// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Fees } from "./libs/Fees.sol";

/// Owner-managed registry of supported assets. Each `id` (the SNARK
/// `publicAssetId`) binds to an ERC-20 and a public-amount to base-units
/// `scale`. Add-only: assets can be disabled but never removed. A disabled
/// asset blocks new deposits but stays spendable, so notes and escrows can
/// exit.
abstract contract AssetRegistry is Ownable {
    /// `token`, `disabled` and the fee fields share slot 0; `scale` is slot 1.
    /// The three fee-related fields fit slot 0's existing padding (20 + 1 + 1 +
    /// 2 + 2 = 26 of 32 bytes), so `_getAsset`, which already loads both slots,
    /// reads them at no extra cost. A field spilling into a third slot would
    /// add a cold SLOAD to every deposit and withdraw.
    ///
    /// Both rates are literal: there is no pool-wide fallback and no unset
    /// sentinel, so a stored `0` means the asset charges nothing on that leg.
    /// Every asset carries its own pair from registration, so a fee change
    /// reaches exactly the ids named in the call.
    struct AssetEntry {
        IERC20 token;
        bool disabled;
        uint16 depositBps;
        uint16 withdrawBps;
        uint256 scale;
    }

    mapping(uint64 => AssetEntry) private _assets;

    event AssetRegistered(uint64 indexed assetId, IERC20 indexed token, uint256 scale);
    event AssetDisabledSet(uint64 indexed assetId, bool disabled);
    /// Emitted with the rates an asset is registered at, and again on every
    /// change. Indexers must follow it rather than reading rates once: unlike
    /// `scale`, a fee is mutable. Kept separate from `AssetRegistered` so that
    /// event's shape — which consumers already decode — does not move.
    event AssetFeeSet(uint64 indexed assetId, uint16 depositBps, uint16 withdrawBps);

    error UnknownAsset(uint64 id);
    error DuplicateAsset(uint64 id);
    error ZeroToken();
    error ZeroScale();
    error ScaleTooLarge();
    error LengthMismatch();
    error AssetDisabled(uint64 id);
    error AssetFeeTooHigh();

    function asset(uint64 id) external view returns (AssetEntry memory) {
        AssetEntry memory a = _assets[id];
        if (address(a.token) == address(0)) revert UnknownAsset(id);
        return a;
    }

    /// Owner-only single-asset add. Reverts if `id` is already registered.
    ///
    /// Rates are required rather than defaulted: there is nothing to inherit,
    /// so an omitted rate would silently register the asset as free.
    function addAsset(uint64 id, IERC20 token, uint256 scale, uint16 depositBps, uint16 withdrawBps)
        external
        onlyOwner
    {
        _addAsset(id, token, scale, depositBps, withdrawBps);
    }

    /// Replace this asset's deposit and withdraw rates. Either may be zero.
    ///
    /// Rates apply from the next operation. A deposit already in escrow keeps
    /// the rate folded into its digest at submit, so a change here cannot
    /// re-rate a pending deposit or its cancellation. The withdraw leg carries
    /// no such binding — it is read at execution — so raising `withdrawBps`
    /// affects spends that are already proven but not yet mined.
    function setAssetFee(uint64 id, uint16 depositBps, uint16 withdrawBps) external onlyOwner {
        if (depositBps > Fees.MAX_FEE_BPS || withdrawBps > Fees.MAX_FEE_BPS) revert AssetFeeTooHigh();
        AssetEntry storage a = _assets[id];
        if (address(a.token) == address(0)) revert UnknownAsset(id);
        a.depositBps = depositBps;
        a.withdrawBps = withdrawBps;
        emit AssetFeeSet(id, depositBps, withdrawBps);
    }

    /// Owner-only update of an asset's `disabled` flag.
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

    /// Existence check for paths that move no tokens. Reads only slot 0, shared
    /// by `token` and `disabled`; `_getAsset` also loads `scale` from slot 1.
    function _requireAssetKnown(uint64 id) internal view {
        if (address(_assets[id].token) == address(0)) revert UnknownAsset(id);
    }

    /// Constructor-time bulk initialization. Same validation as `addAsset`.
    ///
    /// Rates are parallel arrays rather than one uniform value: the deployed
    /// policy is asymmetric per leg and may differ per asset. Registering at a
    /// placeholder rate would leave the pool live at the wrong rate between two
    /// transactions, so every asset is registered at its final rates or the
    /// deploy reverts.
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
            _addAsset(ids[i], tokens[i], scales[i], depositBps[i], withdrawBps[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// `internal` rather than `private` so a subclass can register an asset and
    /// bind extra per-asset state in the same call — `MASP.addYieldAsset` pairs
    /// it with the venue binding. The add-only rule below is what makes such a
    /// binding permanent: a second registration of `id` reverts here.
    function _addAsset(uint64 id, IERC20 token, uint256 scale, uint16 depositBps, uint16 withdrawBps) internal {
        if (address(_assets[id].token) != address(0)) revert DuplicateAsset(id);
        if (address(token) == address(0)) revert ZeroToken();
        if (scale == 0) revert ZeroScale();
        if (scale > 1e18) revert ScaleTooLarge();
        if (depositBps > Fees.MAX_FEE_BPS || withdrawBps > Fees.MAX_FEE_BPS) revert AssetFeeTooHigh();
        _assets[id] = AssetEntry({
            token: token, disabled: false, depositBps: depositBps, withdrawBps: withdrawBps, scale: scale
        });
        emit AssetRegistered(id, token, scale);
        emit AssetFeeSet(id, depositBps, withdrawBps);
    }
}
