// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ExitTerms } from "../libs/ExitTerms.sol";
import { Fees } from "../libs/Fees.sol";
import { IYieldVenue } from "./IYieldVenue.sol";

/// Minimal ERC-4626 surface required by the venue binding check.
interface IERC4626Asset {
    function asset() external view returns (address);
}

/// Which venues are already bound to a yield id, held at a fixed ERC-7201 slot.
///
/// A venue's `totalAssets()` is its whole position, and each id prices its
/// units against it. Two ids bound to one venue would both count that position
/// in `gross`, so a deposit into one would raise the other's index and a
/// withdrawal from either could be paid out of the other's principal.
/// `initAsset` therefore refuses a venue that is already bound.
///
/// Namespaced rather than a field of `YieldOps.Store`: the store is embedded in
/// the pool's sequential layout (`StorageLayout.t.sol`), and a new member would
/// widen it and shift every pool variable declared after `_y`.
///
/// Records only bindings made by an implementation that carries this check. An
/// upgrade onto a pool that already has yield ids does not backfill it, so
/// those venues must be written by a migration or checked by hand before any
/// further `addYieldAsset`.
library VenueBinding {
    /// `keccak256(abi.encode(uint256(keccak256("lelantos.storage.VenueBinding")) - 1)) & ~bytes32(uint256(0xff))`
    /// Re-derived in `VenueBinding.t.sol`.
    bytes32 internal constant SLOT = 0xa6c3bebda549f5084fdfcd40001b1f0bf32be1fec6fb4d6d201bdb403ee41100;

    /// @custom:storage-location erc7201:lelantos.storage.VenueBinding
    struct Layout {
        mapping(address venue => bool) bound;
    }

    /// Named `$` for symmetry with `ExitTerms.$`.
    function $() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly {
            l.slot := s
        }
    }
}

/// Yield-index operations for `YieldIndex`, deployed as an external library.
/// The pool carries both the plain and the indexed arithmetic and sits close to
/// the EIP-170 code-size limit, so this logic is deployed once at its own
/// address and reached by `delegatecall`.
///
/// Under `delegatecall` the library runs in the pool's context: `Store storage`
/// resolves against the pool's slots, `safeTransfer` moves the pool's tokens,
/// and the pool emits the events. The library holds no state and no privileges
/// of its own; every entry point is reachable only through the pool, which
/// applies the access control.
///
/// Callers pass `token` and `scale` from the `AssetEntry` they hold, so this
/// library has no dependency on the asset registry.
library YieldOps {
    using SafeERC20 for IERC20;

    /// Fixed-point base for the reported index, used only by `lastIdx` and
    /// `index`. The unit conversions are exact ratios; see `_toUnderlying`.
    uint256 internal constant RAY = 1e27;

    /// Per-asset configuration, packed into one slot (25 of 32 bytes) so the
    /// venue test and every parameter behind it cost one cold SLOAD.
    struct YieldParams {
        /// Zero means the asset carries no venue. Written once, by `initAsset`.
        address venue;
        /// Share of `gross` kept unlent, so ordinary withdrawals are served
        /// without reaching the venue.
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
        /// Tracked explicitly rather than derived from `token.balanceOf(pool)`,
        /// which is not attributable per asset because a plain id and a yield id
        /// may share one ERC-20. A direct transfer to the pool therefore cannot
        /// move the index.
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
    /// Units are outstanding but the asset holds nothing: `gross` is zero, so
    /// every unit prices at zero. Shielding would mint units for free against
    /// any later recovery, and exiting would burn a claim for nothing, so all
    /// three are refused until the asset is backed again.
    error NoBacking(uint64 id);
    /// `venue` already backs another yield id; see `VenueBinding`.
    error VenueAlreadyBound(address venue);
    /// A venue draw returned less than the caller needs. `draw` is what was
    /// requested, `received` the pool's measured balance increase.
    error VenueUnderDelivered(uint64 id, uint256 draw, uint256 received);

    // ============== Internal helpers =========================================

    function _supply(Store storage y, uint64 id) private view returns (uint256) {
        return y.totalNormalized[id] + y.accruedFeeNormalized[id];
    }

    function _gross(Store storage y, uint64 id, address venue) private view returns (uint256) {
        return IYieldVenue(venue).totalAssets() + y.idle[id];
    }

    /// Converts normalized units to underlying. Equivalent to
    /// `n * scale * idx / RAY` with `idx = g * RAY / (s * scale)`; `scale` and
    /// `RAY` cancel, leaving `n * g / s`, one `mulDiv` and one rounding step.
    ///
    /// `scale` governs the empty pool, where there is no ratio yet and one unit
    /// is worth exactly `scale` base units, pinning the index to `RAY` at the
    /// first deposit.
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
    /// `withdrawBps` is: that needs the note's cost basis, and notes are
    /// shielded and fungible, so `publicOut` is a bare unit count. Minting
    /// dilutes instead and leaves the circuit untouched.
    ///
    /// Attribution stays per-holder with no basis recorded: this runs before
    /// every change to `totalNormalized`, so the holder set is constant within
    /// an accrual window and the dilution charges that window's holders in
    /// proportion to their holdings.
    ///
    /// Growth is measured against holdings rather than through the index:
    /// `(idx - lastIdx) * supply / RAY` expands to
    /// `gross - lastIdx * supply / RAY`, one division.
    ///
    /// `g` is supplied by the caller, which has already read `totalAssets()`;
    /// re-reading it would cost the hot path and widen the read-only-reentrancy
    /// surface.
    ///
    /// A cut worth less than one unit mints nothing and leaves `lastIdx` where it
    /// was, so the growth stays billable once it amounts to a unit and a
    /// permissionless `accruePerf` repeated every block cannot erase the fee.
    /// That carry is sound only while the holder set is unchanged; `quoteShield`
    /// clears it before the supply grows.
    function _accruePerf(Store storage y, uint64 id, uint256 scale, uint256 g, YieldParams memory q) private {
        if (q.perfBps == 0) return;
        uint256 s = _supply(y, id);
        if (s == 0) return;

        // Value of this supply at the mark, rounded up against the treasury so
        // rounding cannot manufacture growth.
        uint256 hwm = Math.mulDiv(s * scale, y.lastIdx[id], RAY, Math.Rounding.Ceil);
        // Loss check and high-water mark in one: after a venue loss `lastIdx`
        // is left untouched, so nothing is charged until gross passes its peak.
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
    /// band crossing and amortises across the deposits between. The band is
    /// `bufferBps` itself, which already states how much unlent capital the
    /// asset tolerates.
    ///
    /// This governs yield, not solvency: `idle` and `totalNormalized` both move
    /// at submit, so the books balance whether or not the tokens have reached
    /// the venue. Idle capital dilutes the return for every holder alike.
    /// `rebalance` passes `banded = false` to close the gap on demand.
    ///
    /// The supply is clamped to the venue's `maxDeposit`. A capped or paused
    /// ERC-4626 reverts a deposit above its limit, and this runs inside every
    /// shield that crosses the band, so an unclamped supply would halt shields
    /// until the guardian halted the asset. The excess stays idle, which costs
    /// yield and not solvency (above), and the next band crossing or
    /// `rebalance` offers it again.
    function _fundVenue(Store storage y, uint64 id, IERC20 token, uint256 g, YieldParams memory q, bool banded)
        private
    {
        if (q.halted) return;
        uint256 target = (g * q.bufferBps) / Fees.BPS_DENOMINATOR;
        uint256 have = y.idle[id];
        if (have <= target) return;
        // Doubles the already-rounded `target` rather than re-deriving the
        // threshold at full precision: `target` is the value written back to
        // `idle` below, so a more precise band would compare against a number
        // the accounting never uses. The precision loss is under two base units.
        // slither-disable-next-line divide-before-multiply
        if (banded && have < target * 2) return;
        uint256 amt = have - target;
        uint256 room = IYieldVenue(q.venue).maxDeposit();
        if (amt > room) amt = room;
        if (amt == 0) return;
        y.idle[id] = have - amt;
        token.safeTransfer(q.venue, amt);
        IYieldVenue(q.venue).deposit(amt);
    }

    /// Makes `need` of underlying available as idle, drawing any shortfall from
    /// the venue. Reverts `VenueDrained` when the venue cannot service it,
    /// leaving the caller's transaction and its nullifiers untouched.
    ///
    /// `maxWithdraw` is read only once a draw is required; the buffer exists so
    /// the common withdrawal never reaches the venue.
    ///
    /// A draw takes the shortfall plus `refill`, restoring the buffer in the
    /// same hop so subsequent withdrawals need not reach the venue. The top-up
    /// is best-effort: a venue that cannot cover it still serves the shortfall,
    /// and only one that cannot cover that reverts. `rebalance` passes zero,
    /// targeting an exact idle balance.
    ///
    /// `idle` is credited with the pool's measured balance increase across the
    /// draw, not with `draw`. A vault that charges an exit fee or rounds against
    /// the withdrawer delivers less than it was asked for, and crediting the
    /// request would overstate `idle`: the shortfall would be paid out of the
    /// same ERC-20 held for another id, a plain id included. What arrived is
    /// credited even when it falls short of the refill; only a delivery that
    /// leaves `idle` below `need` reverts, with `VenueUnderDelivered`, so a
    /// lossy venue fails the exit as a drained one does rather than being paid
    /// from other ids' balances. Measuring is sound because every caller holds
    /// the pool's reentrancy guard and the venue is the one bound at
    /// registration.
    // slither-disable-next-line reentrancy-balance
    function _ensureIdle(Store storage y, uint64 id, IERC20 token, uint256 need, YieldParams memory q, uint256 refill)
        private
    {
        uint256 have = y.idle[id];
        if (have >= need) return;
        uint256 short = need - have;
        uint256 avail = IYieldVenue(q.venue).maxWithdraw();
        if (avail < short) revert VenueDrained(id, short, avail);

        uint256 draw = short + refill;
        if (draw > avail) draw = avail;

        uint256 received = _withdrawMeasured(q.venue, token, draw);
        if (received < short) revert VenueUnderDelivered(id, draw, received);
        y.idle[id] = have + received;
    }

    /// Withdraws `draw` from `venue` and returns the pool's measured balance
    /// increase, which is what `idle` may be credited with; see `_ensureIdle`.
    /// Every caller holds the pool's reentrancy guard, and `venue` is the one
    /// bound at registration, so the reads cannot be interleaved.
    // slither-disable-next-line reentrancy-balance
    function _withdrawMeasured(address venue, IERC20 token, uint256 draw) private returns (uint256 received) {
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 before = token.balanceOf(address(this));
        // aderyn-fp-next-line(reentrancy-state-change)
        IYieldVenue(venue).withdraw(draw);
        // aderyn-fp-next-line(reentrancy-state-change)
        received = token.balanceOf(address(this)) - before;
    }

    /// The buffer to leave behind after `need` has left a pool worth `g`.
    function _refillFor(uint256 g, uint256 need, uint16 bufferBps) private pure returns (uint256) {
        return ((g > need ? g - need : 0) * bufferBps) / Fees.BPS_DENOMINATOR;
    }

    function _requireYield(Store storage y, uint64 id) private view returns (YieldParams memory q) {
        q = y.params[id];
        if (q.venue == address(0)) revert NotYieldAsset(id);
    }

    /// Shared prologue: resolves the asset, reads `gross` once, and brings the
    /// performance fee up to date before anything touches `totalNormalized`.
    ///
    /// `g` is returned because `_accruePerf` mints units and moves no tokens, so
    /// `gross` is unchanged afterwards and callers can price against it without
    /// a second round trip into the venue.
    function _begin(Store storage y, uint64 id, uint256 scale) private returns (YieldParams memory q, uint256 g) {
        q = _requireYield(y, id);
        g = _gross(y, id, q.venue);
        _accruePerf(y, id, scale, g, q);
    }

    // ============== Hot path =================================================

    /// Prices and books a yield-asset unshield, then transfers the underlying.
    ///
    /// Rounds the payout down, against the withdrawer, so the pool is never left
    /// owing more than it holds, and the unit fee up, so a withdrawal below
    /// `BPS_DENOMINATOR / withdrawBps` units is not free; see `Fees.unitFee`. At
    /// the rate ceiling a one-unit withdrawal is consumed entirely by its fee.
    function unshield(
        Store storage y,
        uint64 id,
        IERC20 token,
        uint256 scale,
        uint16 withdrawBps,
        address recipient,
        uint256 nOut
    ) external returns (uint256 net) {
        // Accrues the performance fee before `totalNormalized` changes.
        (YieldParams memory q, uint256 g) = _begin(y, id, scale);
        if (g == 0) revert NoBacking(id);

        uint256 nFee = Fees.unitFee(nOut, withdrawBps);
        // Priced against the supply that still includes these units, and a
        // `gross` the accrual left unchanged: it mints units, not tokens.
        net = _toUnderlying(nOut - nFee, scale, g, _supply(y, id), Math.Rounding.Floor);

        y.totalNormalized[id] -= nOut;
        y.accruedFeeNormalized[id] += nFee;

        _ensureIdle(y, id, token, net, q, _refillFor(g, net, q.bufferBps));
        y.idle[id] -= net;
        token.safeTransfer(recipient, net);
    }

    /// Prices a yield-asset shield and returns the units it buys.
    ///
    /// Rounds the pull up, against the depositor. The amount moves with the
    /// index between signing and inclusion; `Permit2Sig.maxTotal` is the payer's
    /// signed ceiling on the whole pull and bounds that drift.
    function quoteShield(Store storage y, uint64 id, uint256 scale, uint16 depositBps, uint256 publicIn, uint256 feeIn)
        external
        returns (uint256 total, uint256 inAmt, uint256 nTotal, uint256 grossBefore)
    {
        // Accrues before the supply grows, so an arriving depositor is not
        // diluted by growth that predates them. Growth too small to mint a unit
        // is carried by `_accruePerf`, and the ceilinged mark can hide a wei more;
        // left in place, the arriving supply would multiply either into a gap
        // billed to the depositor. Raising the mark to the current index forgives
        // it instead. After a mint the mark is already current, so this is a
        // no-op there; with the fee off the mark is left alone, as in
        // `_accruePerf`.
        (YieldParams memory q, uint256 g) = _begin(y, id, scale);
        if (q.perfBps != 0) {
            uint256 idx = _raiseMark(y, id, scale, g);
            if (idx != 0) emit PerfFeeAccrued(id, 0, idx);
        }
        grossBefore = g;

        uint256 s = _supply(y, id);
        if (s != 0 && g == 0) revert NoBacking(id);
        uint256 nFee = Fees.unitFee(publicIn, depositBps);
        nTotal = publicIn + nFee + feeIn;
        total = _toUnderlying(nTotal, scale, g, s, Math.Rounding.Ceil);
        // Principal only, matching the `inAmount` reported for a plain asset.
        inAmt = _toUnderlying(publicIn, scale, g, s, Math.Rounding.Ceil);
    }

    /// Books a pulled yield-asset shield and supplies the venue.
    ///
    /// `idle` and `totalNormalized` both move here, at submit, so the books
    /// balance from the moment the tokens land, whether or not they have reached
    /// the venue. That separation lets `_fundVenue` wait for a band without
    /// putting solvency at stake.
    ///
    /// The fee units stay inside `totalNormalized` until flush, so a
    /// cancellation refunds them.
    ///
    /// `grossBefore` is the pre-pull `gross` already read by `quoteShield`;
    /// re-deriving it would cost a second round trip into the venue on every
    /// shield.
    function settleShield(Store storage y, uint64 id, IERC20 token, uint256 total, uint256 nTotal, uint256 grossBefore)
        external
    {
        YieldParams memory q = y.params[id];
        uint256 held = y.idle[id] + total;
        y.idle[id] = held;
        y.totalNormalized[id] += nTotal;
        _fundVenue(y, id, token, grossBefore + total, q, true);
    }

    /// Releases a yield-asset escrow and returns the current value of its
    /// units, capped at `cap`, the underlying pulled at submit. A zero `cap` is
    /// no record, not a cap: a recorded pull is never zero (`publicIn != 0`, and
    /// `NoBacking` refuses a zero-priced shield), so it marks an escrow submitted
    /// before the cap existed, refunded uncapped as it was priced to be.
    ///
    /// The escrow's units join the supply at submit, so they share the index
    /// while the deposit waits. The cap keeps an escrow that is never flushed
    /// from earning: without it, a deposit deliberately made unprovable would be
    /// a fee-free position in the venue, refunding its deposit fee and never
    /// paying `withdrawBps`. Every unit is still burned, so the value above the
    /// cap stays with the remaining holders. A loss is shared: the refund is the
    /// floored current value when that is below the cap.
    function cancel(
        Store storage y,
        uint64 id,
        IERC20 token,
        uint256 scale,
        uint256 publicIn,
        uint256 fbps,
        uint256 feeIn,
        uint256 cap
    ) external returns (uint256 total) {
        (YieldParams memory q, uint256 g) = _begin(y, id, scale);
        if (g == 0) revert NoBacking(id);

        uint256 nTotal = publicIn + Fees.unitFee(publicIn, fbps) + feeIn;
        total = _toUnderlying(nTotal, scale, g, _supply(y, id), Math.Rounding.Floor);
        if (cap != 0 && total > cap) total = cap;

        y.totalNormalized[id] -= nTotal;
        _ensureIdle(y, id, token, total, q, _refillFor(g, total, q.bufferBps));
        y.idle[id] -= total;
    }

    // ============== Registration and administration ==========================

    /// Binds `id` to `venue`. Called by the pool once its registry has accepted
    /// `id`; that registry is add-only and rejects a duplicate id, which makes
    /// the binding permanent. `AlreadyYieldAsset` guards the same invariant
    /// locally, and `VenueAlreadyBound` its converse: a venue backs one id.
    function initAsset(Store storage y, uint64 id, address token, address venue, uint16 bufferBps, uint16 perfBps)
        external
    {
        if (venue == address(0)) revert VenueZero();
        if (y.params[id].venue != address(0)) revert AlreadyYieldAsset(id);
        if (perfBps > Fees.MAX_FEE_BPS || bufferBps > Fees.BPS_DENOMINATOR) revert BadYieldParams();
        // The venue must be pinned to this pool, and its vault must hold this
        // token. Reached only through `MASP.addYieldAsset` (`onlyOwner`), and
        // both calls are view probes on the venue being bound. `_addAsset`
        // reverts on a duplicate id, so the write below happens at most once per
        // id under any ordering.
        // aderyn-fp-next-line(reentrancy-state-change)
        if (IYieldVenue(venue).POOL() != address(this)) revert VenueNotPinned();
        // aderyn-fp-next-line(reentrancy-state-change)
        if (IERC4626Asset(IYieldVenue(venue).VAULT()).asset() != token) revert VenueAssetMismatch();
        // One id per venue; see `VenueBinding`. Checked after the probes so a
        // venue pinned elsewhere or holding another token reports that first.
        VenueBinding.Layout storage vb = VenueBinding.$();
        if (vb.bound[venue]) revert VenueAlreadyBound(venue);
        vb.bound[venue] = true;

        y.params[id] = YieldParams({ venue: venue, bufferBps: bufferBps, perfBps: perfBps, halted: false });
        y.lastIdx[id] = RAY;
        emit YieldAssetAdded(id, venue, bufferBps, perfBps);
    }

    /// Updates the buffer split and proposes the performance-fee rate. Neither
    /// touches the venue binding, so neither can move principal between
    /// protocols: `bufferBps` shifts the split between idle and lent, `perfBps`
    /// the treasury's future cut.
    ///
    /// The buffer applies at once; it changes no holder's claim. The rate is
    /// charged on growth every current holder goes on earning, so only a rate
    /// at or below the live one applies here. A higher one is queued in
    /// `ExitTerms` and applied by `commitExitTerms` after the notice period, and
    /// this call keeps the live rate; see `ExitTerms.propose`.
    ///
    /// `YieldParamsSet` carries the pair in force afterwards, so a queued raise
    /// shows the unchanged rate.
    function setParams(Store storage y, uint64 id, uint256 scale, uint16 bufferBps, uint16 perfBps) external {
        if (perfBps > Fees.MAX_FEE_BPS || bufferBps > Fees.BPS_DENOMINATOR) revert BadYieldParams();
        // Settles at the old rate first, so growth earned under it is collected
        // before the new rate takes effect.
        (YieldParams memory q, uint256 g) = _begin(y, id, scale);
        // After `_begin`, which rejects an id with no venue before anything is
        // queued for it.
        if (ExitTerms.propose(ExitTerms.$().perfBps[id], q.perfBps, perfBps, id, ExitTerms.PERF_BPS)) {
            perfBps = q.perfBps;
        }
        _raiseMark(y, id, scale, g);
        y.params[id].bufferBps = bufferBps;
        y.params[id].perfBps = perfBps;
        emit YieldParamsSet(id, bufferBps, perfBps);
    }

    // ============== Exit terms ===============================================
    //
    // The commit for the delayed-raise queue in `ExitTerms` is hosted here, in
    // the pool's one external library, rather than inlined into the pool, which
    // sits close to the EIP-170 limit. As with everything in this library, the
    // pool applies the access control.

    /// `ExitTerms.propose` behind an external call, for `MASP.setCancelDelay`.
    /// A second internal call site in the pool is inlined in full under the
    /// optimizer settings, which measured larger than this call; `setAssetFee`
    /// keeps the internal call so `AssetRegistry` needs no library link.
    function proposeRaise(ExitTerms.Pending storage p, uint256 live, uint256 next, uint64 id, uint8 term)
        external
        returns (bool)
    {
        return ExitTerms.propose(p, live, next, id, term);
    }

    /// Takes every raise queued for `id` whose notice has run, and those only:
    /// its withdraw rate, the pool-wide cancel delay, and its performance-fee
    /// rate. Applies the performance fee here, where its storage lives, and
    /// returns the other two for the pool to write; zero means not taken.
    /// Reverts only if nothing was taken: `RaiseNotDue` with the earliest due
    /// time if something is queued, `NoPendingRaise` otherwise.
    ///
    /// The performance fee follows `setParams`: accrue at the old rate, so
    /// growth earned during the notice is billed at the rate in force for it,
    /// then raise the mark, so the new rate reaches only growth from the commit
    /// on (in particular, a raise from zero does not bill the fee-free period).
    /// The buffer is left as it is. Every queue entry is cleared before the
    /// venue is read.
    ///
    /// `scale` is the registry's raw entry: zero for an id the registry does not
    /// know, which is harmless, since only a yield asset can have a
    /// performance-fee raise queued and only then is `scale` used.
    function commitExitTerms(Store storage y, uint64 id, uint256 scale)
        external
        returns (uint256 withdrawBps, uint256 cancelDelay)
    {
        ExitTerms.Layout storage t = ExitTerms.$();
        uint256 wait;
        (withdrawBps, wait) = ExitTerms.take(t.withdrawBps[id], id, ExitTerms.WITHDRAW_BPS, type(uint256).max);
        (cancelDelay, wait) = ExitTerms.take(t.cancelDelay, 0, ExitTerms.CANCEL_DELAY, wait);
        uint256 perfBps;
        (perfBps, wait) = ExitTerms.take(t.perfBps[id], id, ExitTerms.PERF_BPS, wait);
        if ((withdrawBps | cancelDelay | perfBps) == 0) {
            if (wait == type(uint256).max) revert ExitTerms.NoPendingRaise();
            revert ExitTerms.RaiseNotDue(wait);
        }
        if (perfBps != 0) {
            (YieldParams memory q, uint256 g) = _begin(y, id, scale);
            _raiseMark(y, id, scale, g);
            // `setParams` bounded the queued rate by `MAX_FEE_BPS`.
            // forge-lint: disable-next-line(unsafe-typecast)
            y.params[id].perfBps = uint16(perfBps);
            // forge-lint: disable-next-line(unsafe-typecast)
            emit YieldParamsSet(id, q.bufferBps, uint16(perfBps));
        }
    }

    /// Raises the high-water mark to the current index, so a rate written next
    /// applies only to growth from this point on. `g` is the `gross` the
    /// caller's `_begin` read.
    ///
    /// `_accruePerf` returns on `perfBps == 0` before it touches `lastIdx`, so
    /// while the fee is off the mark does not move (it stays at `RAY` from
    /// `initAsset` if the asset was registered without a fee). Without this
    /// step, re-enabling the fee would bill against that mark and charge a cut
    /// of everything the venue earned over the fee-free period.
    ///
    /// Raised, never assigned: assignment would lower the mark while the pool
    /// is under water, letting an owner reset it with a no-op parameter change
    /// and then bill the recovery. Raising only preserves the loss protection of
    /// the `g <= hwm` check in `_accruePerf`.
    ///
    /// Rounded up, against the treasury, matching `_accruePerf`. Returns the new
    /// mark, or zero when it did not move.
    function _raiseMark(Store storage y, uint64 id, uint256 scale, uint256 g) private returns (uint256 raised) {
        uint256 s = _supply(y, id);
        if (s != 0) {
            uint256 nowIdx = Math.mulDiv(g, RAY, s * scale, Math.Rounding.Ceil);
            if (nowIdx > y.lastIdx[id]) {
                y.lastIdx[id] = nowIdx;
                raised = nowIdx;
            }
        }
    }

    /// Withdraws the venue position back to idle and halts further supply.
    ///
    /// `venue` stays set: clearing it would move the asset onto the pool's
    /// plain arithmetic, where the same integers denote underlying rather than
    /// units, stranding `totalNormalized` and mis-paying every holder. `halted`
    /// stops supply instead.
    ///
    /// The underlying travels only from the venue to the pool, so `gross` is
    /// unchanged, the index is continuous, and no note is revalued. The asset
    /// becomes zero-yield custody, fully backed.
    ///
    /// Partial unwinds are supported and the call is repeatable: a vault short
    /// of liquidity returns what it can, and later calls recover the remainder.
    ///
    /// `recovered` is the pool's measured balance increase, as in `_ensureIdle`,
    /// so a vault that charges an exit fee cannot overstate `idle`. Unlike a
    /// draw, a short delivery does not revert: the unwind is the recovery path,
    /// and the fee shows up as a loss in the index rather than as idle the pool
    /// does not hold.
    function emergencyUnwind(Store storage y, uint64 id, IERC20 token) external returns (uint256 recovered) {
        YieldParams memory q = _requireYield(y, id);
        y.params[id].halted = true;

        // `YieldIndex.emergencyUnwind` is `onlyOwner nonReentrant`, `halted` is set
        // before these calls, and the venue is the one fixed at registration rather
        // than caller-supplied. `idle` cannot be credited twice.
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 held = IYieldVenue(q.venue).totalAssets();
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 avail = IYieldVenue(q.venue).maxWithdraw();
        uint256 draw = held < avail ? held : avail;
        if (draw != 0) {
            recovered = _withdrawMeasured(q.venue, token, draw);
            y.idle[id] += recovered;
        }
        emit HaltedSet(id, true);
        emit EmergencyUnwound(id, recovered);
    }

    /// Halts or resumes supply to the asset's bound vault. Funds can return
    /// only to the vault fixed at registration, so a transient vault outage does
    /// not require retiring the asset id and fragmenting its anonymity set.
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
            _ensureIdle(y, id, token, target, q, 0);
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
    /// transfer to every exit and place the payout behind the venue's liveness,
    /// so a drained vault could block a withdrawal the buffer would cover.
    ///
    /// The accumulator is cleared in full while the floored amount is paid out;
    /// the remainder stays in the pool as surplus backing and accrues to note
    /// holders. Rounding points away from the treasury.
    function sweepNormalized(Store storage y, uint64 id, IERC20 token, uint256 scale, address treasury)
        external
        returns (uint256 amount)
    {
        (YieldParams memory q, uint256 g) = _begin(y, id, scale);

        uint256 units = y.accruedFeeNormalized[id];
        if (units == 0) return 0;
        amount = _toUnderlying(units, scale, g, _supply(y, id), Math.Rounding.Floor);
        // Returns before clearing: a zero floor means the units are worth less
        // than one base unit, and the accumulator must remain claimable once the
        // pool recovers.
        if (amount == 0) return 0;
        y.accruedFeeNormalized[id] = 0;

        _ensureIdle(y, id, token, amount, q, _refillFor(g, amount, q.bufferBps));
        y.idle[id] -= amount;
        token.safeTransfer(treasury, amount);
        emit NormalizedFeeSwept(id, units, amount);
    }

    // ============== Views ====================================================

    /// The index in RAY, for indexers and the SDK. `RAY` when nothing is
    /// outstanding.
    ///
    /// `scale` sits in the denominator because a conversion is
    /// `underlying = n * scale * idx / RAY`; summed over the supply that gives
    /// `gross = supply * scale * idx / RAY`, which inverts to this.
    function index(Store storage y, uint64 id, uint256 scale) external view returns (uint256) {
        uint256 s = _supply(y, id);
        if (s == 0) return RAY;
        return Math.mulDiv(_gross(y, id, y.params[id].venue), RAY, s * scale);
    }
}
