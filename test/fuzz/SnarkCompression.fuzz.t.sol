// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { SnarkCompression } from "../../src/SnarkCompression.sol";

/// Property-based tests for `SnarkCompression.evaluatePolyAt`. Coefficients are
/// pre-reduced into [0, R) — the library trusts callers to do this (see usage
/// in `MASP._compressPubInputs`).
contract SnarkCompressionFuzzTest is Test {
    uint256 internal constant R = SnarkCompression.R;

    function _toReduced(uint256[4] memory src) internal pure returns (uint256[] memory) {
        uint256[] memory out = new uint256[](src.length);
        for (uint256 i; i < src.length; ++i) {
            out[i] = src[i] % R;
        }
        return out;
    }

    function _toReduced(uint256[6] memory src) internal pure returns (uint256[] memory) {
        uint256[] memory out = new uint256[](src.length);
        for (uint256 i; i < src.length; ++i) {
            out[i] = src[i] % R;
        }
        return out;
    }

    function _toReduced(uint256[8] memory src) internal pure returns (uint256[] memory) {
        uint256[] memory out = new uint256[](src.length);
        for (uint256 i; i < src.length; ++i) {
            out[i] = src[i] % R;
        }
        return out;
    }

    /// p(0) == coefficients[0] for any non-empty poly.
    function testFuzz_EvalAtZero(uint256[8] memory raw) public pure {
        uint256[] memory c = _toReduced(raw);
        assertEq(SnarkCompression.evaluatePolyAt(c, 0), c[0]);
    }

    /// Eval is linear over coefficient vectors:
    ///   eval(a + b, z) == eval(a, z) + eval(b, z) (mod R)
    function testFuzz_Linearity(uint256[6] memory rawA, uint256[6] memory rawB, uint256 z) public pure {
        uint256 zr = z % R;
        uint256[] memory a = _toReduced(rawA);
        uint256[] memory b = _toReduced(rawB);
        uint256[] memory s = new uint256[](a.length);
        for (uint256 i; i < a.length; ++i) {
            s[i] = addmod(a[i], b[i], R);
        }

        uint256 lhs = SnarkCompression.evaluatePolyAt(s, zr);
        uint256 rhs = addmod(SnarkCompression.evaluatePolyAt(a, zr), SnarkCompression.evaluatePolyAt(b, zr), R);
        assertEq(lhs, rhs);
    }

    /// Scalar homogeneity: eval(k * c, z) == k * eval(c, z) (mod R).
    function testFuzz_ScalarHomogeneity(uint256[6] memory raw, uint256 k, uint256 z) public pure {
        uint256 zr = z % R;
        uint256 kr = k % R;
        uint256[] memory c = _toReduced(raw);
        uint256[] memory kc = new uint256[](c.length);
        for (uint256 i; i < c.length; ++i) {
            kc[i] = mulmod(kr, c[i], R);
        }

        assertEq(SnarkCompression.evaluatePolyAt(kc, zr), mulmod(kr, SnarkCompression.evaluatePolyAt(c, zr), R));
    }

    /// Variable-length fuzz against naive Horner reference. Bounded so the
    /// reference loop stays cheap.
    function testFuzz_VariableLengthMatchesReference(uint256[] memory raw, uint256 z) public pure {
        uint256 len = raw.length > 32 ? 32 : raw.length;
        uint256 zr = z % R;
        uint256[] memory c = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            c[i] = raw[i] % R;
        }

        uint256 expected = 0;
        for (uint256 i = c.length; i > 0; --i) {
            expected = addmod(mulmod(expected, zr, R), c[i - 1], R);
        }
        assertEq(SnarkCompression.evaluatePolyAt(c, zr), expected);
    }

    /// Coefficient vectors differing in the constant term disagree at z=0,
    /// confirming distinct polynomials are not collapsed by the evaluation.
    function testFuzz_DistinctConstantTermsDiffer(uint256[4] memory rawA, uint256 deltaConst) public pure {
        deltaConst = bound(deltaConst, 1, R - 1);
        uint256[] memory a = _toReduced(rawA);
        uint256[] memory b = new uint256[](a.length);
        for (uint256 i; i < a.length; ++i) {
            b[i] = a[i];
        }
        b[0] = addmod(a[0], deltaConst, R);
        assertTrue(SnarkCompression.evaluatePolyAt(a, 0) != SnarkCompression.evaluatePolyAt(b, 0));
    }
}
