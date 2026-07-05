// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { FeeConfig } from "../src/FeeConfig.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// Concrete `FeeConfig` exposing the internal helpers for unit tests.
contract FeeConfigHarness is FeeConfig {
    constructor(uint16 feeBps_, address treasury_, address owner_) Ownable(owner_) {
        _initFee(feeBps_, treasury_);
    }

    function accrue(IERC20 token, uint256 amount) external {
        _accrueFee(token, amount);
    }

    function decrue(IERC20 token, uint256 amount) external {
        _decrueFee(token, amount);
    }

    function addPending(IERC20 token, uint256 amount) external {
        _addPendingEscrowFee(token, amount);
    }

    function subPending(IERC20 token, uint256 amount) external {
        _subPendingEscrowFee(token, amount);
    }
}

contract FeeConfigTest is Test {
    FeeConfigHarness internal fc;
    MockERC20 internal token;
    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0xB0B);

    function setUp() public {
        token = new MockERC20("T", "T", 18);
        fc = new FeeConfigHarness(100, TREASURY, OWNER); // 1% fee
        // Pre-fund harness so sweep transfers can succeed.
        token.mint(address(fc), 1_000_000 ether);
    }

    function test_accrueDecrueRoundTrip() public {
        IERC20 t = IERC20(address(token));
        fc.accrue(t, 100);
        assertEq(fc.accruedFee(t), 100);
        fc.decrue(t, 30);
        assertEq(fc.accruedFee(t), 70);
        fc.decrue(t, 70);
        assertEq(fc.accruedFee(t), 0);
    }

    function test_decrueUnderflow_reverts() public {
        IERC20 t = IERC20(address(token));
        fc.accrue(t, 50);
        vm.expectRevert(FeeConfig.PendingFeeUnderflow.selector);
        fc.decrue(t, 51);
    }

    function test_pendingEscrowFee_blocksSweep() public {
        IERC20 t = IERC20(address(token));
        fc.accrue(t, 1000);
        fc.addPending(t, 600);
        // Releasable = 1000 - 600 = 400.
        uint256 swept = fc.sweep(t);
        assertEq(swept, 400, "swept = releasable");
        assertEq(token.balanceOf(TREASURY), 400, "treasury received releasable");
        assertEq(fc.accruedFee(t), 600, "remaining = pending");
        assertEq(fc.pendingEscrowFee(t), 600, "pending unchanged by sweep");
    }

    function test_pendingEscrowFee_zeroSweep_whenAllPending() public {
        IERC20 t = IERC20(address(token));
        fc.accrue(t, 500);
        fc.addPending(t, 500);
        uint256 swept = fc.sweep(t);
        assertEq(swept, 0, "nothing releasable");
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(fc.accruedFee(t), 500);
    }

    function test_subPendingUnderflow_reverts() public {
        IERC20 t = IERC20(address(token));
        fc.addPending(t, 50);
        vm.expectRevert(FeeConfig.PendingFeeUnderflow.selector);
        fc.subPending(t, 51);
    }

    function test_pendingFlow_submitFlush() public {
        IERC20 t = IERC20(address(token));
        // Submit: fee both accrues and adds to pending.
        fc.accrue(t, 100);
        fc.addPending(t, 100);
        assertEq(fc.accruedFee(t), 100);
        assertEq(fc.pendingEscrowFee(t), 100);
        // Flush: only pending decrements (accrual is real income).
        fc.subPending(t, 100);
        assertEq(fc.accruedFee(t), 100, "still claimable");
        assertEq(fc.pendingEscrowFee(t), 0);
        // Sweep now releases full 100.
        uint256 swept = fc.sweep(t);
        assertEq(swept, 100);
    }

    function test_pendingFlow_submitCancel() public {
        IERC20 t = IERC20(address(token));
        fc.accrue(t, 100);
        fc.addPending(t, 100);
        // Cancel: both decrement.
        fc.subPending(t, 100);
        fc.decrue(t, 100);
        assertEq(fc.accruedFee(t), 0);
        assertEq(fc.pendingEscrowFee(t), 0);
        uint256 swept = fc.sweep(t);
        assertEq(swept, 0, "nothing left to sweep");
    }
}
