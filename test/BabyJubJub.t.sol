// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";

/// Edge tests for `BabyJubJub.isOnCurve`. The library is the gatekeeper for
/// `AuxValidation` (off-curve clueRx/Ry and ephPub points are rejected) —
/// bugs here would let a malformed FMD clue corrupt SNARK PIs.
contract BabyJubJubTest is Test {
    uint256 internal constant P = BabyJubJub.P;

    /// Verified on-curve point (asset 1 from
    /// test/fixtures/asset_registry.json).
    uint256 internal constant GEN_X =
        3_309_989_483_652_810_547_183_542_801_964_179_728_734_313_126_748_501_664_722_543_918_881_379_626_481;
    uint256 internal constant GEN_Y =
        19_074_974_479_579_335_435_926_212_694_086_463_865_934_978_035_491_619_549_852_413_897_256_554_942_562;

    /// Identity element of the twisted Edwards group: (0, 1).
    /// Plug into a*x^2 + y^2 = 1 + d*x^2*y^2 → 0 + 1 = 1 + 0. ✓
    function testIdentityIsOnCurve() public pure {
        assertTrue(BabyJubJub.isOnCurve(0, 1));
    }

    function testKnownGenIsOnCurve() public pure {
        assertTrue(BabyJubJub.isOnCurve(GEN_X, GEN_Y));
    }

    function testNegYIsOnCurve() public pure {
        // (x, -y) is on curve iff (x, y) is — equation only uses y^2.
        assertTrue(BabyJubJub.isOnCurve(GEN_X, P - GEN_Y));
    }

    function testNegXIsOnCurve() public pure {
        assertTrue(BabyJubJub.isOnCurve(P - GEN_X, GEN_Y));
    }

    function testZeroZeroOffCurve() public pure {
        // 0 + 0 != 1 → off curve.
        assertFalse(BabyJubJub.isOnCurve(0, 0));
    }

    function testOneOneOffCurve() public pure {
        // a + 1 != 1 + d → off curve.
        assertFalse(BabyJubJub.isOnCurve(1, 1));
    }

    function testXEqualsPRejected() public pure {
        // x >= P guard.
        assertFalse(BabyJubJub.isOnCurve(P, GEN_Y));
    }

    function testYEqualsPRejected() public pure {
        assertFalse(BabyJubJub.isOnCurve(GEN_X, P));
    }

    function testXAbovePRejected() public pure {
        assertFalse(BabyJubJub.isOnCurve(P + 1, GEN_Y));
    }

    function testYAbovePRejected() public pure {
        assertFalse(BabyJubJub.isOnCurve(GEN_X, P + 1));
    }

    function testFuzz_RandomPointsAlmostAlwaysOffCurve(uint256 x, uint256 y) public pure {
        x = x % P;
        y = y % P;
        // Rejecting on-curve coincidences (probability ~1/P) keeps the assert clean.
        if (BabyJubJub.isOnCurve(x, y)) return;
        assertFalse(BabyJubJub.isOnCurve(x, y));
    }

    /// Identity (0, 1) is the trivial low-order point — `[1]·O = O`. Must be
    /// flagged so `AuxValidation` rejects placeholder clue/eph points.
    function testIdentityIsLowOrder() public view {
        assertTrue(BabyJubJub.isLowOrder(0, 1));
    }

    /// Canonical `8·Base` generator of the prime-order subgroup is NOT low
    /// order — used by indexers as a valid sentinel.
    function testBase8IsNotLowOrder() public view {
        assertFalse(BabyJubJub.isLowOrder(BabyJubJub.BASE8_X, BabyJubJub.BASE8_Y));
    }
}
