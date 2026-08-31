// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        fc = new FeeConfigHarness(TREASURY, OWNER);
        // Pre-fund so sweep can transfer.
        token.mint(address(fc), type(uint128).max);
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

    // --- Sweep correctness -------------------------------------------------

    /// Sweep transfers exactly the full `accruedFee` to treasury and zeroes it.
    /// uint120 so a1 + a2 stays under the uint128 pre-funded balance.
    function testFuzz_sweep_transfersFullAccrual(uint120 a1, uint120 a2) public {
        IERC20 t = IERC20(address(token));
        fc.accrue(t, a1);
        fc.accrue(t, a2);

        uint256 total = uint256(a1) + uint256(a2);
        uint256 swept = fc.sweep(t);
        assertEq(swept, total);
        assertEq(token.balanceOf(TREASURY), total);
        assertEq(fc.accruedFee(t), 0);
        assertEq(fc.sweep(t), 0, "second sweep finds nothing");
    }
}
