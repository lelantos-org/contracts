// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { SnarkCompression } from "../src/SnarkCompression.sol";
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
    BATCH_DOMAIN
} from "../src/verifiers/VerifyingKeys.sol";

/// Pins `VerifyingKeys.sol` against the published verification keys and against
/// its own derived `BATCH_DOMAIN`.
///
/// `VerifyingKeys.sol` transcribes constants whose authoritative form lives in
/// the two snarkjs codegen verifiers. Those are contract-scoped and non-public,
/// so the comparison goes through the committed verification-key JSON.
///
/// A wrong constant makes `BatchedGroth16Verifier` fail closed, which surfaces
/// only in a test running a real proof. A stale `BATCH_DOMAIN` surfaces nowhere
/// else at all: both sides of a batch derive the challenge from the same
/// domain, so an incorrect one still agrees with itself.
contract VerifyingKeysTest is Test {
    string internal constant VK1 = "test/fixtures/verification_key_4x4.json";
    string internal constant VK2 = "test/fixtures/verification_key_tree_update_batch.json";

    string internal vk1;
    string internal vk2;

    function setUp() public {
        vk1 = vm.readFile(VK1);
        vk2 = vm.readFile(VK2);
    }

    function _u(string memory json, string memory path) internal pure returns (uint256) {
        return vm.parseJsonUint(json, path);
    }

    /// Read a G2 point in the order the snarkjs codegen emits it: `(x1, x2)`
    /// then `(y1, y2)`, which is the JSON's `[0][1], [0][0], [1][1], [1][0]`.
    /// The coordinate swap is expressed here once, not at each assertion.
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
    function _assertIC(string memory json, uint256[6] memory expected, string memory what) internal pure {
        for (uint256 i; i < 3; ++i) {
            string memory base = string.concat(".IC[", vm.toString(i), "]");
            assertEq(expected[2 * i], _u(json, string.concat(base, "[0]")), string.concat(what, " IC.x"));
            assertEq(expected[2 * i + 1], _u(json, string.concat(base, "[1]")), string.concat(what, " IC.y"));
        }
    }

    // --- the domain the batched verifier separates its transcript with -------

    /// `BATCH_DOMAIN` is `keccak256(abi.encode(...))` over the thirty key
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
                VK2_DELTA_X1,
                VK2_DELTA_X2,
                VK2_DELTA_Y1,
                VK2_DELTA_Y2,
                VK2_IC0X,
                VK2_IC0Y,
                VK2_IC1X,
                VK2_IC1Y,
                VK2_IC2X,
                VK2_IC2Y
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
        _assertIC(vk1, [VK1_IC0X, VK1_IC0Y, VK1_IC1X, VK1_IC1Y, VK1_IC2X, VK1_IC2Y], "VK1");
    }

    function test_treeUpdateKeysMatchVerificationKey() public view {
        _assertG2(vk2, ".vk_delta_2", [VK2_DELTA_X1, VK2_DELTA_X2, VK2_DELTA_Y1, VK2_DELTA_Y2], "VK2_DELTA");
        _assertIC(vk2, [VK2_IC0X, VK2_IC0Y, VK2_IC1X, VK2_IC1Y, VK2_IC2X, VK2_IC2Y], "VK2");
    }

    /// The two circuits must keep distinct `delta`s. A collision means both keys
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

    /// Both key files must come from the same circuits release.
    function test_fixtureProvenance() public view {
        assertEq(vm.parseJsonString(vk1, ".protocol"), "groth16", "vk1 protocol");
        assertEq(vm.parseJsonString(vk2, ".protocol"), "groth16", "vk2 protocol");
        assertEq(vm.parseJsonString(vk1, ".curve"), "bn128", "vk1 curve");
        assertEq(vm.parseJsonString(vk2, ".curve"), "bn128", "vk2 curve");
        assertEq(vm.parseJsonUint(vk1, ".nPublic"), 2, "vk1 nPublic");
        assertEq(vm.parseJsonUint(vk2, ".nPublic"), 2, "vk2 nPublic");
    }
}
