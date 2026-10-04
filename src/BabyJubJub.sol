// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Baby-Jubjub twisted Edwards curve over the BN254 scalar field:
///   a * x^2 + y^2 = 1 + d * x^2 * y^2
/// with p = the BN254 scalar field order, a = 168700, d = 168696.
/// The curve has cofactor 8; the prime-order subgroup has order
///   L = 2736030358979909402780800718157159386076813972158567259200215660948447373041.
library BabyJubJub {
    uint256 internal constant P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant A = 168700;
    uint256 internal constant D = 168696;

    /// Prime-order subgroup generator (`8 * Base` per circomlibjs). Read only by tests.
    uint256 internal constant BASE8_X = 5299619240641551281634865583518297030282874472190772894086521144482721001553;
    uint256 internal constant BASE8_Y = 16950150798460657717958625567821834550301663161624707787222815936182638968203;

    /// Whether (x, y) lies on Baby-Jubjub. Subgroup membership is not checked.
    function isOnCurve(uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= P || y >= P) return false;
        uint256 xx = mulmod(x, x, P);
        uint256 yy = mulmod(y, y, P);
        uint256 lhs = addmod(mulmod(A, xx, P), yy, P);
        uint256 rhs = addmod(1, mulmod(mulmod(D, xx, P), yy, P), P);
        return lhs == rhs;
    }

    /// Whether (x, y) has order dividing the cofactor 8: the identity or a
    /// small-subgroup point. Requires an on-curve input, so callers must run
    /// `isOnCurve` first. A mixed-order point, of order `2L`, `4L` or `8L`, is
    /// not low-order.
    ///
    /// Decided from the coordinates, with no doubling. The curve is complete
    /// (`a` square, `d` non-square), so its only point of order 2 is (0, -1)
    /// and the points of order dividing 8 form one cyclic group: the identity,
    /// that point, two of order 4 and four of order 8. For an on-curve point:
    ///
    /// - `x == 0` holds exactly for (0, 1) and (0, -1), orders 1 and 2;
    /// - `y == 0` holds exactly for (+-1/sqrt(a), 0), order 4: a doubling's
    ///   x-coordinate is `2xy / (a*x^2 + y^2)`, zero only there or at `x == 0`;
    /// - `y^2 == a*x^2` holds exactly for order 8: a doubling's y-coordinate is
    ///   `(y^2 - a*x^2) / (2 - a*x^2 - y^2)`, so the double then has `y == 0`
    ///   and is one of the two order-4 points.
    ///
    /// `test/fuzz/BabyJubJub.fuzz.t.sol` checks this against `[8]P` computed
    /// with the affine group law.
    function isLowOrder(uint256 x, uint256 y) internal pure returns (bool) {
        if (x == 0 || y == 0) return true;
        return mulmod(y, y, P) == mulmod(A, mulmod(x, x, P), P);
    }

    /// Whether `R == [8]Q`. Requires an on-curve `Q`, so callers must run
    /// `isOnCurve` on it first; `R` needs no prior check.
    ///
    /// The group is `Z_8 x Z_L`, so `[8]Q` lies in the prime-order subgroup for
    /// every on-curve `Q`, and every point of that subgroup is `[8]Q` for
    /// `Q = [8^-1 mod L]R`. A true result therefore holds exactly when `R` is
    /// on the curve and in the prime-order subgroup, given a `Q` chosen for it.
    /// The identity is in that subgroup and is the only such point with
    /// `x == 0`.
    ///
    /// Three projective doublings, compared with `R` by cross-multiplication.
    /// Doubling is complete on this curve, so `z` is never zero.
    ///
    /// `test/fuzz/BabyJubJub.fuzz.t.sol` checks this against `[8]Q` computed
    /// with the affine group law.
    function isEightfold(uint256 qx, uint256 qy, uint256 rx, uint256 ry) internal pure returns (bool ok) {
        assembly ("memory-safe") {
            let p := P
            let z := 1
            for { let i := 0 } lt(i, 3) { i := add(i, 1) } {
                let c := mulmod(qx, qx, p)
                let e := mulmod(qy, qy, p)
                let b := addmod(qx, qy, p)
                // b = 2xy
                b := addmod(mulmod(b, b, p), sub(p, addmod(c, e, p)), p)
                c := mulmod(A, c, p)
                // f = a*x^2 + y^2, j = f - 2z^2
                let f := addmod(c, e, p)
                z := mulmod(z, z, p)
                let j := addmod(f, sub(p, addmod(z, z, p)), p)
                qx := mulmod(b, j, p)
                qy := mulmod(f, addmod(c, sub(p, e), p), p)
                z := mulmod(f, j, p)
            }
            ok := and(and(lt(rx, p), lt(ry, p)), and(eq(qx, mulmod(rx, z, p)), eq(qy, mulmod(ry, z, p))))
        }
    }
}
