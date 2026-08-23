// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../src/libs/PubInputs.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";

contract TubCompressHarness {
    function compress(PubInputs.TreeUpdateBatch calldata tpi) external pure returns (uint256[2] memory) {
        return PubInputs.compress(tpi);
    }
}

/// Verifies real Groth16 proofs against the deployed `tree_update_batch`
/// verifier, and pins the public-signal order the contract feeds it.
///
/// Layout tests establish only that the coefficient vector is assembled
/// correctly. This runs a proof through the verifier, so a verifier keyed to a
/// different ceremony, or a `(y, z)` ordering flipped on one side, is caught
/// here rather than in production.
///
/// Proofs come from `script/fixtures/gen_proof_fixture.sh`, which proves the
/// published witness vectors against the release artifacts and asserts each
/// proof's public signals against the vector's `(y, z)` before writing. Groth16
/// proving is randomized: regenerating yields different but equally valid proof
/// triples over the same public signals.
contract TreeUpdateBatchVerifierVectorTest is Test {
    string internal constant PROOFS = "test/fixtures/tree_update_batch_proof.json";
    string internal constant VECTOR = "test/fixtures/tree_update_batch_vector.json";
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant N = 3;

    TreeUpdateBatchGroth16Verifier internal verifier;
    TubCompressHarness internal h;
    string internal proofs;
    string internal vector;

    function setUp() public {
        verifier = new TreeUpdateBatchGroth16Verifier();
        h = new TubCompressHarness();
        proofs = vm.readFile(PROOFS);
        vector = vm.readFile(VECTOR);
    }

    function _p(uint256 i) internal pure returns (string memory) {
        return string.concat(".proofs[", vm.toString(i), "]");
    }

    function _w(uint256 i, string memory field) internal view returns (uint256) {
        return vm.parseJsonUint(vector, string.concat(".vectors[", vm.toString(i), "].witness", field));
    }

    function _proof(uint256 i)
        internal
        view
        returns (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[2] memory pub)
    {
        string memory base = _p(i);
        uint256[] memory av = vm.parseJsonUintArray(proofs, string.concat(base, ".a"));
        uint256[] memory b0 = vm.parseJsonUintArray(proofs, string.concat(base, ".b[0]"));
        uint256[] memory b1 = vm.parseJsonUintArray(proofs, string.concat(base, ".b[1]"));
        uint256[] memory cv = vm.parseJsonUintArray(proofs, string.concat(base, ".c"));
        uint256[] memory pv = vm.parseJsonUintArray(proofs, string.concat(base, ".pubSignals"));
        a = [av[0], av[1]];
        b = [[b0[0], b0[1]], [b1[0], b1[1]]];
        c = [cv[0], cv[1]];
        pub = [pv[0], pv[1]];
    }

    /// The proof fixture must have been generated from the vector this repo
    /// also pins the layout against, and at the deployed shape.
    function test_fixtureProvenance() public view {
        assertEq(vm.parseJsonString(proofs, ".source.template"), "TreeUpdateBatch(10, 4)", "template");
        assertEq(
            vm.parseJsonString(proofs, ".source.layoutDigest"),
            vm.parseJsonString(vector, ".circuit.layoutDigest"),
            "layout digest must match the witness vector"
        );
        assertEq(vm.parseJsonString(proofs, ".source.vector"), "tree-update-batch-4.json", "vector name");
    }

    function _accepts(uint256 i) internal view {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[2] memory pub) = _proof(i);
        assertTrue(verifier.verifyProof(a, b, c, pub), "vector proof must verify");
    }

    function test_vector0_singleDepositEmptyTree() public view {
        _accepts(0);
    }

    function test_vector1_oddThreeLeafBatch() public view {
        _accepts(1);
    }

    function test_vector2_mixedBatchNonzeroStart() public view {
        _accepts(2);
    }

    /// The circuit's public signals are the output `y` first, then the public
    /// input `z`; `PubInputs.compress` returns them in exactly that order. A
    /// verifier keyed to the opposite order would accept the swap.
    function test_revert_swappedPublicSignals() public view {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[2] memory pub) = _proof(0);
        assertTrue(pub[0] != pub[1], "signals must differ for the swap to be meaningful");
        assertFalse(verifier.verifyProof(a, b, c, [pub[1], pub[0]]), "swapped (z, y) must not verify");
    }

    /// The end-to-end binding: the struct the contract receives, compressed by
    /// the contract's own code path, must be what the proof commits to.
    function test_compressOfWitnessMatchesProofSignals() public view {
        for (uint256 v = 0; v < N; v++) {
            PubInputs.TreeUpdateBatch memory tpi;
            tpi.oldRoot = bytes32(_w(v, ".old_root"));
            tpi.newRoot = bytes32(_w(v, ".new_root"));
            tpi.startIndex = uint64(_w(v, ".start_index"));
            tpi.actualCount = uint64(_w(v, ".actual_count"));
            for (uint256 k = 0; k < PubInputs.MAX_L_BATCH; k++) {
                string memory idx = string.concat("[", vm.toString(k), "]");
                tpi.cms[k] = bytes32(_w(v, string.concat(".cms", idx)));
                tpi.cvDeps[k][0] = _w(v, string.concat(".cv_dep", idx, "[0]"));
                tpi.cvDeps[k][1] = _w(v, string.concat(".cv_dep", idx, "[1]"));
                tpi.leafAsset[k] = uint64(_w(v, string.concat(".leaf_asset", idx)));
                tpi.leafPublicIn[k] = uint64(_w(v, string.concat(".leaf_public_in", idx)));
                tpi.isDeposit[k] = uint8(_w(v, string.concat(".is_deposit", idx)));
            }

            (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[2] memory pub) = _proof(v);
            uint256[2] memory got = h.compress(tpi);
            assertEq(got[0], pub[0], "compressed y must equal the proof's first public signal");
            assertEq(got[1], pub[1], "compressed z must equal the proof's second public signal");
            assertTrue(verifier.verifyProof(a, b, c, got), "proof must verify against contract-compressed signals");
        }
    }

    /// A batch header the depositor did not prove — one extra leaf slot claimed
    /// — moves `z` and must fail. Covers the case the layout tests cannot: a
    /// correct layout paired with a proof for different data.
    function test_revert_tamperedHeader() public view {
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = bytes32(_w(0, ".old_root"));
        tpi.newRoot = bytes32(_w(0, ".new_root"));
        tpi.startIndex = uint64(_w(0, ".start_index"));
        tpi.actualCount = uint64(_w(0, ".actual_count")) + 1;
        for (uint256 k = 0; k < PubInputs.MAX_L_BATCH; k++) {
            string memory idx = string.concat("[", vm.toString(k), "]");
            tpi.cms[k] = bytes32(_w(0, string.concat(".cms", idx)));
            tpi.cvDeps[k][0] = _w(0, string.concat(".cv_dep", idx, "[0]"));
            tpi.cvDeps[k][1] = _w(0, string.concat(".cv_dep", idx, "[1]"));
            tpi.leafAsset[k] = uint64(_w(0, string.concat(".leaf_asset", idx)));
            tpi.leafPublicIn[k] = uint64(_w(0, string.concat(".leaf_public_in", idx)));
            tpi.isDeposit[k] = uint8(_w(0, string.concat(".is_deposit", idx)));
        }

        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c,) = _proof(0);
        assertFalse(verifier.verifyProof(a, b, c, h.compress(tpi)), "tampered actualCount must not verify");
    }

    /// Each proof is bound to its own batch: replaying one vector's proof under
    /// another's public signals must fail.
    function test_revert_crossVectorReplay() public view {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c,) = _proof(0);
        (,,, uint256[2] memory otherPub) = _proof(1);
        assertFalse(verifier.verifyProof(a, b, c, otherPub), "cross-vector replay must not verify");
    }

    /// Public signals at or above the scalar field modulus are rejected before
    /// the pairing, so a wrapped-around `z` cannot stand in for the real one.
    function test_revert_publicSignalOutOfField() public view {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[2] memory pub) = _proof(0);
        assertFalse(verifier.verifyProof(a, b, c, [pub[0] + R, pub[1]]), "y >= r must not verify");
        assertFalse(verifier.verifyProof(a, b, c, [pub[0], pub[1] + R]), "z >= r must not verify");
    }
}
