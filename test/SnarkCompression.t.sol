// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { SnarkCompression } from "../src/SnarkCompression.sol";

contract SnarkCompressionTest is Test {
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function test_EmptyReturnsZero() public pure {
        uint256[] memory c = new uint256[](0);
        assertEq(SnarkCompression.evaluatePolyAt(c, 12345), 0);
    }

    function test_ConstantPoly() public pure {
        uint256[] memory c = new uint256[](1);
        c[0] = 42;
        assertEq(SnarkCompression.evaluatePolyAt(c, 0), 42);
        assertEq(SnarkCompression.evaluatePolyAt(c, 999), 42);
    }

    function test_LinearAtZero() public pure {
        // p(x) = 7 + 3x → p(0) = 7
        uint256[] memory c = new uint256[](2);
        c[0] = 7;
        c[1] = 3;
        assertEq(SnarkCompression.evaluatePolyAt(c, 0), 7);
    }

    function test_KnownVector() public pure {
        // p(x) = 1 + 2x + 3x^2 + 4x^3, z = 5
        // p(5) = 1 + 10 + 75 + 500 = 586
        uint256[] memory c = new uint256[](4);
        c[0] = 1;
        c[1] = 2;
        c[2] = 3;
        c[3] = 4;
        assertEq(SnarkCompression.evaluatePolyAt(c, 5), 586);
    }

    function test_ReducesModR() public pure {
        // Single coeff at field edge: p(x) = (R-1), z arbitrary → result = R-1 (constant).
        uint256[] memory c = new uint256[](1);
        c[0] = R - 1;
        assertEq(SnarkCompression.evaluatePolyAt(c, 12345), R - 1);
    }

    function test_LargeCoefficientsModR() public pure {
        // p(x) = (R-1) + (R-1) * x, z = 2
        // result = (R-1) + 2*(R-1) mod R = 3*(R-1) mod R = (3R - 3) mod R = R - 3
        uint256[] memory c = new uint256[](2);
        c[0] = R - 1;
        c[1] = R - 1;
        assertEq(SnarkCompression.evaluatePolyAt(c, 2), R - 3);
    }

    /// Fuzz: matches naive Horner reference.
    function testFuzz_MatchesReference(uint256[8] memory raw, uint256 z) public pure {
        uint256[] memory c = new uint256[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            c[i] = raw[i] % R;
        }
        uint256 zr = z % R;

        uint256 expected = 0;
        unchecked {
            for (uint256 i = c.length; i > 0; --i) {
                expected = addmod(mulmod(expected, zr, R), c[i - 1], R);
            }
        }
        assertEq(SnarkCompression.evaluatePolyAt(c, zr), expected);
    }
}
