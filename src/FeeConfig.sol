// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// Owner-set fees + per-token accrual. Drained to `treasury` via
/// permissionless `sweep`. `pendingEscrowFee` gates sweep against
/// `cancelIntent` underflow.
abstract contract FeeConfig is Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// feeBps ceiling (20%).
    uint16 public constant MAX_FEE_BPS = 2_000;

    address public treasury;
    uint16 public feeBps;

    /// Total fees accrued per token. Monotone between sweeps.
    mapping(IERC20 => uint256) public accruedFee;

    /// Subset of `accruedFee` still locked in pending intents.
    mapping(IERC20 => uint256) public pendingEscrowFee;

    error ZeroTreasury();
    error FeeTooHigh();
    error PendingFeeUnderflow();

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

    /// Drain `accruedFee - pendingEscrowFee` for `token` to `treasury`.
    /// Permissionless; destination is owner-pinned.
    function sweep(IERC20 token) external nonReentrant returns (uint256 amount) {
        uint256 acc = accruedFee[token];
        uint256 pending = pendingEscrowFee[token];
        if (acc <= pending) return 0;
        unchecked {
            amount = acc - pending;
        }
        accruedFee[token] = pending;
        token.safeTransfer(treasury, amount);
    }

    function _accrueFee(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        accruedFee[token] += amount;
    }

    /// Reverse a prior `_accrueFee`. Caller responsible for pairing.
    function _decrueFee(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        uint256 acc = accruedFee[token];
        if (acc < amount) revert PendingFeeUnderflow();
        unchecked {
            accruedFee[token] = acc - amount;
        }
    }

    function _addPendingEscrowFee(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        pendingEscrowFee[token] += amount;
    }

    function _subPendingEscrowFee(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        uint256 p = pendingEscrowFee[token];
        if (p < amount) revert PendingFeeUnderflow();
        unchecked {
            pendingEscrowFee[token] = p - amount;
        }
    }
}
