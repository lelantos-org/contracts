// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { SnarkCompression } from "../../src/SnarkCompression.sol";
import {
    SNARK_R,
    SNARK_Q,
    VK_ALPHA_X,
    VK_ALPHA_Y,
    VK_BETA_X1,
    VK_BETA_X2,
    VK_BETA_Y1,
    VK_BETA_Y2,
    VK_GAMMA_X1,
    VK_GAMMA_X2,
    VK_GAMMA_Y1,
    VK_GAMMA_Y2,
    VK1_DELTA_X1,
    VK1_DELTA_X2,
    VK1_DELTA_Y1,
    VK1_DELTA_Y2,
    VK1_IC0X,
    VK1_IC0Y,
    VK1_IC1X,
    VK1_IC1Y,
    VK1_IC2X,
    VK1_IC2Y,
    VK1_IC3X,
    VK1_IC3Y,
    VK2_DELTA_X1,
    VK2_DELTA_X2,
    VK2_DELTA_Y1,
    VK2_DELTA_Y2,
    VK2_IC0X,
    VK2_IC0Y,
    VK2_IC1X,
    VK2_IC1Y,
    VK2_IC2X,
    VK2_IC2Y,
    VK2_IC3X,
    VK2_IC3Y,
    BATCH_DOMAIN
} from "../../src/verifiers/VerifyingKeys.sol";

/// Pins `VerifyingKeys.sol` against the committed verification keys and
/// against its own derived `BATCH_DOMAIN`. This shows the constants and the
/// JSON agree, not that either is a ceremony output: where the keys come from
/// is recorded in `test/fixtures/README.md`.
///
/// `VerifyingKeys.sol` transcribes constants whose authoritative form lives in
/// the two snarkjs codegen verifiers. Those are contract-scoped and non-public,
/// so the comparison goes through the committed verification-key JSON.
///
/// A wrong constant makes `BatchedGroth16Verifier` fail closed, which surfaces
/// only in a test running a real proof. A stale `BATCH_DOMAIN` is detected only
/// here: both sides of a batch derive the challenge from the same domain, so an
/// incorrect one is still self-consistent.
contract VerifyingKeysTest is Test {
    string internal constant VK1 = "test/fixtures/verification_key_4x6.json";
    string internal constant VK2 = "test/fixtures/verification_key_tree_update_batch.json";

    /// Points in a key's `IC`: the constant term, then one per public signal
    /// `[y, digest, z]`.
    uint256 internal constant IC_POINTS = 4;

    string internal vk1;
    string internal vk2;

    function setUp() public {
        vk1 = vm.readFile(VK1);
        vk2 = vm.readFile(VK2);
    }

    function _u(string memory json, string memory path) internal pure returns (uint256) {
        return vm.parseJsonUint(json, path);
    }

    /// Reads a G2 point in the order the snarkjs codegen emits it: `(x1, x2)`
    /// then `(y1, y2)`, which is the JSON's `[0][1], [0][0], [1][1], [1][0]`.
    /// The coordinate swap is expressed once here rather than at each assertion.
    function _g2(string memory json, string memory field)
        internal
        pure
        returns (uint256 x1, uint256 x2, uint256 y1, uint256 y2)
    {
        x1 = _u(json, string.concat(field, "[0][1]"));
        x2 = _u(json, string.concat(field, "[0][0]"));
        y1 = _u(json, string.concat(field, "[1][1]"));
        y2 = _u(json, string.concat(field, "[1][0]"));
    }

    function _assertG2(string memory json, string memory field, uint256[4] memory expected, string memory what)
        internal
        pure
    {
        (uint256 x1, uint256 x2, uint256 y1, uint256 y2) = _g2(json, field);
        assertEq(expected[0], x1, string.concat(what, ".x1"));
        assertEq(expected[1], x2, string.concat(what, ".x2"));
        assertEq(expected[2], y1, string.concat(what, ".y1"));
        assertEq(expected[3], y2, string.concat(what, ".y2"));
    }

    /// `IC` is G1, so it needs no reordering: `[i][0]` is x, `[i][1]` is y.
    /// The length is asserted first: a key for another signal count would
    /// otherwise match on its leading points.
    function _assertIC(string memory json, uint256[2 * IC_POINTS] memory expected, string memory what) internal view {
        assertEq(_icLength(json), IC_POINTS, string.concat(what, " IC length"));
        for (uint256 i; i < IC_POINTS; ++i) {
            string memory base = string.concat(".IC[", vm.toString(i), "]");
            assertEq(expected[2 * i], _u(json, string.concat(base, "[0]")), string.concat(what, " IC.x"));
            assertEq(expected[2 * i + 1], _u(json, string.concat(base, "[1]")), string.concat(what, " IC.y"));
        }
    }

    function _icLength(string memory json) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(".IC[", vm.toString(n), "]"))) {
            ++n;
        }
    }

    /// Each circuit's `IC` block as `VerifyingKeys.sol` transcribes it, `(x, y)`
    /// per point.
    function _ic1() internal pure returns (uint256[2 * IC_POINTS] memory) {
        return [VK1_IC0X, VK1_IC0Y, VK1_IC1X, VK1_IC1Y, VK1_IC2X, VK1_IC2Y, VK1_IC3X, VK1_IC3Y];
    }

    function _ic2() internal pure returns (uint256[2 * IC_POINTS] memory) {
        return [VK2_IC0X, VK2_IC0Y, VK2_IC1X, VK2_IC1Y, VK2_IC2X, VK2_IC2Y, VK2_IC3X, VK2_IC3Y];
    }

    // --- the domain the batched verifier separates its transcript with -------

    /// `BATCH_DOMAIN` is `keccak256(abi.encode(...))` over the thirty-four key
    /// constants in a fixed order, held as a literal because Solidity cannot
    /// fold that into a compile-time `constant`. Recomputing it here fails the
    /// suite when a key changes without the domain being regenerated.
    function test_batchDomainIsKeccakOfKeys() public pure {
        bytes32 expected = keccak256(
            abi.encode(
                VK_ALPHA_X,
                VK_ALPHA_Y,
                VK_BETA_X1,
                VK_BETA_X2,
                VK_BETA_Y1,
                VK_BETA_Y2,
                VK_GAMMA_X1,
                VK_GAMMA_X2,
                VK_GAMMA_Y1,
                VK_GAMMA_Y2,
                VK1_DELTA_X1,
                VK1_DELTA_X2,
                VK1_DELTA_Y1,
                VK1_DELTA_Y2,
                VK1_IC0X,
                VK1_IC0Y,
                VK1_IC1X,
                VK1_IC1Y,
                VK1_IC2X,
                VK1_IC2Y,
                VK1_IC3X,
                VK1_IC3Y,
                VK2_DELTA_X1,
                VK2_DELTA_X2,
                VK2_DELTA_Y1,
                VK2_DELTA_Y2,
                VK2_IC0X,
                VK2_IC0Y,
                VK2_IC1X,
                VK2_IC1Y,
                VK2_IC2X,
                VK2_IC2Y,
                VK2_IC3X,
                VK2_IC3Y
            )
        );
        assertEq(BATCH_DOMAIN, expected, "BATCH_DOMAIN is stale: recompute it from the current constants");
    }

    // --- shared alpha / beta / gamma ----------------------------------------

    /// The six-pairing fold requires the two circuits to share `alpha`, `beta`
    /// and `gamma` as group elements: that is what collapses two
    /// `e(alpha, beta)` terms into one and two `e(PI, gamma)` terms into one.
    /// A rebuild against a different ptau breaks the sharing, after which the
    /// batched verifier rejects every proof.
    function test_sharedKeysAreActuallyShared() public view {
        assertEq(_u(vk1, ".vk_alpha_1[0]"), _u(vk2, ".vk_alpha_1[0]"), "alpha.x diverged");
        assertEq(_u(vk1, ".vk_alpha_1[1]"), _u(vk2, ".vk_alpha_1[1]"), "alpha.y diverged");
        _assertSameG2(".vk_beta_2", "beta");
        _assertSameG2(".vk_gamma_2", "gamma");
    }

    function _assertSameG2(string memory field, string memory what) private view {
        (uint256 ax1, uint256 ax2, uint256 ay1, uint256 ay2) = _g2(vk1, field);
        (uint256 bx1, uint256 bx2, uint256 by1, uint256 by2) = _g2(vk2, field);
        assertEq(ax1, bx1, string.concat(what, ".x1 diverged"));
        assertEq(ax2, bx2, string.concat(what, ".x2 diverged"));
        assertEq(ay1, by1, string.concat(what, ".y1 diverged"));
        assertEq(ay2, by2, string.concat(what, ".y2 diverged"));
    }

    function test_sharedKeysMatchVerificationKey() public view {
        assertEq(VK_ALPHA_X, _u(vk1, ".vk_alpha_1[0]"), "VK_ALPHA_X");
        assertEq(VK_ALPHA_Y, _u(vk1, ".vk_alpha_1[1]"), "VK_ALPHA_Y");
        _assertG2(vk1, ".vk_beta_2", [VK_BETA_X1, VK_BETA_X2, VK_BETA_Y1, VK_BETA_Y2], "VK_BETA");
        _assertG2(vk1, ".vk_gamma_2", [VK_GAMMA_X1, VK_GAMMA_X2, VK_GAMMA_Y1, VK_GAMMA_Y2], "VK_GAMMA");
    }

    // --- per-circuit delta and IC -------------------------------------------

    function test_transactKeysMatchVerificationKey() public view {
        _assertG2(vk1, ".vk_delta_2", [VK1_DELTA_X1, VK1_DELTA_X2, VK1_DELTA_Y1, VK1_DELTA_Y2], "VK1_DELTA");
        _assertIC(vk1, _ic1(), "VK1");
    }

    function test_treeUpdateKeysMatchVerificationKey() public view {
        _assertG2(vk2, ".vk_delta_2", [VK2_DELTA_X1, VK2_DELTA_X2, VK2_DELTA_Y1, VK2_DELTA_Y2], "VK2_DELTA");
        _assertIC(vk2, _ic2(), "VK2");
    }

    /// Within a key the `IC` points are pairwise distinct, and the two keys
    /// differ at every point. This is what makes a transposition of
    /// `[y, digest, z]`, or one circuit's signals under the other's key, a
    /// different commitment rather than the same one.
    function test_icPointsAreDistinct() public pure {
        uint256[2 * IC_POINTS] memory k1 = _ic1();
        uint256[2 * IC_POINTS] memory k2 = _ic2();
        for (uint256 i; i < IC_POINTS; ++i) {
            for (uint256 j = i + 1; j < IC_POINTS; ++j) {
                assertTrue(k1[2 * i] != k1[2 * j] || k1[2 * i + 1] != k1[2 * j + 1], "VK1 IC points coincide");
                assertTrue(k2[2 * i] != k2[2 * j] || k2[2 * i + 1] != k2[2 * j + 1], "VK2 IC points coincide");
            }
            assertTrue(k1[2 * i] != k2[2 * i] || k1[2 * i + 1] != k2[2 * i + 1], "the two keys share an IC point");
        }
    }

    /// The two circuits have distinct `delta`s. A collision means both keys
    /// came from the same phase-2 output.
    function test_deltasAreDistinct() public pure {
        assertTrue(
            VK1_DELTA_X1 != VK2_DELTA_X1 || VK1_DELTA_X2 != VK2_DELTA_X2 || VK1_DELTA_Y1 != VK2_DELTA_Y1
                || VK1_DELTA_Y2 != VK2_DELTA_Y2,
            "the two circuits share a delta"
        );
    }

    // --- moduli --------------------------------------------------------------

    function test_moduliAgreeWithCompression() public pure {
        assertEq(SNARK_R, SnarkCompression.R, "scalar field disagrees with SnarkCompression");
        assertTrue(SNARK_Q > SNARK_R, "base field must exceed the scalar field");
    }

    // --- provenance ----------------------------------------------------------

    /// Both key files are Groth16 over bn128 with three public inputs,
    /// `[y, digest, z]`, and so four `IC` points.
    function test_fixtureProvenance() public view {
        assertEq(vm.parseJsonString(vk1, ".protocol"), "groth16", "vk1 protocol");
        assertEq(vm.parseJsonString(vk2, ".protocol"), "groth16", "vk2 protocol");
        assertEq(vm.parseJsonString(vk1, ".curve"), "bn128", "vk1 curve");
        assertEq(vm.parseJsonString(vk2, ".curve"), "bn128", "vk2 curve");
        assertEq(vm.parseJsonUint(vk1, ".nPublic"), 3, "vk1 nPublic");
        assertEq(vm.parseJsonUint(vk2, ".nPublic"), 3, "vk2 nPublic");
        assertEq(_icLength(vk1), IC_POINTS, "vk1 IC length");
        assertEq(_icLength(vk2), IC_POINTS, "vk2 IC length");
    }
}
