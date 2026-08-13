// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { SnarkCompression } from "../src/SnarkCompression.sol";

/// External wrapper so `vm.expectRevert` can intercept the internal library
/// revert. `evaluatePolyAt` is `internal` — direct calls don't create a new
/// EVM call frame that Foundry can intercept.
contract SnarkCompressionWrapper {
    function eval(uint256[] calldata c, uint256 z) external pure returns (uint256) {
        return SnarkCompression.evaluatePolyAt(c, z);
    }
}

/// Negative tests for `SnarkCompression.evaluatePolyAt`.
/// The main fuzz suite pre-reduces coefficients with `% R`; these tests verify
/// the out-of-field guard that fires when a caller skips reduction.
contract SnarkCompressionNegTest is Test {
    uint256 internal constant R = SnarkCompression.R;

    SnarkCompressionWrapper wrapper;

    function setUp() public {
        wrapper = new SnarkCompressionWrapper();
    }

    function test_coefficientExactlyR_reverts() public {
        uint256[] memory c = new uint256[](1);
        c[0] = R;
        vm.expectRevert(SnarkCompression.CoefficientOutOfField.selector);
        wrapper.eval(c, 0);
    }

    function test_coefficientRPlusOne_reverts() public {
        uint256[] memory c = new uint256[](1);
        c[0] = R + 1;
        vm.expectRevert(SnarkCompression.CoefficientOutOfField.selector);
        wrapper.eval(c, 0);
    }

    function test_coefficientMaxUint256_reverts() public {
        uint256[] memory c = new uint256[](1);
        c[0] = type(uint256).max;
        vm.expectRevert(SnarkCompression.CoefficientOutOfField.selector);
        wrapper.eval(c, 0);
    }

    /// Out-of-field coefficient at a later position (not index 0) — Horner
    /// eval visits coefficients in reverse (highest degree first), so the
    /// leading coefficient is checked last; it must still revert.
    function test_outOfField_inHigherDegreeCoeff_reverts() public {
        uint256[] memory c = new uint256[](3);
        c[0] = 1; // valid
        c[1] = 2; // valid
        c[2] = R; // invalid leading coeff
        vm.expectRevert(SnarkCompression.CoefficientOutOfField.selector);
        wrapper.eval(c, 5);
    }

    /// Boundary: R-1 is the maximum valid coefficient.
    function test_coefficientRMinusOne_accepted() public view {
        uint256[] memory c = new uint256[](1);
        c[0] = R - 1;
        uint256 result = wrapper.eval(c, 0);
        assertEq(result, R - 1);
    }

    /// Fuzz: any coefficient >= R must revert.
    function testFuzz_outOfField_alwaysReverts(uint256 coeff) public {
        vm.assume(coeff >= R);
        uint256[] memory c = new uint256[](1);
        c[0] = coeff;
        vm.expectRevert(SnarkCompression.CoefficientOutOfField.selector);
        wrapper.eval(c, 0);
    }

    /// Fuzz: any in-field coefficient must not revert; result must be in [0, R).
    function testFuzz_inField_neverReverts(uint256 coeff, uint256 z) public view {
        coeff = coeff % R;
        z = z % R;
        uint256[] memory c = new uint256[](1);
        c[0] = coeff;
        uint256 result = wrapper.eval(c, z);
        assertLt(result, R);
    }
}
