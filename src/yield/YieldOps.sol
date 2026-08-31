// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Fees } from "../libs/Fees.sol";
import { IYieldVenue } from "./IYieldVenue.sol";

/// Minimal ERC-4626 surface required by the venue binding check.
interface IERC4626Asset {
    function asset() external view returns (address);
}

/// Yield-index operations for `YieldIndex`, deployed as an external library.
///
/// The pool carries both the plain and the indexed arithmetic and sits close to
/// the EIP-170 code-size limit, so this logic is deployed once at its own
/// address and reached by `delegatecall` rather than inlined at each of the
/// pool's branch sites.
///
/// Under `delegatecall` the library runs in the pool's context: `Store storage`
/// resolves against the pool's slots, `safeTransfer` moves the pool's tokens,
/// and events are emitted by the pool. The library holds no state and no
/// privileges of its own; every entry point is reachable only through the pool,
/// which applies the access control.
///
/// Callers pass `token` and `scale` from the `AssetEntry` they already hold, so
/// this library has no dependency on the asset registry.
library YieldOps {
    using SafeERC20 for IERC20;

    /// Fixed-point base for the reported index. Used only by `lastIdx` and
    /// `index`; the unit conversions themselves are exact ratios
    /// (`_toUnderlying`).
    uint256 internal constant RAY = 1e27;

    /// Per-asset configuration, packed into one slot (25 of 32 bytes) so the
    /// venue test and every parameter behind it cost a single cold SLOAD.
    struct YieldParams {
        /// Zero means the asset carries no venue. Written once, by `initAsset`.
        address venue;
        /// Share of `gross` kept unlent, so ordinary withdrawals are served
        /// without touching the venue.
        uint16 bufferBps;
        /// Performance fee on yield, minted to the treasury as normalized
        /// units.
        uint16 perfBps;
        /// When set, `_fundVenue` stops supplying the venue. Does not clear
        /// `venue`.
        bool halted;
    }

    /// All index state, reachable from a single storage pointer under
    /// `delegatecall`.
    struct Store {
        mapping(uint64 assetId => YieldParams) params;
        /// Units owed to note holders.
        mapping(uint64 assetId => uint256) totalNormalized;
        /// The treasury's units, accruing alongside holders' until swept.
        mapping(uint64 assetId => uint256) accruedFeeNormalized;
        /// Underlying held by the pool for this asset and not supplied to the
        /// venue.
        ///
        /// Tracked explicitly rather than derived from `token.balanceOf(pool)`:
        /// a plain id and a yield id may share one ERC-20, so that balance is
        /// not attributable per asset. A direct transfer to the pool therefore
        /// cannot move the index.
        mapping(uint64 assetId => uint256) idle;
        /// High-water mark for the performance fee, in RAY. The only stored
        /// index; every user-facing value is derived from holdings on demand.
        mapping(uint64 assetId => uint256) lastIdx;
    }

    event YieldAssetAdded(uint64 indexed assetId, address indexed venue, uint16 bufferBps, uint16 perfBps);
    event PerfFeeAccrued(uint64 indexed assetId, uint256 unitsMinted, uint256 newLastIdx);
    event Rebalanced(uint64 indexed assetId, uint256 idleAfter);
    event HaltedSet(uint64 indexed assetId, bool halted);
    event EmergencyUnwound(uint64 indexed assetId, uint256 recovered);
    event NormalizedFeeSwept(uint64 indexed assetId, uint256 units, uint256 amount);
    event YieldParamsSet(uint64 indexed assetId, uint16 bufferBps, uint16 perfBps);

    error NotYieldAsset(uint64 id);
    error AlreadyYieldAsset(uint64 id);
    error VenueZero();
    error VenueNotPinned();
    error VenueAssetMismatch();
    error BadYieldParams();
    /// The venue cannot service the draw the pool requires. The transaction
    /// reverts, leaving its nullifiers unconsumed.
    error VenueDrained(uint64 id, uint256 need, uint256 available);

    // ============== Internal helpers =========================================

    function _supply(Store storage y, uint64 id) private view returns (uint256) {
        return y.totalNormalized[id] + y.accruedFeeNormalized[id];
    }

    function _gross(Store storage y, uint64 id, address venue) private view returns (uint256) {
        return IYieldVenue(venue).totalAssets() + y.idle[id];
    }

    /// Converts normalized units to underlying.
    ///
    /// Equivalent to `n * scale * idx / RAY` with `idx = g * RAY / (s *
    /// scale)`; `scale` and `RAY` cancel, leaving `n * g / s`, which is one
    /// `mulDiv` and one rounding step.
    ///
    /// `scale` governs the empty pool, where there is no ratio yet and one unit
    /// is worth exactly `scale` base units, which pins the index to `RAY` at
    /// the first deposit.
    function _toUnderlying(uint256 n, uint256 scale, uint256 g, uint256 s, Math.Rounding r)
        private
        pure
        returns (uint256)
    {
        if (s == 0) return n * scale;
        return Math.mulDiv(n, g, s, r);
    }

    /// Takes `perfBps` of the growth since the last mark by minting normalized
    /// units to the treasury.
    ///
    /// A performance fee cannot be deducted from the payout the way
    /// `withdrawBps` is: that requires the note's cost basis, and notes are
    /// shielded and fungible, so `publicOut` is a bare unit count. Minting
    /// dilutes instead, which leaves the circuit untouched.
    ///
    /// Attribution remains per-holder without any basis being recorded. This
    /// runs before every change to `totalNormalized`, so the holder set is
    /// constant within an accrual window and the dilution charges that window's
    /// holders in proportion to their holdings.
    ///
    /// Growth is measured against holdings rather than through the index: `(idx
    /// - lastIdx) * supply / RAY` expands to `gross - lastIdx * supply / RAY`,
    /// which needs one division.
    ///
    /// `g` is supplied by the caller, which has already read `totalAssets()`.
    /// Reading it again would add cost on the hot path and widen the
    /// read-only-reentrancy surface.
    function _accruePerf(Store storage y, uint64 id, uint256 scale, uint256 g, YieldParams memory q) private {
        if (q.perfBps == 0) return;
        uint256 s = _supply(y, id);
        if (s == 0) return;

        // Value of this supply at the mark, rounded up against the treasury so
        // rounding cannot manufacture growth.
        uint256 hwm = Math.mulDiv(s * scale, y.lastIdx[id], RAY, Math.Rounding.Ceil);
        // Loss check and high-water mark in one line: after a venue loss
        // `lastIdx` is left untouched, so nothing is charged until gross passes
        // its old peak.
        if (g <= hwm) return;

        uint256 cut = ((g - hwm) * q.perfBps) / Fees.BPS_DENOMINATOR;
        if (cut == 0) return;
        // Fee-share solve: after minting, the treasury's `m` units are worth
        // `cut`.
        uint256 m = Math.mulDiv(cut, s, g - cut);
        if (m == 0) return;

        y.accruedFeeNormalized[id] += m;
        uint256 next = Math.mulDiv(g, RAY, (s + m) * scale, Math.Rounding.Ceil);
        y.lastIdx[id] = next;
        emit PerfFeeAccrued(id, m, next);
    }

    /// Supplies the venue with everything above the buffer target.
    ///
    /// `banded` defers the transfer and ERC-4626 mint until idle reaches twice
    /// the target, then moves down to the target, so the cost is paid once per
    /// band crossing and amortises across the deposits in between. The band is
    /// `bufferBps` itself, which already expresses how much unlent capital the
    /// asset tolerates.
    ///
    /// This governs yield, not solvency: `idle` and `totalNormalized` both move
    /// at submit, so the books balance whether or not the tokens have reached
    /// the venue. Capital left idle dilutes the return, and dilutes every
    /// holder alike. `rebalance` passes `banded = false` to close the gap on
    /// demand.
    function _fundVenue(Store storage y, uint64 id, IERC20 token, uint256 g, YieldParams memory q, bool banded)
        private
    {
        if (q.halted) return;
        uint256 target = (g * q.bufferBps) / Fees.BPS_DENOMINATOR;
        uint256 have = y.idle[id];
        if (have <= target) return;
        // Deliberately doubles the already-rounded `target` rather than
        // re-deriving the threshold at full precision: this is the same value
        // written back to `idle` below, so a more precise band would compare
        // against a number the accounting never uses. Loss is one unit, doubled.
        // slither-disable-next-line divide-before-multiply
        if (banded && have < target * 2) return;
        uint256 amt = have - target;
        y.idle[id] = target;
        token.safeTransfer(q.venue, amt);
        IYieldVenue(q.venue).deposit(amt);
    }

    /// Makes `need` of underlying available as idle, drawing any shortfall from
    /// the venue. Reverts `VenueDrained` when the venue cannot service it,
    /// which leaves the caller's transaction, and its nullifiers, untouched.
    ///
    /// `maxWithdraw` is read only once a draw is required; the buffer exists so
    /// the common withdrawal never reaches the venue at all.
    ///
    /// A draw takes the shortfall plus `refill`, restoring the buffer in the
    /// same hop so the withdrawals that follow do not each reach the venue. The
    /// top-up is best-effort: a venue that cannot cover it still serves the
    /// shortfall, and only one that cannot cover even that reverts. `rebalance`
    /// passes zero, since it targets an exact idle balance.
    function _ensureIdle(Store storage y, uint64 id, uint256 need, YieldParams memory q, uint256 refill) private {
        uint256 have = y.idle[id];
        if (have >= need) return;
        uint256 short = need - have;
        uint256 avail = IYieldVenue(q.venue).maxWithdraw();
        if (avail < short) revert VenueDrained(id, short, avail);

        uint256 draw = short + refill;
        if (draw > avail) draw = avail;

        IYieldVenue(q.venue).withdraw(draw);
        y.idle[id] = have + draw;
    }

    /// The buffer to leave behind after `need` has left a pool worth `g`.
    function _refillFor(uint256 g, uint256 need, uint16 bufferBps) private pure returns (uint256) {
        return ((g > need ? g - need : 0) * bufferBps) / Fees.BPS_DENOMINATOR;
    }

    function _requireYield(Store storage y, uint64 id) private view returns (YieldParams memory q) {
        q = y.params[id];
        if (q.venue == address(0)) revert NotYieldAsset(id);
    }

    /// Shared prologue: resolve the asset, read `gross` once, and bring the
    /// performance fee up to date before anything touches `totalNormalized`.
    ///
    /// `g` is returned because `_accruePerf` mints units and moves no tokens,
    /// so `gross` is unchanged afterwards and callers can price against it
    /// without a second round trip into the venue and its vault.
    function _begin(Store storage y, uint64 id, uint256 scale) private returns (YieldParams memory q, uint256 g) {
        q = _requireYield(y, id);
        g = _gross(y, id, q.venue);
        _accruePerf(y, id, scale, g, q);
    }

    // ============== Hot path =================================================

    /// Prices and books a yield-asset unshield, then transfers the underlying.
    ///
    /// Rounds the payout down, against the withdrawer, so the pool is never
    /// left owing more than it holds.
    function unshield(
        Store storage y,
        uint64 id,
        IERC20 token,
        uint256 scale,
        uint16 withdrawBps,
        address recipient,
        uint256 nOut
    ) external returns (uint256 net) {
        // Settles at the old rate first, so the change is not retroactive.
        (YieldParams memory q, uint256 g) = _begin(y, id, scale);

        uint256 nFee = (nOut * withdrawBps) / Fees.BPS_DENOMINATOR;
        // Priced against the supply that still includes these units, and
        // against a `gross` the accrual left unchanged: it mints units, not
        // tokens.
        net = _toUnderlying(nOut - nFee, scale, g, _supply(y, id), Math.Rounding.Floor);

        y.totalNormalized[id] -= nOut;
        y.accruedFeeNormalized[id] += nFee;

        _ensureIdle(y, id, net, q, _refillFor(g, net, q.bufferBps));
        y.idle[id] -= net;
        token.safeTransfer(recipient, net);
    }

    /// Prices a yield-asset shield and returns the units it buys.
    ///
    /// Rounds the pull up, against the depositor. The amount moves with the
    /// index between signing and inclusion; `Permit2Sig.maxTotal` is the
    /// payer's signed ceiling on the whole pull and bounds that drift as it
    /// bounds a fee change.
    function quoteShield(Store storage y, uint64 id, uint256 scale, uint16 depositBps, uint256 publicIn, uint256 feeIn)
        external
        returns (uint256 total, uint256 inAmt, uint256 nTotal, uint256 grossBefore)
    {
        // Accrues before the supply grows, so an arriving depositor is not
        // diluted by growth that predates them.
        (YieldParams memory q, uint256 g) = _begin(y, id, scale);
        grossBefore = g;

        uint256 s = _supply(y, id);
        uint256 nFee = (publicIn * depositBps) / Fees.BPS_DENOMINATOR;
        nTotal = publicIn + nFee + feeIn;
        total = _toUnderlying(nTotal, scale, g, s, Math.Rounding.Ceil);
        // Principal only, matching the `inAmount` reported for a plain asset.
        inAmt = _toUnderlying(publicIn, scale, g, s, Math.Rounding.Ceil);
    }

    /// Books a pulled yield-asset shield and supplies the venue.
    ///
    /// `idle` and `totalNormalized` both move here, at submit, so the pool's
    /// books balance from the moment the tokens land, independently of whether
    /// those tokens have reached the venue. That separation lets `_fundVenue`
    /// wait for a band without putting solvency at stake.
    ///
    /// The fee units stay inside `totalNormalized` until flush, so a
    /// cancellation refunds them.
    ///
    /// `grossBefore` is the pre-pull `gross` already read by `quoteShield`;
    /// re-deriving it here would mean a second round trip into the venue and
    /// its vault on every shield.
    function settleShield(Store storage y, uint64 id, IERC20 token, uint256 total, uint256 nTotal, uint256 grossBefore)
        external
    {
        YieldParams memory q = y.params[id];
        uint256 held = y.idle[id] + total;
        y.idle[id] = held;
        y.totalNormalized[id] += nTotal;
        _fundVenue(y, id, token, grossBefore + total, q, true);
    }

    /// Releases a yield-asset escrow and returns today's value of its units.
    ///
    /// Includes whatever the escrowed funds earned while they sat in the venue,
    /// which matches the liability being released. Floored against a ceilinged
    /// pull, so a round trip leaves the pool over-backed.
    function cancel(Store storage y, uint64 id, uint256 scale, uint256 publicIn, uint256 fbps, uint256 feeIn)
        external
        returns (uint256 total)
    {
        (YieldParams memory q, uint256 g) = _begin(y, id, scale);

        uint256 nTotal = publicIn + ((publicIn * fbps) / Fees.BPS_DENOMINATOR) + feeIn;
        total = _toUnderlying(nTotal, scale, g, _supply(y, id), Math.Rounding.Floor);

        y.totalNormalized[id] -= nTotal;
        _ensureIdle(y, id, total, q, _refillFor(g, total, q.bufferBps));
        y.idle[id] -= total;
    }

    // ============== Registration and administration ==========================

    /// Binds `id` to `venue`. Called by the pool once its registry has accepted
    /// `id`; that registry is add-only and rejects a duplicate id, which makes
    /// the binding permanent without a further guard here.
    function initAsset(Store storage y, uint64 id, address token, address venue, uint16 bufferBps, uint16 perfBps)
        external
    {
        if (venue == address(0)) revert VenueZero();
        if (y.params[id].venue != address(0)) revert AlreadyYieldAsset(id);
        if (perfBps > Fees.MAX_FEE_BPS || bufferBps > Fees.BPS_DENOMINATOR) revert BadYieldParams();
        // The venue must be pinned to this pool, and its vault must hold this
        // token.
        if (IYieldVenue(venue).POOL() != address(this)) revert VenueNotPinned();
        if (IERC4626Asset(IYieldVenue(venue).VAULT()).asset() != token) revert VenueAssetMismatch();

        y.params[id] = YieldParams({ venue: venue, bufferBps: bufferBps, perfBps: perfBps, halted: false });
        y.lastIdx[id] = RAY;
        emit YieldAssetAdded(id, venue, bufferBps, perfBps);
    }

    /// Updates the buffer split and the performance-fee rate. Neither touches
    /// the venue binding, so neither can move principal between protocols:
    /// `bufferBps` shifts the split between idle and lent, `perfBps` the
    /// treasury's future cut.
    function setParams(Store storage y, uint64 id, uint256 scale, uint16 bufferBps, uint16 perfBps) external {
        if (perfBps > Fees.MAX_FEE_BPS || bufferBps > Fees.BPS_DENOMINATOR) revert BadYieldParams();
        // Settle at the old rate first, so growth earned under it is collected
        // before the new one takes effect.
        (, uint256 g) = _begin(y, id, scale);

        // Then move the water line to here, so the new rate applies only to
        // growth from this point on.
        //
        // This is load-bearing rather than tidy-up. `_accruePerf` returns on
        // `perfBps == 0` *before* it touches `lastIdx`, so while a fee is
        // switched off the mark stays frozen wherever it was — at `RAY` from
        // `initAsset` if the asset was registered without one. Re-enabling the
        // fee would otherwise bill against that stale mark and charge a cut of
        // everything the venue had earned in the meantime, which is exactly the
        // period the operator had declared fee-free.
        //
        // Raised, never assigned. A plain assignment would *lower* the mark
        // while the pool is under water, so an owner could reset the high-water
        // mark with a no-op parameter change and then bill the recovery. Only
        // ever moving it up preserves the loss protection that the `g <= hwm`
        // check in `_accruePerf` provides.
        //
        // Rounded up, against the treasury, matching `_accruePerf`.
        uint256 s = _supply(y, id);
        if (s != 0) {
            uint256 nowIdx = Math.mulDiv(g, RAY, s * scale, Math.Rounding.Ceil);
            if (nowIdx > y.lastIdx[id]) y.lastIdx[id] = nowIdx;
        }

        y.params[id].bufferBps = bufferBps;
        y.params[id].perfBps = perfBps;
        emit YieldParamsSet(id, bufferBps, perfBps);
    }

    /// Withdraws the venue position back to idle and halts further supply.
    ///
    /// `venue` is left set. Clearing it would move the asset onto the pool's
    /// plain arithmetic, where the same integers denote underlying rather than
    /// units, stranding `totalNormalized` and mis-paying every holder; `halted`
    /// covers this case instead.
    ///
    /// `gross` is unchanged by the move, since the underlying only travels from
    /// the venue to the pool, so the index is continuous and no note is
    /// revalued. The asset becomes zero-yield custody, fully backed.
    ///
    /// Partial unwinds are supported and the call is repeatable: a vault short
    /// of liquidity returns what it can now, and the remainder as it recovers.
    function emergencyUnwind(Store storage y, uint64 id) external returns (uint256 recovered) {
        YieldParams memory q = _requireYield(y, id);
        y.params[id].halted = true;

        uint256 held = IYieldVenue(q.venue).totalAssets();
        uint256 avail = IYieldVenue(q.venue).maxWithdraw();
        recovered = held < avail ? held : avail;
        if (recovered != 0) {
            IYieldVenue(q.venue).withdraw(recovered);
            y.idle[id] += recovered;
        }
        emit HaltedSet(id, true);
        emit EmergencyUnwound(id, recovered);
    }

    /// Halts or resumes supply to the asset's bound vault.
    ///
    /// Funds can only return to the vault fixed at registration, never to a
    /// different protocol. This allows a transient vault outage without
    /// retiring the asset id and fragmenting its anonymity set.
    function setHalted(Store storage y, uint64 id, bool halted) external {
        _requireYield(y, id);
        y.params[id].halted = halted;
        emit HaltedSet(id, halted);
    }

    // ============== Permissionless maintenance ===============================

    /// Restores the buffer split in either direction. Permissionless: it moves
    /// nothing in or out of the pool and cannot change `gross`.
    function rebalance(Store storage y, uint64 id, IERC20 token, uint256 scale) external {
        (YieldParams memory q, uint256 g) = _begin(y, id, scale);

        uint256 target = (g * q.bufferBps) / Fees.BPS_DENOMINATOR;
        uint256 have = y.idle[id];
        if (have < target && !q.halted) {
            _ensureIdle(y, id, target, q, 0);
        } else if (have > target) {
            // Unbanded: the call exists to close the gap in full.
            _fundVenue(y, id, token, g, q, false);
        }
        emit Rebalanced(id, y.idle[id]);
    }

    /// Brings the performance fee up to date without waiting on user traffic,
    /// so a quiet asset still accrues.
    function accruePerf(Store storage y, uint64 id, uint256 scale) external {
        _begin(y, id, scale);
    }

    /// Converts the treasury's units to underlying and transfers them.
    ///
    /// Permissionless caller, owner-pinned destination. Settlement is lazy:
    /// paying the treasury inside every withdraw would add a venue draw and a
    /// transfer to every exit, and would place the payout behind the venue's
    /// liveness, so a drained vault could block a withdrawal the buffer would
    /// otherwise cover.
    ///
    /// The accumulator is cleared in full while the floored amount is paid out;
    /// the remainder stays in the pool as surplus backing, which accrues to
    /// note holders. Rounding points away from the treasury.
    function sweepNormalized(Store storage y, uint64 id, IERC20 token, uint256 scale, address treasury)
        external
        returns (uint256 amount)
    {
        (YieldParams memory q, uint256 g) = _begin(y, id, scale);

        uint256 units = y.accruedFeeNormalized[id];
        if (units == 0) return 0;
        amount = _toUnderlying(units, scale, g, _supply(y, id), Math.Rounding.Floor);
        y.accruedFeeNormalized[id] = 0;
        if (amount == 0) return 0;

        _ensureIdle(y, id, amount, q, _refillFor(g, amount, q.bufferBps));
        y.idle[id] -= amount;
        token.safeTransfer(treasury, amount);
        emit NormalizedFeeSwept(id, units, amount);
    }

    // ============== Views ====================================================

    /// The index in RAY, for indexers and the SDK. `RAY` when nothing is
    /// outstanding.
    ///
    /// `scale` sits in the denominator because a conversion is `underlying = n
    /// * scale * idx / RAY`; summed over the supply this gives `gross = supply
    /// * scale * idx / RAY`, which inverts to this.
    function index(Store storage y, uint64 id, uint256 scale) external view returns (uint256) {
        uint256 s = _supply(y, id);
        if (s == 0) return RAY;
        return Math.mulDiv(_gross(y, id, y.params[id].venue), RAY, s * scale);
    }
}
