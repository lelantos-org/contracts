// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Fees } from "./libs/Fees.sol";
import { OwnableInit } from "./OwnableInit.sol";
import { ExitTerms } from "./libs/ExitTerms.sol";

/// Owner-managed registry of supported assets. Each `id` (the SNARK
/// `publicAssetId`) binds to an ERC-20 and a public-amount to base-units
/// `scale`. Add-only: an asset can be disabled but never removed, and a disabled
/// asset blocks new deposits while staying spendable, so notes and escrows can
/// exit.
abstract contract AssetRegistry is OwnableInit {
    /// One slot, exactly: `token` (20 bytes), `disabled` (1), both rates (4),
    /// `isYield` (1) and `scale` (6). `_getAsset` is therefore a single SLOAD,
    /// and a field spilling into a second slot would add a cold one to every
    /// deposit, withdraw, flush and cancel.
    ///
    /// `scale` is `uint48` to fit: registration rejects anything larger, about
    /// 2.8e14. Its width also bounds every `units * scale` product, since unit
    /// counts are held to `uint48` on every path.
    ///
    /// `isYield` mirrors the venue binding `YieldIndex` holds for the id, so
    /// the pool's paths branch on the entry they already loaded instead of
    /// reading that binding. Both are written once, in the same call, and
    /// neither can change afterwards; see `MASP.addYieldAsset`.
    ///
    /// Both rates are literal: there is no pool-wide fallback and no unset
    /// sentinel, so a stored `0` charges nothing on that leg, and a fee change
    /// reaches exactly the ids named in the call.
    struct AssetEntry {
        IERC20 token;
        bool disabled;
        uint16 depositBps;
        uint16 withdrawBps;
        bool isYield;
        uint48 scale;
    }

    mapping(uint64 => AssetEntry) private _assets;

    event AssetRegistered(uint64 indexed assetId, IERC20 indexed token, uint256 scale);
    event AssetDisabledSet(uint64 indexed assetId, bool disabled);
    /// Emitted with the rates an asset is registered at, on every
    /// `setAssetFee`, and when a queued withdraw raise is committed. Always
    /// carries the pair in force afterwards, so a `setAssetFee` whose withdraw
    /// rate was queued rather than applied reports the unchanged withdraw rate;
    /// the queued value is announced by `ExitTerms.ExitTermRaisePending`. Rates
    /// are mutable, unlike `scale`, so indexers must follow this event rather
    /// than read them once. Separate from `AssetRegistered` so that event's
    /// shape stays fixed.
    event AssetFeeSet(uint64 indexed assetId, uint16 depositBps, uint16 withdrawBps);

    error UnknownAsset(uint64 id);
    error DuplicateAsset(uint64 id);
    error ZeroToken();
    error ZeroScale();
    error ScaleTooLarge();
    error LengthMismatch();
    /// Asset id 0 means "no asset" to the circuits and cannot be registered.
    error ZeroAssetId();
    error AssetDisabled(uint64 id);
    error AssetFeeTooHigh();

    function asset(uint64 id) external view returns (AssetEntry memory) {
        AssetEntry memory a = _assets[id];
        if (address(a.token) == address(0)) revert UnknownAsset(id);
        return a;
    }

    /// Owner-only single-asset add. Reverts if `id` is already registered.
    /// Rates are required rather than defaulted: there is nothing to inherit, so
    /// an omitted rate would register the asset as free.
    ///
    /// `id` is a caller-chosen `uint64`, and the circuits treat it as an opaque
    /// label: a deposit leaf is bound to its `(asset, value)` by hash, so no id
    /// set is safer than another. The one reserved value is 0, which means "no
    /// asset": a transfer's `publicAssetId` and a zero-value fee note carry it,
    /// and the circuits refuse value under it. It cannot be registered.
    function addAsset(uint64 id, IERC20 token, uint256 scale, uint16 depositBps, uint16 withdrawBps)
        external
        onlyOwner
    {
        _addAsset(id, token, scale, depositBps, withdrawBps, false);
    }

    /// Sets this asset's deposit rate and proposes its withdraw rate. Either may
    /// be zero; both are checked against the ceiling here, whether applied or
    /// queued.
    ///
    /// The deposit rate applies from the next deposit. A deposit already in
    /// escrow keeps the rate folded into its digest at submit, so a change
    /// cannot reach a pending deposit, its cancellation, or anyone already
    /// shielded.
    ///
    /// The withdraw rate has no such binding: it is read at execution, so it
    /// reaches every note in the pool and every spend proven but not yet mined.
    /// A new rate at or below the live one therefore applies at once and drops
    /// any queued raise. A higher one is queued in `ExitTerms` and lands only
    /// through `commitExitTerms` after `ExitTerms.DELAY` of notice (and a full
    /// `DELAY` after any pause), so holders can leave at the old rate first.
    /// Re-sending the queued value keeps its timer, so a deposit-only change
    /// need not restart the notice; see `ExitTerms.propose`.
    function setAssetFee(uint64 id, uint16 depositBps, uint16 withdrawBps) external onlyOwner {
        if (depositBps > Fees.MAX_FEE_BPS || withdrawBps > Fees.MAX_FEE_BPS) revert AssetFeeTooHigh();
        AssetEntry storage a = _assets[id];
        if (address(a.token) == address(0)) revert UnknownAsset(id);
        if (ExitTerms.propose(ExitTerms.$().withdrawBps[id], a.withdrawBps, withdrawBps, id, ExitTerms.WITHDRAW_BPS)) {
            withdrawBps = a.withdrawBps;
        }
        a.depositBps = depositBps;
        a.withdrawBps = withdrawBps;
        emit AssetFeeSet(id, depositBps, withdrawBps);
    }

    /// Applies a withdraw raise `commitExitTerms` has taken from the queue.
    /// The id is registered: only `setAssetFee` queues, and it checks.
    function _commitWithdrawBps(uint64 id, uint16 withdrawBps) internal {
        AssetEntry storage a = _assets[id];
        a.withdrawBps = withdrawBps;
        emit AssetFeeSet(id, a.depositBps, withdrawBps);
    }

    function setAssetDisabled(uint64 id, bool disabled) external onlyOwner {
        AssetEntry storage a = _assets[id];
        if (address(a.token) == address(0)) revert UnknownAsset(id);
        if (a.disabled == disabled) return;
        a.disabled = disabled;
        emit AssetDisabledSet(id, disabled);
    }

    /// Raw lookup for the transact path; does not revert on a missing asset.
    function _getAsset(uint64 id) internal view returns (AssetEntry memory) {
        return _assets[id];
    }

    /// Bulk registration at initialization, with the same validation as
    /// `addAsset`. Rates are parallel arrays because policy is asymmetric per
    /// leg and may differ per asset; every asset is registered at its final
    /// rates or the deploy reverts.
    function _writeAssets(
        uint64[] memory ids,
        IERC20[] memory tokens,
        uint256[] memory scales,
        uint16[] memory depositBps,
        uint16[] memory withdrawBps
    ) internal {
        uint256 n = ids.length;
        if (tokens.length != n || scales.length != n || depositBps.length != n || withdrawBps.length != n) {
            revert LengthMismatch();
        }
        for (uint256 i; i < n;) {
            _addAsset(ids[i], tokens[i], scales[i], depositBps[i], withdrawBps[i], false);
            unchecked {
                ++i;
            }
        }
    }

    /// `internal` so a subclass can register an asset and bind extra per-asset
    /// state in the same call; `MASP.addYieldAsset` pairs it with the venue
    /// binding and passes `isYield`. The add-only rule below makes such a
    /// binding, and the flag with it, permanent: a second registration of `id`
    /// reverts here.
    function _addAsset(uint64 id, IERC20 token, uint256 scale, uint16 depositBps, uint16 withdrawBps, bool isYield)
        internal
    {
        if (id == 0) revert ZeroAssetId();
        if (address(_assets[id].token) != address(0)) revert DuplicateAsset(id);
        if (address(token) == address(0)) revert ZeroToken();
        if (scale == 0) revert ZeroScale();
        if (scale > type(uint48).max) revert ScaleTooLarge();
        if (depositBps > Fees.MAX_FEE_BPS || withdrawBps > Fees.MAX_FEE_BPS) revert AssetFeeTooHigh();
        _assets[id] = AssetEntry({
            token: token,
            disabled: false,
            depositBps: depositBps,
            withdrawBps: withdrawBps,
            isYield: isYield,
            // Checked against the field's width above.
            // forge-lint: disable-next-line(unsafe-typecast)
            scale: uint48(scale)
        });
        emit AssetRegistered(id, token, scale);
        emit AssetFeeSet(id, depositBps, withdrawBps);
    }
}
