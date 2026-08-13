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

    /// Identity element of the twisted Edwards form, (0, 1). `[k]·O = O` for
    /// all k.
    function isIdentity(uint256 x, uint256 y) internal pure returns (bool) {
        return x == 0 && y == 1;
    }

    /// True iff (x, y) lies on Baby-Jubjub. Does not check subgroup membership.
    function isOnCurve(uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= P || y >= P) return false;
        uint256 xx = mulmod(x, x, P);
        uint256 yy = mulmod(y, y, P);
        uint256 lhs = addmod(mulmod(A, xx, P), yy, P);
        uint256 rhs = addmod(1, mulmod(mulmod(D, xx, P), yy, P), P);
        return lhs == rhs;
    }

    /// True iff (x, y) has order dividing the cofactor 8, i.e. the identity or a
    /// small-subgroup point. The caller must have checked `isOnCurve` first.
    /// Rejecting these points blocks small-subgroup attacks on FMD clues, and
    /// backs the equivalent in-circuit constraint.
    function isLowOrder(uint256 x, uint256 y) internal pure returns (bool) {
        if (isIdentity(x, y)) return true;
        // Three projective doublings. The formula is complete on Baby-Jubjub
        // (`a` square, `d` non-square), so Z stays nonzero for on-curve inputs.
        (uint256 rx, uint256 ry, uint256 rz) = _doubleProj(x, y, 1);
        (rx, ry, rz) = _doubleProj(rx, ry, rz);
        (rx, ry, rz) = _doubleProj(rx, ry, rz);
        // [8]P is the identity iff (X : Y : Z) = (0 : λ : λ).
        return rx == 0 && ry == rz;
    }

    /// Projective twisted Edwards doubling (dbl-2008-bbjlp), 3M + 4S.
    /// (X : Y : Z) represents affine (X/Z, Y/Z) and requires Z != 0.
    function _doubleProj(uint256 x, uint256 y, uint256 z) private pure returns (uint256 x3, uint256 y3, uint256 z3) {
        uint256 b = addmod(x, y, P);
        b = mulmod(b, b, P); // B = (X+Y)^2
        uint256 c = mulmod(x, x, P); // C = X^2
        uint256 dd = mulmod(y, y, P); // D = Y^2
        uint256 e = mulmod(A, c, P); // E = a*C
        uint256 f = addmod(e, dd, P); // F = E + D
        uint256 h = mulmod(z, z, P); // H = Z^2
        uint256 j = addmod(f, P - mulmod(2, h, P), P); // J = F - 2H
        x3 = mulmod(addmod(b, P - addmod(c, dd, P), P), j, P); // (B-C-D)*J
        y3 = mulmod(f, addmod(e, P - dd, P), P); // F*(E-D)
        z3 = mulmod(f, j, P); // F*J
    }
}
