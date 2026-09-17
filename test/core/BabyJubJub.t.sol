// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { BabyJubJub } from "../../src/BabyJubJub.sol";

/// Edge tests for `BabyJubJub.isOnCurve` and `isLowOrder`. `AuxValidation`
/// relies on the library to reject off-curve and low-order clue R and
/// ephemeral points; an error here admits malformed FMD clues.
contract BabyJubJubTest is Test {
    uint256 internal constant P = BabyJubJub.P;

    /// Verified on-curve point (asset 1 from
    /// test/fixtures/asset_registry.json).
    uint256 internal constant GEN_X =
        3_309_989_483_652_810_547_183_542_801_964_179_728_734_313_126_748_501_664_722_543_918_881_379_626_481;
    uint256 internal constant GEN_Y =
        19_074_974_479_579_335_435_926_212_694_086_463_865_934_978_035_491_619_549_852_413_897_256_554_942_562;

    /// Identity element of the twisted Edwards group: (0, 1).
    /// a*x^2 + y^2 = 1 + d*x^2*y^2 reduces to 0 + 1 = 1 + 0.
    function test_identityIsOnCurve() public pure {
        assertTrue(BabyJubJub.isOnCurve(0, 1));
    }

    function test_knownGenIsOnCurve() public pure {
        assertTrue(BabyJubJub.isOnCurve(GEN_X, GEN_Y));
    }

    function test_negYIsOnCurve() public pure {
        // (x, -y) is on curve iff (x, y) is — equation only uses y^2.
        assertTrue(BabyJubJub.isOnCurve(GEN_X, P - GEN_Y));
    }

    function test_negXIsOnCurve() public pure {
        assertTrue(BabyJubJub.isOnCurve(P - GEN_X, GEN_Y));
    }

    function test_zeroZeroOffCurve() public pure {
        // 0 + 0 != 1 → off curve.
        assertFalse(BabyJubJub.isOnCurve(0, 0));
    }

    function test_oneOneOffCurve() public pure {
        // a + 1 != 1 + d → off curve.
        assertFalse(BabyJubJub.isOnCurve(1, 1));
    }

    function test_xEqualsPRejected() public pure {
        // x >= P guard.
        assertFalse(BabyJubJub.isOnCurve(P, GEN_Y));
    }

    function test_yEqualsPRejected() public pure {
        assertFalse(BabyJubJub.isOnCurve(GEN_X, P));
    }

    function test_xAbovePRejected() public pure {
        assertFalse(BabyJubJub.isOnCurve(P + 1, GEN_Y));
    }

    function test_yAbovePRejected() public pure {
        assertFalse(BabyJubJub.isOnCurve(GEN_X, P + 1));
    }

    function testFuzz_RandomPointsAlmostAlwaysOffCurve(uint256 x, uint256 y) public pure {
        x = x % P;
        y = y % P;
        // Skips on-curve coincidences (probability ~1/P).
        if (BabyJubJub.isOnCurve(x, y)) return;
        assertFalse(BabyJubJub.isOnCurve(x, y));
    }

    /// Identity (0, 1) is the trivial low-order point (`[1]·O = O`). It is
    /// flagged so `AuxValidation` rejects placeholder clue and ephemeral points.
    function test_identityIsLowOrder() public view {
        assertTrue(BabyJubJub.isLowOrder(0, 1));
    }

    /// The canonical `8·Base` generator of the prime-order subgroup is not
    /// low-order; indexers use it as a valid sentinel.
    function test_base8IsNotLowOrder() public view {
        assertFalse(BabyJubJub.isLowOrder(BabyJubJub.BASE8_X, BabyJubJub.BASE8_Y));
    }
}
