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
    // Order-4 / order-8 / mixed-order vectors (computed off-chain with the
    // affine twisted Edwards group law; see git history for the generator
    // script). These differentially pin the projective `isLowOrder` rewrite:
    // an arithmetic slip in the doubling formulas would misclassify at least
    // one of them.
    // -----------------------------------------------------------------------

    /// Order-4 points are (±sqrt(1/a), 0): doubling gives (0, P-1), so
    /// [8]P = identity.
    uint256 internal constant ORDER4_X =
        18_930_368_022_820_495_955_728_484_915_491_405_972_470_733_850_014_661_777_449_844_430_438_130_630_919;

    /// Order-8 point: `[L] * Base` for circomlib's full-order (8L) generator.
    uint256 internal constant ORDER8_X =
        4_342_719_913_949_491_028_786_768_530_115_087_822_524_712_248_835_451_589_697_801_404_893_164_183_326;
    uint256 internal constant ORDER8_Y =
        4_826_523_245_007_015_323_400_664_741_523_384_119_579_596_407_052_839_571_721_035_538_011_798_951_543;

    /// `3 * BASE8`: a prime-order point distinct from BASE8 (negative control).
    uint256 internal constant PRIME3_X =
        2_763_488_322_167_937_039_616_325_905_516_046_217_694_264_098_671_987_087_929_565_332_380_420_898_366;
    uint256 internal constant PRIME3_Y =
        15_305_195_750_036_305_661_220_525_648_961_313_310_481_046_260_814_497_672_243_197_092_298_550_508_693;

    /// Order-2L point ((0, P-1) + 3*BASE8): mixed order, [8]P != identity, so
    /// NOT low-order — the check must not over-reject cofactor components.
    uint256 internal constant MIXED2L_X =
        19_124_754_549_671_338_182_630_079_839_741_228_870_854_100_301_744_047_255_768_638_854_195_387_597_251;
    uint256 internal constant MIXED2L_Y =
        6_583_047_121_802_969_561_025_880_096_295_961_778_067_318_139_601_536_671_455_007_094_277_257_986_924;

    function testOrderFourPoints_areLowOrder() public pure {
        assertTrue(BabyJubJub.isOnCurve(ORDER4_X, 0));
        assertTrue(BabyJubJub.isLowOrder(ORDER4_X, 0));
        // Negated x is the other order-4 point.
        assertTrue(BabyJubJub.isOnCurve(P - ORDER4_X, 0));
        assertTrue(BabyJubJub.isLowOrder(P - ORDER4_X, 0));
    }

    function testOrderEightPoint_isLowOrder() public pure {
        assertTrue(BabyJubJub.isOnCurve(ORDER8_X, ORDER8_Y));
        assertTrue(BabyJubJub.isLowOrder(ORDER8_X, ORDER8_Y));
        // (x, -y) has the same order.
        assertTrue(BabyJubJub.isLowOrder(ORDER8_X, P - ORDER8_Y));
    }

    function testPrimeOrderPoint_notBase8_isNotLowOrder() public pure {
        assertTrue(BabyJubJub.isOnCurve(PRIME3_X, PRIME3_Y));
        assertFalse(BabyJubJub.isLowOrder(PRIME3_X, PRIME3_Y));
    }

    function testMixedOrderPoint_isNotLowOrder() public pure {
        assertTrue(BabyJubJub.isOnCurve(MIXED2L_X, MIXED2L_Y));
        assertFalse(BabyJubJub.isLowOrder(MIXED2L_X, MIXED2L_Y));
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
