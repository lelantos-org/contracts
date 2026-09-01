// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { Fees } from "./libs/Fees.sol";

/// Per-token fee accrual, drained to `treasury` by the permissionless `sweep`.
/// Fees accrue at flush, so `accruedFee` never holds escrowed funds.
///
/// There is no pool-wide rate: every asset carries its own deposit and withdraw
/// rates in its `AssetRegistry` entry, set at registration and mutable only
/// through `setAssetFee`. A stored `0` means exactly 0, so no owner action can
/// re-rate an asset not named in the call.
abstract contract FeeConfig is Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = Fees.BPS_DENOMINATOR;

    /// Ceiling on any rate (20%).
    uint16 public constant MAX_FEE_BPS = Fees.MAX_FEE_BPS;

    address public treasury;

    /// Total fees accrued per token. Monotone between sweeps.
    mapping(IERC20 => uint256) public accruedFee;

    error ZeroTreasury();

    function _initTreasury(address treasury_) internal {
        if (treasury_ == address(0)) revert ZeroTreasury();
        treasury = treasury_;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroTreasury();
        treasury = newTreasury;
    }

    /// Drains `accruedFee` for `token` to `treasury`. Permissionless caller,
    /// owner-pinned destination.
    function sweep(IERC20 token) external nonReentrant returns (uint256 amount) {
        amount = accruedFee[token];
        if (amount == 0) return 0;
        accruedFee[token] = 0;
        token.safeTransfer(treasury, amount);
    }

    function _accrueFee(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        accruedFee[token] += amount;
    }
}
