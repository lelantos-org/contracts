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

    /// Prime-order subgroup generator (`8 * Base` per circomlibjs).
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
    /// `isOnCurve` first. Rejecting these points blocks small-subgroup attacks
    /// on FMD clues and mirrors the in-circuit constraint.
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
}
