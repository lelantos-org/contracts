// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { BabyJubJub } from "../../src/BabyJubJub.sol";

/// Fuzz suite for `BabyJubJub.isLowOrder`, which decides `[8]P == O` from the
/// coordinates alone (`x == 0`, `y == 0` or `y^2 == a*x^2`), and for
/// `BabyJubJub.isEightfold`, which decides `R == [8]Q` by projective doubling.
///
/// Ground truth is an independent affine implementation of the twisted Edwards
/// group law (complete addition + modexp inversion). Points are sampled by
/// scalar-multiplying the full-order circomlib generator, so the fuzz covers
/// every coset of the prime-order subgroup, including mixed-order points.
contract BabyJubJubFuzzTest is Test {
    uint256 internal constant P = BabyJubJub.P;
    uint256 internal constant A = BabyJubJub.A;
    uint256 internal constant D = BabyJubJub.D;

    /// Prime-order subgroup order.
    uint256 internal constant L =
        2_736_030_358_979_909_402_780_800_718_157_159_386_076_813_972_158_567_259_200_215_660_948_447_373_041;

    /// Full group order (cofactor 8 times L).
    uint256 internal constant FULL_ORDER = 8 * L;

    /// circomlib `Generator`: order-8L point with `BASE8 = [8]·G`.
    uint256 internal constant G_X =
        995_203_441_582_195_749_578_291_179_787_384_436_505_546_430_278_305_826_713_579_947_235_728_471_134;
    uint256 internal constant G_Y =
        5_472_060_717_959_818_805_561_601_436_314_318_772_137_091_100_104_008_585_924_551_046_643_952_123_905;

    // -----------------------------------------------------------------------
    // Fuzz properties
    // -----------------------------------------------------------------------

    /// Differential: for any point in the full group, the coordinate test in
    /// `isLowOrder` agrees with the affine reference `[8]P == identity`.
    function testFuzz_isLowOrder_matchesAffineReference(uint256 k) public view {
        k = bound(k, 0, FULL_ORDER - 1);
        (uint256 x, uint256 y) = _refMul(k, G_X, G_Y);
        assertTrue(BabyJubJub.isOnCurve(x, y), "reference produced off-curve point");
        assertEq(BabyJubJub.isLowOrder(x, y), _refIsLowOrder(x, y), "isLowOrder disagrees with affine reference");
    }

    /// Points in the prime-order subgroup (excluding identity) are never
    /// low-order.
    function testFuzz_primeOrderPoint_neverLowOrder(uint256 k) public view {
        k = bound(k, 1, L - 1);
        (uint256 x, uint256 y) = _refMul(k, BabyJubJub.BASE8_X, BabyJubJub.BASE8_Y);
        assertTrue(BabyJubJub.isOnCurve(x, y), "reference produced off-curve point");
        assertFalse(BabyJubJub.isLowOrder(x, y), "prime-order point flagged as low-order");
    }

    /// The seven non-identity small-subgroup points `[j*L]·G` (j in 1..7) are
    /// all detected. Random scalars almost never land on these, so this test
    /// covers the true branch explicitly.
    function testFuzz_smallSubgroupPoint_alwaysDetected(uint8 j) public view {
        uint256 jb = bound(uint256(j), 1, 7);
        (uint256 x, uint256 y) = _refMul(jb * L, G_X, G_Y);
        assertTrue(BabyJubJub.isOnCurve(x, y), "reference produced off-curve point");
        assertTrue(BabyJubJub.isLowOrder(x, y), "small-subgroup point not detected");
    }

    /// Mixed-order points (prime-order component + small-subgroup component)
    /// satisfy `[8]P != identity` and are not flagged: the check does not
    /// over-reject cofactor cosets.
    function testFuzz_mixedOrderPoint_notLowOrder(uint256 k, uint8 j) public view {
        k = bound(k, 1, L - 1);
        uint256 jb = bound(uint256(j), 1, 7);
        (uint256 px, uint256 py) = _refMul(k, BabyJubJub.BASE8_X, BabyJubJub.BASE8_Y);
        (uint256 sx, uint256 sy) = _refMul(jb * L, G_X, G_Y);
        (uint256 x, uint256 y) = _refAdd(px, py, sx, sy);
        assertTrue(BabyJubJub.isOnCurve(x, y), "reference produced off-curve point");
        assertFalse(BabyJubJub.isLowOrder(x, y), "mixed-order point flagged as low-order");
    }

    /// Point negation `-(x, y) = (P - x, y)` preserves order, so the verdict
    /// is negation-invariant.
    function testFuzz_isLowOrder_negationInvariant(uint256 k) public view {
        k = bound(k, 0, FULL_ORDER - 1);
        (uint256 x, uint256 y) = _refMul(k, G_X, G_Y);
        uint256 negX = x == 0 ? 0 : P - x;
        assertEq(BabyJubJub.isLowOrder(x, y), BabyJubJub.isLowOrder(negX, y), "verdict not negation-invariant");
    }

    /// Differential: for any two points of the full group, `isEightfold`
    /// agrees with the affine reference `[8]Q == R`.
    function testFuzz_isEightfold_matchesAffineReference(uint256 kq, uint256 kr) public view {
        (uint256 qx, uint256 qy) = _refMul(bound(kq, 0, FULL_ORDER - 1), G_X, G_Y);
        (uint256 rx, uint256 ry) = _refMul(bound(kr, 0, FULL_ORDER - 1), G_X, G_Y);
        (uint256 ex, uint256 ey) = _refMul(8, qx, qy);
        assertEq(BabyJubJub.isEightfold(qx, qy, rx, ry), ex == rx && ey == ry, "isEightfold disagrees with reference");
    }

    /// Completeness: every prime-order point `R` is accepted with the witness
    /// `Q = [8^-1 mod L]R`, and with that witness shifted by any torsion point.
    function testFuzz_isEightfold_acceptsSubgroupWithWitness(uint256 k, uint8 j) public view {
        k = bound(k, 0, L - 1);
        (uint256 rx, uint256 ry) = _refMul(k, BabyJubJub.BASE8_X, BabyJubJub.BASE8_Y);
        // `[k]G` is a witness for `[k]BASE8 = [8k]G`; adding `[j*L]G` moves it
        // through the eight preimages of `R` under multiplication by 8.
        (uint256 qx, uint256 qy) = _refMul(k + bound(uint256(j), 0, 7) * L, G_X, G_Y);
        assertTrue(BabyJubJub.isOnCurve(qx, qy), "reference produced off-curve witness");
        assertTrue(BabyJubJub.isEightfold(qx, qy, rx, ry), "subgroup point rejected with a valid witness");
    }

    /// Soundness: a point outside the prime-order subgroup is rejected for
    /// every on-curve witness. `R = [k]G` with `8` not dividing `k` is such a
    /// point; the witness ranges over the full group.
    function testFuzz_isEightfold_rejectsOutsideSubgroup(uint256 k, uint256 kq) public view {
        k = bound(k, 0, FULL_ORDER - 1);
        vm.assume(k % 8 != 0);
        (uint256 rx, uint256 ry) = _refMul(k, G_X, G_Y);
        (uint256 qx, uint256 qy) = _refMul(bound(kq, 0, FULL_ORDER - 1), G_X, G_Y);
        assertFalse(BabyJubJub.isEightfold(qx, qy, rx, ry), "point outside the subgroup accepted");
        // The witness an honest sender would derive for the subgroup part.
        (qx, qy) = _refMul(k / 8, G_X, G_Y);
        assertFalse(BabyJubJub.isEightfold(qx, qy, rx, ry), "point outside the subgroup accepted");
    }

    /// A coordinate of `R` at or above `P` is rejected, including the alias
    /// `x + P` of an accepted coordinate.
    function testFuzz_isEightfold_rejectsNonCanonicalR(uint256 k) public view {
        k = bound(k, 1, L - 1);
        (uint256 rx, uint256 ry) = _refMul(k, BabyJubJub.BASE8_X, BabyJubJub.BASE8_Y);
        (uint256 qx, uint256 qy) = _refMul(k, G_X, G_Y);
        assertTrue(BabyJubJub.isEightfold(qx, qy, rx, ry));
        assertFalse(BabyJubJub.isEightfold(qx, qy, rx + P, ry), "aliased x accepted");
        assertFalse(BabyJubJub.isEightfold(qx, qy, rx, ry + P), "aliased y accepted");
    }

    // -----------------------------------------------------------------------
    // Affine reference implementation (independent of the library internals)
    // -----------------------------------------------------------------------

    /// `[8]P == (0, 1)` via the affine group law.
    function _refIsLowOrder(uint256 x, uint256 y) internal view returns (bool) {
        (uint256 rx, uint256 ry) = _refMul(8, x, y);
        return rx == 0 && ry == 1;
    }

    /// Double-and-add scalar multiplication using the complete affine
    /// addition law (valid for doubling on twisted Edwards curves).
    function _refMul(uint256 k, uint256 x, uint256 y) internal view returns (uint256 rx, uint256 ry) {
        (rx, ry) = (0, 1);
        while (k != 0) {
            if (k & 1 == 1) (rx, ry) = _refAdd(rx, ry, x, y);
            (x, y) = _refAdd(x, y, x, y);
            k >>= 1;
        }
    }

    /// Complete twisted Edwards addition:
    ///   x3 = (x1*y2 + y1*x2) / (1 + d*x1*x2*y1*y2)
    ///   y3 = (y1*y2 - a*x1*x2) / (1 - d*x1*x2*y1*y2)
    /// Denominators are nonzero for on-curve inputs (`d` is a non-square).
    function _refAdd(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal view returns (uint256 x3, uint256 y3) {
        uint256 x1x2 = mulmod(x1, x2, P);
        uint256 y1y2 = mulmod(y1, y2, P);
        uint256 dxy = mulmod(D, mulmod(x1x2, y1y2, P), P);
        uint256 numX = addmod(mulmod(x1, y2, P), mulmod(y1, x2, P), P);
        uint256 numY = addmod(y1y2, P - mulmod(A, x1x2, P), P);
        x3 = mulmod(numX, _inv(addmod(1, dxy, P)), P);
        y3 = mulmod(numY, _inv(addmod(1, P - dxy, P)), P);
    }

    /// Modular inverse via Fermat: v^(P-2) mod P, using the bigModExp
    /// precompile (0x05).
    function _inv(uint256 v) internal view returns (uint256 r) {
        uint256 e = P - 2;
        uint256 m = P;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, 0x20)
            mstore(add(p, 0x20), 0x20)
            mstore(add(p, 0x40), 0x20)
            mstore(add(p, 0x60), v)
            mstore(add(p, 0x80), e)
            mstore(add(p, 0xa0), m)
            if iszero(staticcall(gas(), 0x05, p, 0xc0, p, 0x20)) { revert(0, 0) }
            r := mload(p)
        }
    }
}
