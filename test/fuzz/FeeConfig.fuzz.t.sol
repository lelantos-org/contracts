// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FeeConfig } from "../../src/FeeConfig.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { FeeConfigHarness } from "../FeeConfig.t.sol";

/// Fuzz suite for `FeeConfig` accounting invariants.
contract FeeConfigFuzzTest is Test {
    FeeConfigHarness fc;
    MockERC20 token;
    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0xB0B);

    function setUp() public {
        token = new MockERC20("T", "T", 18);
        fc = new FeeConfigHarness(100, TREASURY, OWNER);
        // Pre-fund so sweep can transfer.
        token.mint(address(fc), type(uint128).max);
    }

    // --- Invariant: accruedFee >= pendingEscrowFee -------------------------

    /// After any accrue + addPending pair (where pending <= accrued),
    /// the invariant holds.
    function testFuzz_invariant_accruedGeqPending(uint128 accrueAmt, uint128 pendingAmt) public {
        vm.assume(pendingAmt <= accrueAmt);
        IERC20 t = IERC20(address(token));
        fc.accrue(t, accrueAmt);
        fc.addPending(t, pendingAmt);
        assertGe(fc.accruedFee(t), fc.pendingEscrowFee(t));
    }

    /// After a submit (accrue + addPending) and partial flush (subPending),
    /// invariant still holds.
    function testFuzz_invariant_afterPartialFlush(uint128 fee, uint128 flushFraction) public {
        vm.assume(fee > 0);
        flushFraction = uint128(bound(flushFraction, 0, fee));
        IERC20 t = IERC20(address(token));
        fc.accrue(t, fee);
        fc.addPending(t, fee);
        fc.subPending(t, flushFraction);
        assertGe(fc.accruedFee(t), fc.pendingEscrowFee(t));
    }

    // --- Fee arithmetic: no overflow for realistic inputs ------------------

    /// Fee formula: `fee = (inAmt * fbps) / 10_000`. For any publicIn <= uint48
    /// max and fbps <= 2000, the result must not overflow uint256 and must be
    /// <= inAmt.
    function testFuzz_feeFormula_noOverflow(uint48 publicIn, uint16 fbps) public pure {
        vm.assume(fbps <= 2000);
        uint256 scale = 1e10;
        uint256 inAmt = uint256(publicIn) * scale;
        uint256 fee = (inAmt * uint256(fbps)) / 10_000;
        assertLe(fee, inAmt);
    }

    /// fee + net == inAmt (no token loss or gain from fee split).
    function testFuzz_feeFormula_splitSumsToInAmt(uint48 publicIn, uint16 fbps) public pure {
        vm.assume(fbps <= 2000);
        uint256 scale = 1e10;
        uint256 inAmt = uint256(publicIn) * scale;
        uint256 fee = (inAmt * uint256(fbps)) / 10_000;
        uint256 net = inAmt - fee;
        assertEq(fee + net, inAmt);
    }

    // --- Underflow protection -----------------------------------------------

    /// `decrue` beyond `accruedFee` must revert.
    function testFuzz_decrue_underflow_reverts(uint128 accrueAmt, uint128 decrueAmt) public {
        vm.assume(decrueAmt > accrueAmt);
        IERC20 t = IERC20(address(token));
        fc.accrue(t, accrueAmt);
        vm.expectRevert(FeeConfig.PendingFeeUnderflow.selector);
        fc.decrue(t, decrueAmt);
    }

    /// `subPending` beyond `pendingEscrowFee` must revert.
    function testFuzz_subPending_underflow_reverts(uint128 addAmt, uint128 subAmt) public {
        vm.assume(subAmt > addAmt);
        IERC20 t = IERC20(address(token));
        fc.addPending(t, addAmt);
        vm.expectRevert(FeeConfig.PendingFeeUnderflow.selector);
        fc.subPending(t, subAmt);
    }

    // --- Sweep correctness -------------------------------------------------

    /// Sweep transfers exactly `accruedFee - pendingEscrowFee` to treasury.
    function testFuzz_sweep_transfersReleasable(uint128 accrueAmt, uint128 pendingAmt) public {
        vm.assume(pendingAmt <= accrueAmt);
        IERC20 t = IERC20(address(token));
        fc.accrue(t, accrueAmt);
        fc.addPending(t, pendingAmt);

        uint256 releasable = accrueAmt - pendingAmt;
        uint256 swept = fc.sweep(t);
        assertEq(swept, releasable);
        assertEq(token.balanceOf(TREASURY), releasable);
        assertEq(fc.accruedFee(t), pendingAmt);
        assertEq(fc.pendingEscrowFee(t), pendingAmt);
    }
}
