// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// Owner-set fees with per-token accrual, drained to `treasury` by the
/// permissionless `sweep`. Fees accrue at flush, so `accruedFee` never holds
/// escrowed funds.
abstract contract FeeConfig is Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// Ceiling on `feeBps` (20%).
    uint16 public constant MAX_FEE_BPS = 2_000;

    address public treasury;
    uint16 public feeBps;

    /// Total fees accrued per token. Monotone between sweeps.
    mapping(IERC20 => uint256) public accruedFee;

    error ZeroTreasury();
    error FeeTooHigh();

    function _initFee(uint16 feeBps_, address treasury_) internal {
        if (treasury_ == address(0)) revert ZeroTreasury();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        treasury = treasury_;
    }

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroTreasury();
        treasury = newTreasury;
    }

    /// Drain `accruedFee` for `token` to `treasury`. Permissionless; the
    /// destination is owner-pinned.
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
