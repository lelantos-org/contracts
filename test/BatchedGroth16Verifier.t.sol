// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";

import { IBatchVerifier } from "../src/interfaces/IBatchVerifier.sol";
import { BatchedGroth16Verifier } from "../src/verifiers/BatchedGroth16Verifier.sol";
import { Groth16Verifier } from "../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";
import { SNARK_R, SNARK_Q } from "../src/verifiers/VerifyingKeys.sol";

/// Differential and negative coverage for `BatchedGroth16Verifier`, the
/// hand-written pairing assembly the spend path runs.
///
/// The load-bearing property is stated once and checked everywhere:
///
///     verifyBatch(P1, P2) == v1.verifyProof(P1) && v2.verifyProof(P2)
///
/// with the two snarkjs codegen verifiers as oracle. Folding the shared
/// `alpha`/`beta` and `gamma` terms, scaling proof 2 by a Fiat-Shamir `r2`, and
/// deriving `r2` from the calldata transcript must all preserve that equality.
///
/// Proofs come from `script/fixtures/gen_proof_fixture.sh`. The two circuits'
/// instances are not bound to each other at the verifier level — that
/// cross-binding is `MASP._validateRequest` — so any transact vector paired
/// with any tree-update vector is a valid accepting case.
contract BatchedGroth16VerifierTest is Test {
    string internal constant TRANSACT_PROOFS = "test/fixtures/transact_4x6_proof.json";
    string internal constant TUB_PROOFS = "test/fixtures/tree_update_batch_proof.json";
    uint256 internal constant N = 3;
    /// Calldata words in one `verifyBatch` instance, ten per proof.
    uint256 internal constant WORDS = 20;

    struct P {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
        uint256[2] pub;
    }

    BatchedGroth16Verifier internal batch;
    Groth16Verifier internal v1;
    TreeUpdateBatchGroth16Verifier internal v2;

    P[N] internal t; // 4x6
    P[N] internal u; // tree_update_batch

    function setUp() public {
        batch = new BatchedGroth16Verifier();
        v1 = new Groth16Verifier();
        v2 = new TreeUpdateBatchGroth16Verifier();
        string memory tj = vm.readFile(TRANSACT_PROOFS);
        string memory uj = vm.readFile(TUB_PROOFS);
        for (uint256 i; i < N; ++i) {
            t[i] = _load(tj, i);
            u[i] = _load(uj, i);
        }
    }

    function _load(string memory json, uint256 i) internal pure returns (P memory p) {
        string memory base = string.concat(".proofs[", vm.toString(i), "]");
        uint256[] memory av = vm.parseJsonUintArray(json, string.concat(base, ".a"));
        uint256[] memory b0 = vm.parseJsonUintArray(json, string.concat(base, ".b[0]"));
        uint256[] memory b1 = vm.parseJsonUintArray(json, string.concat(base, ".b[1]"));
        uint256[] memory cv = vm.parseJsonUintArray(json, string.concat(base, ".c"));
        uint256[] memory pv = vm.parseJsonUintArray(json, string.concat(base, ".pubSignals"));
        p.a = [av[0], av[1]];
        p.b = [[b0[0], b0[1]], [b1[0], b1[1]]];
        p.c = [cv[0], cv[1]];
        p.pub = [pv[0], pv[1]];
    }

    function _batch(P memory p1, P memory p2) internal view returns (bool) {
        return batch.verifyBatch(p1.a, p1.b, p1.c, p1.pub, p2.a, p2.b, p2.c, p2.pub);
    }

    function _oracle(P memory p1, P memory p2) internal view returns (bool) {
        return v1.verifyProof(p1.a, p1.b, p1.c, p1.pub) && v2.verifyProof(p2.a, p2.b, p2.c, p2.pub);
    }

    function _assertMatchesOracle(P memory p1, P memory p2, string memory what) internal view {
        assertEq(_batch(p1, p2), _oracle(p1, p2), what);
    }

    // --- the differential ----------------------------------------------------

    /// Every transact vector against every tree-update vector: nine accepting
    /// cases, each agreeing with the oracle.
    function test_differential_allValidCombinations() public view {
        for (uint256 i; i < N; ++i) {
            for (uint256 j; j < N; ++j) {
                assertTrue(_oracle(t[i], u[j]), "fixture does not verify unbatched");
                _assertMatchesOracle(t[i], u[j], "batched disagrees with the two codegen verifiers");
            }
        }
    }

    /// A valid proof beside a broken one must still agree with the oracle. This
    /// establishes that proof 2 is checked at all: `r2 == 0` would collapse the
    /// identity to `e_1 == 0` and admit any `P2`.
    function test_differential_mixedValidity() public view {
        // Perturb a public signal rather than a curve point. An off-curve point
        // makes the pairing precompile fail, and a failing precompile consumes
        // all gas forwarded to it; both verifiers forward nearly all of it, so
        // a point-level tamper costs ~1e9 gas to reject.
        P memory badT = t[0];
        badT.pub[0] = addmod(badT.pub[0], 1, SNARK_R);
        P memory badU = u[0];
        badU.pub[0] = addmod(badU.pub[0], 1, SNARK_R);

        assertFalse(_batch(badT, u[0]), "broken transact proof accepted");
        assertFalse(_batch(t[0], badU), "broken tree-update proof accepted");
        assertFalse(_batch(badT, badU), "two broken proofs accepted");

        _assertMatchesOracle(badT, u[0], "mixed validity: bad P1");
        _assertMatchesOracle(t[0], badU, "mixed validity: bad P2");
    }

    /// Each slot is checked against its own `delta` and `IC` block, so a valid
    /// pair passed in the opposite order must reject.
    function test_slotOrderIsLoadBearing() public view {
        assertTrue(_batch(t[0], u[0]), "control case must verify");
        assertFalse(batch.verifyBatch(u[0].a, u[0].b, u[0].c, u[0].pub, t[0].a, t[0].b, t[0].c, t[0].pub), "swapped");
    }

    /// The `IC` blocks differ per circuit, so a proof paired with the other
    /// circuit's public signals must reject.
    function test_crossCircuitPublicSignalsReject() public view {
        P memory p1 = t[0];
        p1.pub = u[0].pub;
        assertFalse(_batch(p1, u[0]), "transact proof accepted with tree-update signals");
    }

    // --- word-level tampering ------------------------------------------------

    /// The transcript is all twenty calldata words. Perturbing any one of them
    /// must reject.
    function testFuzz_tamperedWordRejects(uint8 wordIdx, uint256 delta) public view {
        wordIdx = uint8(bound(wordIdx, 0, WORDS - 1));
        // Stay inside the relevant field so the change is a different valid
        // encoding rather than a range-check rejection, which the dedicated
        // out-of-field tests already cover.
        uint256 modulus = _isPublicInput(wordIdx) ? SNARK_R : SNARK_Q;
        delta = bound(delta, 1, modulus - 1);

        uint256[WORDS] memory w = _toWords(t[0], u[0]);
        w[wordIdx] = addmod(w[wordIdx], delta, modulus);
        (P memory p1, P memory p2) = _fromWords(w);

        assertFalse(_batch(p1, p2), "tampered instance accepted");
    }

    /// Guards the fuzz test above, which asserts only that a tampered instance
    /// is rejected: a `_toWords`/`_fromWords` pair that corrupted the instance
    /// would satisfy it on every input. An untouched round trip must still
    /// verify.
    function test_wordRoundTripIsIdentity() public view {
        (P memory p1, P memory p2) = _fromWords(_toWords(t[0], u[0]));
        assertTrue(_batch(p1, p2), "round-trip corrupted the instance");
    }

    // --- the twenty-word view ------------------------------------------------
    //
    // `BatchedGroth16Verifier` hashes its calldata body verbatim, so an instance
    // is a flat array of twenty words. Working in that shape keeps this test
    // aligned with the contract's calldata map rather than re-deriving offsets:
    //
    //   0-1 a1   2-5 b1   6-7 c1   8-9 pub1
    //   10-11 a2 12-15 b2 16-17 c2 18-19 pub2

    function _toWords(P memory p1, P memory p2) internal pure returns (uint256[WORDS] memory w) {
        P[2] memory ps = [p1, p2];
        uint256 i;
        for (uint256 k; k < 2; ++k) {
            w[i++] = ps[k].a[0];
            w[i++] = ps[k].a[1];
            w[i++] = ps[k].b[0][0];
            w[i++] = ps[k].b[0][1];
            w[i++] = ps[k].b[1][0];
            w[i++] = ps[k].b[1][1];
            w[i++] = ps[k].c[0];
            w[i++] = ps[k].c[1];
            w[i++] = ps[k].pub[0];
            w[i++] = ps[k].pub[1];
        }
    }

    function _fromWords(uint256[WORDS] memory w) internal pure returns (P memory p1, P memory p2) {
        p1 = _sliceProof(w, 0);
        p2 = _sliceProof(w, WORDS / 2);
    }

    function _sliceProof(uint256[WORDS] memory w, uint256 o) private pure returns (P memory p) {
        p.a = [w[o], w[o + 1]];
        p.b = [[w[o + 2], w[o + 3]], [w[o + 4], w[o + 5]]];
        p.c = [w[o + 6], w[o + 7]];
        p.pub = [w[o + 8], w[o + 9]];
    }

    /// Words 8, 9, 18 and 19 are `(y, z)` pairs, which live in the scalar
    /// field; every other word is a curve coordinate in the base field.
    function _isPublicInput(uint256 i) private pure returns (bool) {
        uint256 within = i % (WORDS / 2);
        return within == 8 || within == 9;
    }

    // --- range checks --------------------------------------------------------

    /// Public inputs must be reduced, exactly as `checkField` requires in the
    /// codegen. `y + R` and `z + R` are the same field element, so accepting
    /// them would give two calldata encodings of one instance.
    function test_outOfFieldPublicInputsReject() public view {
        for (uint256 k; k < 2; ++k) {
            P memory p1 = t[0];
            p1.pub[k] += SNARK_R;
            assertFalse(_batch(p1, u[0]), "out-of-field transact public input accepted");

            P memory p2 = u[0];
            p2.pub[k] += SNARK_R;
            assertFalse(_batch(t[0], p2), "out-of-field tree-update public input accepted");
        }
    }

    /// `a1.y` is the one coordinate that reaches no precompile unreduced — it is
    /// negated in place — so the contract range-checks it itself.
    function test_unreducedA1YRejects() public view {
        P memory p1 = t[0];
        p1.a[1] += SNARK_Q;
        assertFalse(_batch(p1, u[0]), "unreduced a1.y accepted");
    }

    function test_allZeroInputRejects() public view {
        P memory z;
        assertFalse(_batch(z, z), "point at infinity everywhere accepted");
    }

    // --- calldata length -----------------------------------------------------

    /// The contract pins `calldatasize` to `4 + 20 * 32`, making the transcript
    /// a strict function of the instance; without it a caller could append
    /// trailing bytes and resample `r2`. A typed call cannot produce a wrong
    /// length, so this uses a raw staticcall.
    function test_calldataLengthIsPinned() public view {
        bytes memory cd = abi.encodeWithSelector(
            IBatchVerifier.verifyBatch.selector, t[0].a, t[0].b, t[0].c, t[0].pub, u[0].a, u[0].b, u[0].c, u[0].pub
        );
        assertEq(cd.length, 644, "encoding is not twenty contiguous words");

        (bool ok, bytes memory ret) = address(batch).staticcall(cd);
        assertTrue(ok && abi.decode(ret, (bool)), "exact-length call must verify");

        (ok, ret) = address(batch).staticcall(bytes.concat(cd, hex"00"));
        assertTrue(ok, "over-long call must return, not revert");
        assertFalse(abi.decode(ret, (bool)), "trailing byte accepted");

        bytes memory short = new bytes(cd.length - 1);
        for (uint256 i; i < short.length; ++i) {
            short[i] = cd[i];
        }
        // Truncated calldata never reaches the assembly: every parameter is a
        // static type, so Solidity's dispatcher validates the size and reverts
        // first. A different mechanism from the `calldatasize` pin, equally
        // fail-closed.
        (ok,) = address(batch).staticcall(short);
        assertFalse(ok, "truncated calldata accepted");
    }

    /// The verifier reads every field by a hard-coded calldata offset, and it
    /// hashes `cd[4 .. 644]` verbatim. Both rest on the ABI putting the twenty
    /// words exactly where the assembly's literals say. `test_calldataLengthIsPinned`
    /// pins only the total, which a compensating pair of layout changes would
    /// survive; this pins each word.
    ///
    /// The subject is the encoder, not the assembly. Shifting an offset inside
    /// `BatchedGroth16Verifier` leaves this test green; that mutation is
    /// fail-closed and `test_differential_allValidCombinations` catches it.
    /// This catches the converse: a solc release laying the static arrays out
    /// differently, moving every offset at once, which would otherwise surface
    /// as an unattributable fixture failure.
    ///
    /// The offsets below are transcribed from the header comment of
    /// `BatchedGroth16Verifier`; they are the literals the assembly loads.
    function test_calldataFieldOffsets() public view {
        bytes memory cd = abi.encodeWithSelector(
            IBatchVerifier.verifyBatch.selector, t[0].a, t[0].b, t[0].c, t[0].pub, u[0].a, u[0].b, u[0].c, u[0].pub
        );
        assertEq(cd.length, 644, "encoding is not twenty contiguous words");
        assertEq(bytes4(cd), IBatchVerifier.verifyBatch.selector, "selector is not the first four bytes");

        // a1 @ 0x04, b1 @ 0x44, c1 @ 0xc4, pub1 @ 0x104
        assertEq(_word(cd, 0x04), t[0].a[0], "a1.x offset");
        assertEq(_word(cd, 0x24), t[0].a[1], "a1.y offset");
        assertEq(_word(cd, 0x44), t[0].b[0][0], "b1[0][0] offset");
        assertEq(_word(cd, 0x64), t[0].b[0][1], "b1[0][1] offset");
        assertEq(_word(cd, 0x84), t[0].b[1][0], "b1[1][0] offset");
        assertEq(_word(cd, 0xa4), t[0].b[1][1], "b1[1][1] offset");
        assertEq(_word(cd, 0xc4), t[0].c[0], "c1.x offset");
        assertEq(_word(cd, 0xe4), t[0].c[1], "c1.y offset");
        assertEq(_word(cd, 0x104), t[0].pub[0], "pub1.y offset");
        assertEq(_word(cd, 0x124), t[0].pub[1], "pub1.z offset");

        // a2 @ 0x144, b2 @ 0x184, c2 @ 0x204, pub2 @ 0x244
        assertEq(_word(cd, 0x144), u[0].a[0], "a2.x offset");
        assertEq(_word(cd, 0x164), u[0].a[1], "a2.y offset");
        assertEq(_word(cd, 0x184), u[0].b[0][0], "b2[0][0] offset");
        assertEq(_word(cd, 0x1a4), u[0].b[0][1], "b2[0][1] offset");
        assertEq(_word(cd, 0x1c4), u[0].b[1][0], "b2[1][0] offset");
        assertEq(_word(cd, 0x1e4), u[0].b[1][1], "b2[1][1] offset");
        assertEq(_word(cd, 0x204), u[0].c[0], "c2.x offset");
        assertEq(_word(cd, 0x224), u[0].c[1], "c2.y offset");
        assertEq(_word(cd, 0x244), u[0].pub[0], "pub2.y offset");
        assertEq(_word(cd, 0x264), u[0].pub[1], "pub2.z offset");

        // The transcript is `BATCH_DOMAIN || cd[4 .. 644]`, so the body the
        // assembly copies has to end exactly where the last word does.
        assertEq(0x264 + 0x20, cd.length, "CD_BODY does not cover the last word");
    }

    /// `mload` of the word at `off` bytes into `cd`, counted from the selector.
    function _word(bytes memory cd, uint256 off) internal pure returns (uint256 w) {
        assembly {
            w := mload(add(add(cd, 0x20), off))
        }
    }

    // --- shape ---------------------------------------------------------------

    /// Every rejection path returns `false`; none reverts. `MASP` turns the
    /// bool into `ProofRejected`, so a revert here would surface as an opaque
    /// bubbled failure instead.
    function test_neverReverts() public view {
        P memory bad = t[0];
        bad.a[0] = type(uint256).max;
        bad.pub[0] = type(uint256).max;
        (bool ok, bytes memory ret) = address(batch)
            .staticcall(
                abi.encodeWithSelector(
                    IBatchVerifier.verifyBatch.selector, bad.a, bad.b, bad.c, bad.pub, u[0].a, u[0].b, u[0].c, u[0].pub
                )
            );
        assertTrue(ok, "rejection reverted instead of returning false");
        assertFalse(abi.decode(ret, (bool)), "garbage accepted");
    }

    /// `r2` is a pure function of the calldata, so the result is deterministic.
    function test_deterministic() public view {
        assertEq(_batch(t[0], u[0]), _batch(t[0], u[0]), "result is not a function of the instance");
    }

    // --- the point of the exercise -------------------------------------------

    /// The batched check must cost less than the two it replaces: six pairings
    /// (45k + 6*34k) against two sets of four (2 * (45k + 4*34k)), plus three
    /// extra `ECMUL`s and one keccak over 672 bytes.
    ///
    /// Measured here because MASP spend tests mock verification, so the gas
    /// snapshot reflects the mock rather than the pairing.
    function test_batchedIsCheaperThanTwoSingleVerifications() public view {
        P memory p1 = t[0];
        P memory p2 = u[0];

        uint256 g0 = gasleft();
        v1.verifyProof(p1.a, p1.b, p1.c, p1.pub);
        v2.verifyProof(p2.a, p2.b, p2.c, p2.pub);
        uint256 unbatched = g0 - gasleft();

        g0 = gasleft();
        batch.verifyBatch(p1.a, p1.b, p1.c, p1.pub, p2.a, p2.b, p2.c, p2.pub);
        uint256 batched = g0 - gasleft();

        console.log("unbatched (two verifyProof):", unbatched);
        console.log("batched   (one verifyBatch):", batched);
        console.log("saved:", unbatched - batched);
        assertLt(batched, unbatched, "batching must not cost more than it saves");
        assertGt(unbatched - batched, 50_000, "saving is far below the expected ~90k");
    }

    // --- provenance ----------------------------------------------------------

    function test_fixtureProvenance() public view {
        string memory tj = vm.readFile(TRANSACT_PROOFS);
        string memory uj = vm.readFile(TUB_PROOFS);
        assertEq(vm.parseJsonString(tj, ".source.template"), "Transact(11, 4, 6)", "transact template");
        assertEq(vm.parseJsonString(uj, ".source.template"), "TreeUpdateBatch(11, 8)", "tree-update template");
    }
}
