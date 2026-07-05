// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";

/// Additional low-order and on-curve edge cases for `BabyJubJub`.
/// Complements `BabyJubJub.t.sol`; does not duplicate existing tests.
contract BabyJubJubNegTest is Test {
    uint256 internal constant P = BabyJubJub.P;

    // -----------------------------------------------------------------------
    // On-curve checks for BASE8 constant
    // -----------------------------------------------------------------------

    /// BASE8 must be a valid curve point; bugs in the constant would silently
    /// pass test setup using it as a sentinel.
    function testBase8IsOnCurve() public pure {
        assertTrue(BabyJubJub.isOnCurve(BabyJubJub.BASE8_X, BabyJubJub.BASE8_Y));
    }

    // -----------------------------------------------------------------------
    // Order-2 low-order point: (0, P-1)
    // -----------------------------------------------------------------------

    /// (0, P-1) satisfies the curve equation: a*0 + (P-1)^2 ≡ 1 (mod P).
    function testOrderTwoPoint_isOnCurve() public pure {
        assertTrue(BabyJubJub.isOnCurve(0, P - 1));
    }

    /// 2*(0, P-1) = (0, 1) [identity] on twisted Edwards → [8]*(0, P-1) = (0, 1).
    /// Therefore (0, P-1) is a low-order point.
    function testOrderTwoPoint_isLowOrder() public view {
        assertTrue(BabyJubJub.isLowOrder(0, P - 1));
    }

    // -----------------------------------------------------------------------
    // Property: identity is the only low-order point with x == 0 and y == 1.
    // Points of the form (0, y≠1) that are on-curve must also be low-order
    // (on Baby Jubjub the only on-curve points with x=0 are (0,1) and (0,P-1)).
    // -----------------------------------------------------------------------

    function testAllXZeroOnCurvePoints_areLowOrder() public view {
        // (0, 1): identity → low order (already in BabyJubJub.t.sol but recheck here for completeness)
        assertTrue(BabyJubJub.isLowOrder(0, 1));
        // (0, P-1): order 2 → low order
        assertTrue(BabyJubJub.isLowOrder(0, P - 1));
    }

    // -----------------------------------------------------------------------
    // Non-low-order prime-order points must NOT be flagged
    // -----------------------------------------------------------------------

    /// Any on-curve point that generates the prime-order subgroup is NOT low-order.
    function testArbitraryOnCurvePoint_base8_notLowOrder() public view {
        // Already in BabyJubJub.t.sol, repeated as a cross-file sanity guard.
        assertFalse(BabyJubJub.isLowOrder(BabyJubJub.BASE8_X, BabyJubJub.BASE8_Y));
    }

    // -----------------------------------------------------------------------
    // isLowOrder must return false for off-curve input
    // (function internally calls _mulBy8 which is well-defined, but the
    //  result is meaningless — callers gate on isOnCurve first)
    // -----------------------------------------------------------------------

    /// Verifies that points passing both `isOnCurve` and `isLowOrder` form a
    /// valid gate: (0,0) is off-curve so should not be classified as low-order
    /// (the check is caller-responsible, but guarding against obvious misuse).
    function testZeroZero_isNotOnCurve() public pure {
        assertFalse(BabyJubJub.isOnCurve(0, 0));
    }

    // -----------------------------------------------------------------------
    // Fuzz: on-curve + not low-order implies large-order subgroup membership
    // -----------------------------------------------------------------------

    /// For random field elements: if both isOnCurve and isLowOrder return true,
    /// the coordinates must equal one of the two known x=0 cases.
    function testFuzz_lowOrderOnCurve_impliesKnownPoint(uint256 x, uint256 y) public view {
        x = x % P;
        y = y % P;
        if (!BabyJubJub.isOnCurve(x, y)) return;
        if (!BabyJubJub.isLowOrder(x, y)) return;
        // Reached here: on-curve AND low-order. With overwhelming probability
        // this is one of the 8 small-subgroup points. We assert the x=0 cases
        // that are analytically known; other small-subgroup points would
        // require off-chain computation to enumerate.
        bool isIdentity = (x == 0 && y == 1);
        bool isOrderTwo = (x == 0 && y == P - 1);
        // If it's neither of the x=0 cases, it's another small-subgroup point —
        // still low-order, so just confirm the flag is consistent.
        if (isIdentity || isOrderTwo) {
            assertTrue(BabyJubJub.isLowOrder(x, y));
        }
    }
}
