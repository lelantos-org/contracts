// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// Baby-Jubjub twisted Edwards curve over BN254 scalar field.
///   a * x^2 + y^2 = 1 + d * x^2 * y^2
/// p = BN254 scalar field order
/// a = 168700
/// d = 168696
/// Curve has cofactor 8; the prime-order subgroup has order
///   L = 2736030358979909402780800718157159386076813972158567259200215660948447373041.
library BabyJubJub {
    uint256 internal constant P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant A = 168700;
    uint256 internal constant D = 168696;

    /// Prime-order subgroup generator (`8 * Base` per circomlibjs).
    uint256 internal constant BASE8_X = 5299619240641551281634865583518297030282874472190772894086521144482721001553;
    uint256 internal constant BASE8_Y = 16950150798460657717958625567821834550301663161624707787222815936182638968203;

    /// Identity element on twisted Edwards = (0, 1). [k]·O = O for all k.
    function isIdentity(uint256 x, uint256 y) internal pure returns (bool) {
        return x == 0 && y == 1;
    }

    /// True iff (x, y) on Baby-Jubjub. Excludes subgroup membership.
    function isOnCurve(uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= P || y >= P) return false;
        uint256 xx = mulmod(x, x, P);
        uint256 yy = mulmod(y, y, P);
        uint256 lhs = addmod(mulmod(A, xx, P), yy, P);
        uint256 rhs = addmod(1, mulmod(mulmod(D, xx, P), yy, P), P);
        return lhs == rhs;
    }

    /// True iff (x, y) has order dividing cofactor 8 (identity or a
    /// small-subgroup point). Caller MUST have checked `isOnCurve` first.
    /// Rejecting these blocks small-subgroup attacks on FMD clues.
    /// Defense-in-depth backing the in-circuit constraint.
    function isLowOrder(uint256 x, uint256 y) internal view returns (bool) {
        if (isIdentity(x, y)) return true;
        (uint256 rx, uint256 ry) = _mulBy8(x, y);
        return rx == 0 && ry == 1;
    }

    /// Affine doubling on the twisted Edwards curve; one inverse covers both
    /// denominators via the product trick.
    function _double(uint256 x, uint256 y) private view returns (uint256 x3, uint256 y3) {
        uint256 axx = mulmod(A, mulmod(x, x, P), P);
        uint256 yy = mulmod(y, y, P);
        // d1 = a*x^2 + y^2
        uint256 d1 = addmod(axx, yy, P);
        // d2 = 2 - a*x^2 - y^2  (mod P)
        uint256 d2 = addmod(2, P - addmod(axx, yy, P) % P, P) % P;

        // Joint inverse: inv12 = (d1*d2)^-1. 1/d1 = d2*inv12; 1/d2 = d1*inv12.
        uint256 prod = mulmod(d1, d2, P);
        uint256 inv12 = _expmod(prod, P - 2, P);
        uint256 invD1 = mulmod(d2, inv12, P);
        uint256 invD2 = mulmod(d1, inv12, P);

        // numerator(x3) = 2*x*y; numerator(y3) = y^2 - a*x^2
        uint256 numX = mulmod(2, mulmod(x, y, P), P);
        uint256 numY = addmod(yy, P - axx % P, P) % P;
        x3 = mulmod(numX, invD1, P);
        y3 = mulmod(numY, invD2, P);
    }

    function _mulBy8(uint256 x, uint256 y) private view returns (uint256 rx, uint256 ry) {
        (rx, ry) = _double(x, y);
        (rx, ry) = _double(rx, ry);
        (rx, ry) = _double(rx, ry);
    }

    /// Modular exponentiation via the bigModExp precompile (0x05).
    function _expmod(uint256 b, uint256 e, uint256 m) private view returns (uint256 r) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, 0x20)
            mstore(add(p, 0x20), 0x20)
            mstore(add(p, 0x40), 0x20)
            mstore(add(p, 0x60), b)
            mstore(add(p, 0x80), e)
            mstore(add(p, 0xa0), m)
            if iszero(staticcall(gas(), 0x05, p, 0xc0, p, 0x20)) { revert(0, 0) }
            r := mload(p)
        }
    }
}
