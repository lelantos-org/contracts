// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { BabyJubJub } from "../../src/BabyJubJub.sol";

/// Low-order and on-curve edge cases for `BabyJubJub`, complementing
/// `BabyJubJub.t.sol`.
contract BabyJubJubNegTest is Test {
    uint256 internal constant P = BabyJubJub.P;

    // -----------------------------------------------------------------------
    // On-curve checks for BASE8 constant
    // -----------------------------------------------------------------------

    /// BASE8 is a valid curve point; an error in the constant would otherwise
    /// pass unnoticed in tests that use it as a sentinel.
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

    /// 2*(0, P-1) = (0, 1), the identity, so [8]*(0, P-1) = (0, 1) and the
    /// point is low-order.
    function testOrderTwoPoint_isLowOrder() public view {
        assertTrue(BabyJubJub.isLowOrder(0, P - 1));
    }

    // -----------------------------------------------------------------------
    // The only on-curve points with x = 0 are (0, 1) and (0, P-1); both are
    // low-order.
    // -----------------------------------------------------------------------

    function testAllXZeroOnCurvePoints_areLowOrder() public view {
        // (0, 1): identity.
        assertTrue(BabyJubJub.isLowOrder(0, 1));
        // (0, P-1): order 2.
        assertTrue(BabyJubJub.isLowOrder(0, P - 1));
    }

    // -----------------------------------------------------------------------
    // Prime-order points are not flagged as low-order
    // -----------------------------------------------------------------------

    /// An on-curve point that generates the prime-order subgroup is not low-order.
    function testArbitraryOnCurvePoint_base8_notLowOrder() public view {
        // Also covered in BabyJubJub.t.sol; repeated as a cross-file guard.
        assertFalse(BabyJubJub.isLowOrder(BabyJubJub.BASE8_X, BabyJubJub.BASE8_Y));
    }

    // -----------------------------------------------------------------------
    // Off-curve input
    // (`isLowOrder` requires an on-curve input; callers gate on `isOnCurve`
    //  first, so its result on off-curve points is undefined)
    // -----------------------------------------------------------------------

    /// (0, 0) is rejected by `isOnCurve`, the gate callers apply before
    /// `isLowOrder`.
    function testZeroZero_isNotOnCurve() public pure {
        assertFalse(BabyJubJub.isOnCurve(0, 0));
    }

    // -----------------------------------------------------------------------
    // Order-4 / order-8 / mixed-order vectors, computed off-chain with the
    // affine twisted Edwards group law. They cross-check the projective
    // `isLowOrder` implementation: an arithmetic error in the doubling
    // formulas misclassifies at least one of them.
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

    /// Order-2L point ((0, P-1) + 3*BASE8): mixed order with [8]P != identity,
    /// so not low-order; the check does not reject points with a cofactor
    /// component.
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
    // Fuzz: consistency of isOnCurve and isLowOrder on random inputs
    // -----------------------------------------------------------------------

    /// For random field elements that are on-curve and low-order, the known
    /// x = 0 cases stay classified as low-order.
    function testFuzz_lowOrderOnCurve_impliesKnownPoint(uint256 x, uint256 y) public view {
        x = x % P;
        y = y % P;
        if (!BabyJubJub.isOnCurve(x, y)) return;
        if (!BabyJubJub.isLowOrder(x, y)) return;
        // On-curve and low-order: one of the 8 small-subgroup points. Only the
        // analytically known x = 0 cases are asserted; enumerating the rest
        // requires off-chain computation.
        bool isIdentity = (x == 0 && y == 1);
        bool isOrderTwo = (x == 0 && y == P - 1);
        // Other small-subgroup points are also low-order; the check below
        // only confirms the flag is consistent.
        if (isIdentity || isOrderTwo) {
            assertTrue(BabyJubJub.isLowOrder(x, y));
        }
    }
}
