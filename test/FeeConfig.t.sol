// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { FeeConfig } from "../src/FeeConfig.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// Concrete `FeeConfig` exposing the internal helpers for unit tests.
contract FeeConfigHarness is FeeConfig {
    constructor(address treasury_, address owner_) Ownable(owner_) {
        _initTreasury(treasury_);
    }

    function accrue(IERC20 token, uint256 amount) external {
        _accrueFee(token, amount);
    }
}

contract FeeConfigTest is Test {
    FeeConfigHarness internal fc;
    MockERC20 internal token;
    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0xB0B);

    function setUp() public {
        token = new MockERC20("T", "T", 18);
        fc = new FeeConfigHarness(TREASURY, OWNER); // rates live per asset, not here
        // Pre-fund harness so sweep transfers can succeed.
        token.mint(address(fc), 1_000_000 ether);
    }

    function test_accrue_accumulates() public {
        IERC20 t = IERC20(address(token));
        fc.accrue(t, 100);
        assertEq(fc.accruedFee(t), 100);
        fc.accrue(t, 30);
        assertEq(fc.accruedFee(t), 130);
        fc.accrue(t, 0); // zero-amount is a no-op
        assertEq(fc.accruedFee(t), 130);
    }

    function test_sweep_drainsFullAccrual() public {
        IERC20 t = IERC20(address(token));
        fc.accrue(t, 1000);
        uint256 swept = fc.sweep(t);
        assertEq(swept, 1000, "swept = full accrual");
        assertEq(token.balanceOf(TREASURY), 1000, "treasury received full accrual");
        assertEq(fc.accruedFee(t), 0, "accrual zeroed");
    }

    function test_sweep_zeroWhenNothingAccrued() public {
        IERC20 t = IERC20(address(token));
        uint256 swept = fc.sweep(t);
        assertEq(swept, 0);
        assertEq(token.balanceOf(TREASURY), 0);
    }

    function test_sweep_idempotent() public {
        IERC20 t = IERC20(address(token));
        fc.accrue(t, 500);
        assertEq(fc.sweep(t), 500);
        assertEq(fc.sweep(t), 0, "second sweep finds nothing");
        assertEq(token.balanceOf(TREASURY), 500);
    }

    function test_accrueAfterSweep_startsFresh() public {
        IERC20 t = IERC20(address(token));
        fc.accrue(t, 100);
        fc.sweep(t);
        fc.accrue(t, 40);
        assertEq(fc.accruedFee(t), 40);
        assertEq(fc.sweep(t), 40);
        assertEq(token.balanceOf(TREASURY), 140);
    }
}
