// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IYieldVenue } from "./IYieldVenue.sol";

/// Generic ERC-4626 venue, covering any vault that speaks the standard without
/// a per-protocol adapter.
///
/// One instance per `(assetId, vault)`, pinned to its pool: `onlyPool` gates
/// `deposit` and `withdraw`, so no other caller can move the position or route a
/// redemption. Everything else is immutable, so there is no owner and no
/// configuration to compromise. A venue is replaced by registering a new asset
/// id, never by re-pointing this one.
///
/// The pool pushes the underlying here and then calls `deposit`; this contract
/// holds no allowance over the pool. `withdraw` redeems straight to `POOL`, so
/// the underlying never rests here between calls. An ERC-4626 rounding
/// remainder stays in the position and is counted by `totalAssets`, so it
/// accrues to note holders rather than being stranded.
contract ERC4626Venue is IYieldVenue {
    using SafeERC20 for IERC20;

    /// The only permitted caller of `deposit` and `withdraw`.
    address public immutable POOL;
    address public immutable VAULT;
    /// The vault's asset. Asserted against `IERC4626(VAULT).asset()` at
    /// construction, so the pair cannot be mismatched after deployment.
    address public immutable UNDERLYING;

    error PoolZero();
    error VaultZero();
    error UnauthorizedCaller();
    /// `IERC4626(vault).asset()` disagreed with the supplied underlying.
    error VaultAssetMismatch(address expected, address actual);

    modifier onlyPool() {
        if (msg.sender != POOL) revert UnauthorizedCaller();
        _;
    }

    constructor(address pool, address vault, address underlying) {
        if (pool == address(0)) revert PoolZero();
        if (vault == address(0)) revert VaultZero();
        address vaultAsset = IERC4626(vault).asset();
        if (vaultAsset != underlying) revert VaultAssetMismatch(underlying, vaultAsset);
        POOL = pool;
        VAULT = vault;
        UNDERLYING = underlying;
        // Approved once rather than per deposit. The allowance is this
        // contract's, over a vault fixed at construction, and this contract
        // holds no balance between calls: `deposit` consumes what the pool just
        // pushed and `withdraw` redeems straight to the pool.
        IERC20(underlying).forceApprove(vault, type(uint256).max);
    }

    /// Supplies `assets`, which the pool has already transferred in.
    function deposit(uint256 assets) external onlyPool {
        // Shares minted are not tracked per call: `totalAssets` reads the
        // position back from `balanceOf`.
        // slither-disable-next-line unused-return
        IERC4626(VAULT).deposit(assets, address(this));
    }

    /// Redeems `assets` of the underlying directly to the pool. The pool gates
    /// the amount on `maxWithdraw` beforehand; a vault that reverts anyway
    /// reverts the whole transaction, leaving the spend's nullifiers
    /// unconsumed — a liveness failure, not a loss.
    function withdraw(uint256 assets) external onlyPool {
        // Shares burned are unused: `assets` is the exact amount the vault
        // sends to the pool, and a short vault reverts.
        // slither-disable-next-line unused-return
        IERC4626(VAULT).withdraw(assets, POOL, address(this));
    }

    /// Underlying backing this venue's shares, at the vault's current rate.
    function totalAssets() external view returns (uint256) {
        return IERC4626(VAULT).convertToAssets(IERC4626(VAULT).balanceOf(address(this)));
    }

    /// What the vault will service now. Below `totalAssets` whenever the
    /// vault's own markets are short of liquidity.
    function maxWithdraw() external view returns (uint256) {
        return IERC4626(VAULT).maxWithdraw(address(this));
    }
}
