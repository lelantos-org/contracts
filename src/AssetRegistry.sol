// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// Owner-managed registry of supported assets. Each `id` (the SNARK
/// `publicAssetId`) binds to an ERC-20 and a public-amount to base-units
/// `scale`. Add-only: assets can be disabled but never removed. A disabled
/// asset blocks new deposits but stays spendable, so notes and escrows can
/// exit.
abstract contract AssetRegistry is Ownable {
    struct AssetEntry {
        IERC20 token;
        bool disabled;
        uint256 scale;
    }

    mapping(uint64 => AssetEntry) private _assets;

    event AssetRegistered(uint64 indexed assetId, IERC20 indexed token, uint256 scale);
    event AssetDisabledSet(uint64 indexed assetId, bool disabled);

    error UnknownAsset(uint64 id);
    error DuplicateAsset(uint64 id);
    error ZeroToken();
    error ZeroScale();
    error ScaleTooLarge();
    error LengthMismatch();
    error AssetDisabled(uint64 id);

    function asset(uint64 id) external view returns (AssetEntry memory) {
        AssetEntry memory a = _assets[id];
        if (address(a.token) == address(0)) revert UnknownAsset(id);
        return a;
    }

    /// Owner-only single-asset add. Reverts if `id` is already registered.
    function addAsset(uint64 id, IERC20 token, uint256 scale) external onlyOwner {
        _addAsset(id, token, scale);
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

    /// Existence check for paths that move no tokens. `token` and `disabled`
    /// share slot 0, so this reads one slot where `_getAsset` reads two: `scale`
    /// occupies slot 1 and costs a second cold SLOAD.
    function _requireAssetKnown(uint64 id) internal view {
        if (address(_assets[id].token) == address(0)) revert UnknownAsset(id);
    }

    /// Constructor-time bulk initialization. Same validation as `addAsset`.
    function _writeAssets(uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) internal {
        uint256 n = ids.length;
        if (tokens.length != n || scales.length != n) revert LengthMismatch();
        for (uint256 i; i < n;) {
            _addAsset(ids[i], tokens[i], scales[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _addAsset(uint64 id, IERC20 token, uint256 scale) private {
        if (address(_assets[id].token) != address(0)) revert DuplicateAsset(id);
        if (address(token) == address(0)) revert ZeroToken();
        if (scale == 0) revert ZeroScale();
        if (scale > 1e18) revert ScaleTooLarge();
        _assets[id] = AssetEntry({ token: token, disabled: false, scale: scale });
        emit AssetRegistered(id, token, scale);
    }
}
