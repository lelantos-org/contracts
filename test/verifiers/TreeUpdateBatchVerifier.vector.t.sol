// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../../src/libs/PubInputs.sol";
import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";

import { CompressHarness, Y, DIGEST, Z } from "../utils/CompressHarness.sol";

/// Verifies real Groth16 proofs against the deployed `tree_update_batch`
/// verifier, and pins the public-signal order the contract feeds it.
///
/// Layout tests establish only that the coefficient vector is assembled
/// correctly. This suite runs proofs through the verifier, so it catches a
/// verifier keyed to a different ceremony or a `[y, digest, z]` ordering
/// permuted on one side.
///
/// It is also where the digest signal is exercised against a real proof. The
/// contract never recomputes the circuit's commitment to its coefficients; it
/// forwards the calldata copy. So "a wrong digest fails the proof" is a
/// property of the verifier, tested here.
///
/// Proofs come from `script/fixtures/gen_proof_fixture.sh`, which proves the
/// circuits package's witness vectors and asserts each proof's public signals
/// against the vector's `[y, digest, z]` before writing. Groth16 proving is
/// randomized: regenerating yields different but equally valid proof triples
/// over the same public signals. The setup the proofs and the verifier's key
/// come from is recorded in `test/fixtures/README.md`.
contract TreeUpdateBatchVerifierVectorTest is Test {
    string internal constant PROOFS = "test/fixtures/tree_update_batch_proof.json";
    string internal constant VECTOR = "test/fixtures/tree_update_batch_vector.json";
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant N = 3;

    TreeUpdateBatchGroth16Verifier internal verifier;
    CompressHarness internal h;
    string internal proofs;
    string internal vector;

    function setUp() public {
        verifier = new TreeUpdateBatchGroth16Verifier();
        h = new CompressHarness();
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
        returns (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[3] memory pub)
    {
        string memory base = _p(i);
        uint256[] memory av = vm.parseJsonUintArray(proofs, string.concat(base, ".a"));
        uint256[] memory b0 = vm.parseJsonUintArray(proofs, string.concat(base, ".b[0]"));
        uint256[] memory b1 = vm.parseJsonUintArray(proofs, string.concat(base, ".b[1]"));
        uint256[] memory cv = vm.parseJsonUintArray(proofs, string.concat(base, ".c"));
        uint256[] memory pv = vm.parseJsonUintArray(proofs, string.concat(base, ".pubSignals"));
        assertEq(pv.length, 3, "fixture must carry [y, digest, z]");
        a = [av[0], av[1]];
        b = [[b0[0], b0[1]], [b1[0], b1[1]]];
        c = [cv[0], cv[1]];
        pub = [pv[Y], pv[DIGEST], pv[Z]];
    }

    /// The batch behind vector `v`, as a flusher would put it in calldata: the
    /// coefficients from the witness, and the digest the circuit output for
    /// them.
    function _batch(uint256 v) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = bytes32(_w(v, ".old_root"));
        tpi.newRoot = bytes32(_w(v, ".new_root"));
        tpi.startIndex = uint64(_w(v, ".start_index"));
        tpi.actualCount = uint64(_w(v, ".actual_count"));
        for (uint256 k = 0; k < PubInputs.MAX_L_BATCH; k++) {
            string memory idx = string.concat("[", vm.toString(k), "]");
            tpi.cms[k] = bytes32(_w(v, string.concat(".cms", idx)));
            tpi.leafAsset[k] = uint64(_w(v, string.concat(".leaf_asset", idx)));
            tpi.leafPublicIn[k] = uint64(_w(v, string.concat(".leaf_public_in", idx)));
            tpi.isDeposit[k] = uint8(_w(v, string.concat(".is_deposit", idx)));
        }
        tpi.digest = vm.parseJsonUint(vector, string.concat(".vectors[", vm.toString(v), "].compression.digest"));
    }

    /// The proof fixture is generated from the same vector the layout tests
    /// pin against, at the deployed shape.
    function test_fixtureProvenance() public view {
        assertEq(vm.parseJsonString(proofs, ".source.template"), "TreeUpdateBatch(11, 8)", "template");
        assertEq(
            vm.parseJsonString(proofs, ".source.layoutDigest"),
            vm.parseJsonString(vector, ".circuit.layoutDigest"),
            "layout digest must match the witness vector"
        );
        assertEq(vm.parseJsonString(proofs, ".source.vector"), "tree-update-batch-8.json", "vector name");
    }

    function _accepts(uint256 i) internal view {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[3] memory pub) = _proof(i);
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

    /// The circuit's public signals are its outputs `y` and `digest`, then the
    /// public input `z`; `PubInputs.compress` returns them in that order. A
    /// verifier keyed to any other order would accept the matching reordering,
    /// so all five are tried.
    function test_revert_swappedPublicSignals() public view {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[3] memory pub) = _proof(0);
        assertTrue(
            pub[Y] != pub[DIGEST] && pub[DIGEST] != pub[Z] && pub[Y] != pub[Z],
            "signals must differ for a reordering to be meaningful"
        );
        assertFalse(verifier.verifyProof(a, b, c, [pub[Z], pub[DIGEST], pub[Y]]), "(z, digest, y) must not verify");
        assertFalse(verifier.verifyProof(a, b, c, [pub[DIGEST], pub[Y], pub[Z]]), "(digest, y, z) must not verify");
        assertFalse(verifier.verifyProof(a, b, c, [pub[Y], pub[Z], pub[DIGEST]]), "(y, z, digest) must not verify");
        assertFalse(verifier.verifyProof(a, b, c, [pub[DIGEST], pub[Z], pub[Y]]), "(digest, z, y) must not verify");
        assertFalse(verifier.verifyProof(a, b, c, [pub[Z], pub[Y], pub[DIGEST]]), "(z, y, digest) must not verify");
    }

    /// End-to-end binding: the struct the contract receives, compressed by the
    /// contract's own code path, equals what the proof commits to.
    function test_compressOfWitnessMatchesProofSignals() public view {
        for (uint256 v = 0; v < N; v++) {
            PubInputs.TreeUpdateBatch memory tpi = _batch(v);

            (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[3] memory pub) = _proof(v);
            uint256[3] memory got = h.batch(tpi);
            assertEq(got[Y], pub[Y], "compressed y must equal the proof's first public signal");
            assertEq(got[DIGEST], pub[DIGEST], "returned digest must equal the proof's second public signal");
            assertEq(got[Z], pub[Z], "compressed z must equal the proof's third public signal");
            assertTrue(verifier.verifyProof(a, b, c, got), "proof must verify against contract-compressed signals");
        }
    }

    /// A batch header that was not proven (one extra leaf slot claimed) moves
    /// `z` and fails verification. Covers what the layout tests cannot: a
    /// correct layout paired with a proof for different data.
    function test_revert_tamperedHeader() public view {
        PubInputs.TreeUpdateBatch memory tpi = _batch(0);
        tpi.actualCount += 1;

        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c,) = _proof(0);
        assertFalse(verifier.verifyProof(a, b, c, h.batch(tpi)), "tampered actualCount must not verify");
    }

    /// Each proof is bound to its own batch: replaying one vector's proof under
    /// another's public signals fails.
    function test_revert_crossVectorReplay() public view {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c,) = _proof(0);
        (,,, uint256[3] memory otherPub) = _proof(1);
        assertFalse(verifier.verifyProof(a, b, c, otherPub), "cross-vector replay must not verify");
    }

    /// A calldata digest other than the circuit's fails the proof.
    ///
    /// Run through the contract's own path: `compress` hashes the wrong word
    /// into `z` and returns it as the second signal, so the verifier is handed
    /// a `z` the proof was not made for and a digest it did not output. The
    /// coefficients, and so the polynomial `y` evaluates, are untouched.
    function test_revert_wrongDigestInCalldata() public view {
        for (uint256 v = 0; v < N; v++) {
            PubInputs.TreeUpdateBatch memory tpi = _batch(v);
            tpi.digest = addmod(tpi.digest, 1, R);

            (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c,) = _proof(v);
            uint256[3] memory got = h.batch(tpi);
            assertEq(got[DIGEST], tpi.digest, "compress forwards the digest it was given");
            assertFalse(verifier.verifyProof(a, b, c, got), "a wrong calldata digest must not verify");
        }
    }

    /// The digest signal is constrained on its own: with the proven `y` and `z`
    /// left in place, any other digest is rejected. So the word `compress`
    /// forwards is checked by the proof, not merely carried.
    function testFuzz_revert_wrongDigestSignal(uint256 delta, uint8 vec) public view {
        delta = bound(delta, 1, R - 1);
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[3] memory pub) = _proof(vec % N);
        pub[DIGEST] = addmod(pub[DIGEST], delta, R);
        assertFalse(verifier.verifyProof(a, b, c, pub), "a wrong digest signal must not verify");
    }

    /// A proof under another vector's digest, with its own `y` and `z` left in
    /// place, is rejected: a digest the circuit did output, for a different
    /// batch, is no better than an arbitrary one.
    function test_revert_crossVectorDigest() public view {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[3] memory pub) = _proof(0);
        (,,, uint256[3] memory otherPub) = _proof(2);
        assertTrue(pub[DIGEST] != otherPub[DIGEST], "vectors must have distinct digests");
        assertFalse(verifier.verifyProof(a, b, c, [pub[Y], otherPub[DIGEST], pub[Z]]), "foreign digest must not verify");
    }

    /// Public signals at or above the scalar field modulus are rejected before
    /// the pairing, so a wrapped-around `z` cannot stand in for the real one.
    function test_revert_publicSignalOutOfField() public view {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[3] memory pub) = _proof(0);
        assertFalse(verifier.verifyProof(a, b, c, [pub[Y] + R, pub[DIGEST], pub[Z]]), "y >= r must not verify");
        assertFalse(verifier.verifyProof(a, b, c, [pub[Y], pub[DIGEST] + R, pub[Z]]), "digest >= r must not verify");
        assertFalse(verifier.verifyProof(a, b, c, [pub[Y], pub[DIGEST], pub[Z] + R]), "z >= r must not verify");
    }

    /// The digest's range is checked nowhere else. `PubInputs.compress` does
    /// not evaluate it, so a batch whose digest is `digest + R`, the same field
    /// element the circuit output, compresses without `CoefficientOutOfField`
    /// and reaches the verifier unreduced, where it is rejected.
    function test_revert_digestOutOfFieldThroughCompress() public view {
        PubInputs.TreeUpdateBatch memory tpi = _batch(0);
        tpi.digest += R;

        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c,) = _proof(0);
        uint256[3] memory got = h.batch(tpi);
        assertGe(got[DIGEST], R, "compress forwards the unreduced digest");
        assertFalse(verifier.verifyProof(a, b, c, got), "digest >= r must not verify");
    }
}
