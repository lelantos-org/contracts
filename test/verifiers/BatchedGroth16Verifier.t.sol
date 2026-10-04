// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test, console } from "forge-std/Test.sol";

import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { BatchedGroth16Verifier } from "../../src/verifiers/BatchedGroth16Verifier.sol";
import { Groth16Verifier } from "../../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";
import { SNARK_R, SNARK_Q } from "../../src/verifiers/VerifyingKeys.sol";

import { Y, DIGEST, Z } from "../utils/CompressHarness.sol";

/// Differential and negative coverage for `BatchedGroth16Verifier`, the
/// hand-written pairing assembly the spend path runs.
///
/// The property under test is
///
///     verifyBatch(P1, P2) == v1.verifyProof(P1) && v2.verifyProof(P2)
///
/// with the two snarkjs codegen verifiers as oracle. Folding the shared
/// `alpha`/`beta` and `gamma` terms, scaling proof 2 by a Fiat-Shamir `r2`, and
/// deriving `r2` from the calldata transcript all preserve that equality.
///
/// Proofs come from `script/fixtures/gen_proof_fixture.sh`; the setup behind
/// them and the embedded keys is recorded in `test/fixtures/README.md`. The
/// verifier does not bind the two circuits' instances to each other
/// (`MASP._validateRequest` does), so any transact vector paired with any
/// tree-update vector is a valid accepting case.
contract BatchedGroth16VerifierTest is Test {
    string internal constant TRANSACT_PROOFS = "test/fixtures/transact_4x6_proof.json";
    string internal constant TUB_PROOFS = "test/fixtures/tree_update_batch_proof.json";
    uint256 internal constant N = 3;
    /// Calldata words in one `verifyBatch` instance, eleven per proof: eight
    /// for the proof points, three for the public signals `[y, digest, z]`.
    uint256 internal constant WORDS = 22;
    /// Offset of the public signals within one proof's eleven words.
    uint256 internal constant PUB_AT = 8;
    /// `4 + WORDS * 32`, the one calldata length the verifier accepts.
    uint256 internal constant CD_LEN = 708;

    struct P {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
        uint256[3] pub;
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
        assertEq(pv.length, 3, "fixture must carry [y, digest, z]");
        p.pub = [pv[Y], pv[DIGEST], pv[Z]];
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

    /// A valid proof beside a broken one agrees with the oracle. This shows
    /// proof 2 is checked: `r2 == 0` would collapse the identity to `e_1 == 0`
    /// and admit any `P2`.
    function test_differential_mixedValidity() public view {
        // Perturbs a public signal rather than a curve point. An off-curve point
        // makes the pairing precompile fail, and a failing precompile consumes
        // all gas forwarded to it; both verifiers forward nearly all of it, so
        // a point-level tamper costs ~1e9 gas to reject.
        P memory badT = t[0];
        badT.pub[Y] = addmod(badT.pub[Y], 1, SNARK_R);
        P memory badU = u[0];
        badU.pub[Y] = addmod(badU.pub[Y], 1, SNARK_R);

        assertFalse(_batch(badT, u[0]), "broken transact proof accepted");
        assertFalse(_batch(t[0], badU), "broken tree-update proof accepted");
        assertFalse(_batch(badT, badU), "two broken proofs accepted");

        _assertMatchesOracle(badT, u[0], "mixed validity: bad P1");
        _assertMatchesOracle(t[0], badU, "mixed validity: bad P2");
    }

    /// Each slot is checked against its own `delta` and `IC` block, so a valid
    /// pair passed in the opposite order is rejected.
    function test_slotOrderIsLoadBearing() public view {
        assertTrue(_batch(t[0], u[0]), "control case must verify");
        assertFalse(batch.verifyBatch(u[0].a, u[0].b, u[0].c, u[0].pub, t[0].a, t[0].b, t[0].c, t[0].pub), "swapped");
    }

    /// The `IC` blocks differ per circuit, so a proof paired with the other
    /// circuit's public signals is rejected.
    function test_crossCircuitPublicSignalsReject() public view {
        P memory p1 = t[0];
        p1.pub = u[0].pub;
        assertFalse(_batch(p1, u[0]), "transact proof accepted with tree-update signals");
    }

    /// Each signal is folded against its own `IC` point, `[y, digest, z]` in
    /// that order, so every reordering of a proof's three signals is rejected,
    /// in either slot, and the oracle agrees.
    function test_transposedPublicSignalsReject() public view {
        uint8[3][5] memory perms = _nonIdentityPermutations();
        for (uint256 k; k < perms.length; ++k) {
            P memory p1 = t[0];
            p1.pub = _permute(t[0].pub, perms[k]);
            assertFalse(_batch(p1, u[0]), "transposed transact signals accepted");
            _assertMatchesOracle(p1, u[0], "transposed transact signals");

            P memory p2 = u[0];
            p2.pub = _permute(u[0].pub, perms[k]);
            assertFalse(_batch(t[0], p2), "transposed tree-update signals accepted");
            _assertMatchesOracle(t[0], p2, "transposed tree-update signals");
        }
    }

    /// A proof cannot be replayed under another vector's signals, in either
    /// slot: `IC` binds each proof to its own `[y, digest, z]`.
    function test_crossVectorReplayRejects() public view {
        for (uint256 i; i < N; ++i) {
            for (uint256 j; j < N; ++j) {
                if (i == j) continue;
                P memory p1 = t[i];
                p1.pub = t[j].pub;
                assertFalse(_batch(p1, u[0]), "transact proof accepted under another vector's signals");

                P memory p2 = u[i];
                p2.pub = u[j].pub;
                assertFalse(_batch(t[0], p2), "tree-update proof accepted under another vector's signals");
            }
        }
    }

    // --- the digest signal ---------------------------------------------------
    //
    // The second public signal is the circuit's Poseidon commitment to its own
    // coefficients. `PubInputs` forwards the calldata copy unmodified and
    // never recomputes it, so the proof is what checks it: the verifier must
    // reject any digest but the one the circuit output.

    /// A digest other than the circuit's is rejected in either slot, with `y`
    /// and `z` left as proven, and the oracle agrees.
    function testFuzz_wrongDigestRejects(uint256 delta, uint8 vec) public view {
        delta = bound(delta, 1, SNARK_R - 1);
        uint256 i = vec % N;

        P memory p1 = t[i];
        p1.pub[DIGEST] = addmod(p1.pub[DIGEST], delta, SNARK_R);
        assertFalse(_batch(p1, u[i]), "transact proof accepted under a wrong digest");
        _assertMatchesOracle(p1, u[i], "wrong transact digest");

        P memory p2 = u[i];
        p2.pub[DIGEST] = addmod(p2.pub[DIGEST], delta, SNARK_R);
        assertFalse(_batch(t[i], p2), "tree-update proof accepted under a wrong digest");
        _assertMatchesOracle(t[i], p2, "wrong tree-update digest");
    }

    /// The two circuits' digests are not interchangeable: each proof's digest
    /// under the other's slot is rejected.
    function test_swappedDigestsReject() public view {
        P memory p1 = t[0];
        P memory p2 = u[0];
        (p1.pub[DIGEST], p2.pub[DIGEST]) = (p2.pub[DIGEST], p1.pub[DIGEST]);
        assertFalse(_batch(p1, p2), "digests accepted in each other's slot");
    }

    /// `digest + R` is the same field element as `digest`. This is the only
    /// range check the word gets: `PubInputs.compress` hashes it as given and
    /// does not evaluate it, so unlike a coefficient it reaches the verifier
    /// unreduced. Accepting it would give one instance two encodings and two
    /// challenges.
    function test_digestOutOfFieldRejects() public view {
        P memory p1 = t[0];
        p1.pub[DIGEST] += SNARK_R;
        assertFalse(_batch(p1, u[0]), "transact digest >= R accepted");
        assertFalse(v1.verifyProof(p1.a, p1.b, p1.c, p1.pub), "codegen accepts a transact digest >= R");

        P memory p2 = u[0];
        p2.pub[DIGEST] += SNARK_R;
        assertFalse(_batch(t[0], p2), "tree-update digest >= R accepted");
        assertFalse(v2.verifyProof(p2.a, p2.b, p2.c, p2.pub), "codegen accepts a tree-update digest >= R");

        // The boundary and the top of the word, with the proof otherwise valid.
        p1.pub[DIGEST] = SNARK_R;
        assertFalse(_batch(p1, u[0]), "transact digest == R accepted");
        p2.pub[DIGEST] = type(uint256).max;
        assertFalse(_batch(t[0], p2), "tree-update digest == 2^256 - 1 accepted");
    }

    // --- word-level tampering ------------------------------------------------

    /// The transcript is all twenty-two calldata words. Perturbing any one of
    /// them is rejected.
    function testFuzz_tamperedWordRejects(uint8 wordIdx, uint256 delta) public view {
        wordIdx = uint8(bound(wordIdx, 0, WORDS - 1));
        // Stays inside the relevant field so the change is a different in-range
        // encoding rather than a range-check rejection, which the out-of-field
        // tests cover.
        uint256 modulus = _isPublicInput(wordIdx) ? SNARK_R : SNARK_Q;
        delta = bound(delta, 1, modulus - 1);

        uint256[WORDS] memory w = _toWords(t[0], u[0]);
        w[wordIdx] = addmod(w[wordIdx], delta, modulus);
        (P memory p1, P memory p2) = _fromWords(w);

        assertFalse(_batch(p1, p2), "tampered instance accepted");
    }

    /// Guards the fuzz test above, which asserts only that a tampered instance
    /// is rejected: a `_toWords`/`_fromWords` pair that corrupted the instance
    /// would satisfy it on every input. An untouched round trip still verifies.
    function test_wordRoundTripIsIdentity() public view {
        (P memory p1, P memory p2) = _fromWords(_toWords(t[0], u[0]));
        assertTrue(_batch(p1, p2), "round-trip corrupted the instance");
    }

    // --- the twenty-two-word view --------------------------------------------
    //
    // `BatchedGroth16Verifier` hashes its calldata body verbatim, so an instance
    // is a flat array of twenty-two words. Working in that shape keeps this test
    // aligned with the contract's calldata map rather than re-deriving offsets:
    //
    //   0-1 a1    2-5 b1    6-7 c1    8-10 pub1
    //   11-12 a2  13-16 b2  17-18 c2  19-21 pub2

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
            w[i++] = ps[k].pub[Y];
            w[i++] = ps[k].pub[DIGEST];
            w[i++] = ps[k].pub[Z];
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
        p.pub = [w[o + PUB_AT], w[o + PUB_AT + 1], w[o + PUB_AT + 2]];
    }

    /// Words 8-10 and 19-21 are the `[y, digest, z]` triples, which live in the
    /// scalar field; every other word is a curve coordinate in the base field.
    function _isPublicInput(uint256 i) private pure returns (bool) {
        return i % (WORDS / 2) >= PUB_AT;
    }

    /// The five reorderings of three signals other than the identity.
    function _nonIdentityPermutations() private pure returns (uint8[3][5] memory perms) {
        perms[0] = [0, 2, 1];
        perms[1] = [1, 0, 2];
        perms[2] = [1, 2, 0];
        perms[3] = [2, 0, 1];
        perms[4] = [2, 1, 0];
    }

    function _permute(uint256[3] memory pub, uint8[3] memory perm) private pure returns (uint256[3] memory out) {
        out = [pub[perm[0]], pub[perm[1]], pub[perm[2]]];
    }

    // --- range checks --------------------------------------------------------

    /// Public inputs must be reduced, as `checkField` requires in the codegen.
    /// `y + R`, `digest + R` and `z + R` are the same field elements as `y`,
    /// `digest` and `z`, so accepting them would give two calldata encodings of
    /// one instance. Each of the six signals is checked on its own.
    function test_outOfFieldPublicInputsReject() public view {
        for (uint256 k; k < 3; ++k) {
            P memory p1 = t[0];
            p1.pub[k] += SNARK_R;
            assertFalse(_batch(p1, u[0]), "out-of-field transact public input accepted");

            P memory p2 = u[0];
            p2.pub[k] += SNARK_R;
            assertFalse(_batch(t[0], p2), "out-of-field tree-update public input accepted");
        }
    }

    /// `a1.y` is the one coordinate that does not reach a precompile unreduced
    /// (it is negated in place), so the contract range-checks it directly.
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

    /// The contract pins `calldatasize` to `4 + 22 * 32`, making the transcript
    /// a strict function of the instance; without it a caller could append
    /// trailing bytes and resample `r2`. A typed call cannot produce a wrong
    /// length, so this uses a raw staticcall.
    function test_calldataLengthIsPinned() public view {
        bytes memory cd = abi.encodeWithSelector(
            IBatchVerifier.verifyBatch.selector, t[0].a, t[0].b, t[0].c, t[0].pub, u[0].a, u[0].b, u[0].c, u[0].pub
        );
        assertEq(cd.length, CD_LEN, "encoding is not twenty-two contiguous words");
        assertEq(CD_LEN, 4 + WORDS * 32, "CD_LEN");

        (bool ok, bytes memory ret) = address(batch).staticcall(cd);
        assertTrue(ok && abi.decode(ret, (bool)), "exact-length call must verify");

        (ok, ret) = address(batch).staticcall(bytes.concat(cd, hex"00"));
        assertTrue(ok, "over-long call must return, not revert");
        assertFalse(abi.decode(ret, (bool)), "trailing byte accepted");

        bytes memory short = new bytes(cd.length - 1);
        for (uint256 i; i < short.length; ++i) {
            short[i] = cd[i];
        }
        // Truncated calldata does not reach the assembly: every parameter is a
        // static type, so Solidity's dispatcher validates the size and reverts
        // first. This is a separate mechanism from the `calldatasize` pin and
        // also fails closed.
        (ok,) = address(batch).staticcall(short);
        assertFalse(ok, "truncated calldata accepted");
    }

    /// Calldata carrying `(y, z)` per proof and no digest is twenty words, one
    /// of the truncated lengths: a caller that omits the digest cannot reach
    /// the pairing with a signal missing.
    function test_twoSignalCalldataRejects() public view {
        bytes memory cd = abi.encodePacked(
            IBatchVerifier.verifyBatch.selector,
            abi.encode(t[0].a, t[0].b, t[0].c, [t[0].pub[Y], t[0].pub[Z]]),
            abi.encode(u[0].a, u[0].b, u[0].c, [u[0].pub[Y], u[0].pub[Z]])
        );
        assertEq(cd.length, 4 + 20 * 32, "the two-signal encoding is twenty words");
        (bool ok, bytes memory ret) = address(batch).staticcall(cd);
        assertFalse(ok, "two-signal calldata accepted");
        // The ABI decoder's length check, which reverts with no data, and not a
        // failure further in: the same proofs verify once the digests are back.
        assertEq(ret.length, 0, "rejected by something other than the calldata length");
        assertTrue(_batch(t[0], u[0]), "control: the full encoding of the same proofs verifies");
    }

    /// The verifier reads every field by a hard-coded calldata offset and
    /// hashes `cd[4 .. 708]` verbatim. Both rely on the ABI placing the
    /// twenty-two words where the assembly's literals expect.
    /// `test_calldataLengthIsPinned` pins only the total, which a compensating
    /// pair of layout changes would preserve; this test pins each word.
    ///
    /// The subject is the encoder, not the assembly. A shifted offset inside
    /// `BatchedGroth16Verifier` fails closed and is caught by
    /// `test_differential_allValidCombinations`, not here. This test catches a
    /// solc release laying out the static arrays differently, moving every
    /// offset at once, which would otherwise surface as an unattributable
    /// fixture failure.
    ///
    /// The offsets below are the literals the assembly loads, transcribed from
    /// the calldata map at the top of `BatchedGroth16Verifier`.
    function test_calldataFieldOffsets() public view {
        bytes memory cd = abi.encodeWithSelector(
            IBatchVerifier.verifyBatch.selector, t[0].a, t[0].b, t[0].c, t[0].pub, u[0].a, u[0].b, u[0].c, u[0].pub
        );
        assertEq(cd.length, CD_LEN, "encoding is not twenty-two contiguous words");
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
        assertEq(_word(cd, 0x104), t[0].pub[Y], "pub1.y offset");
        assertEq(_word(cd, 0x124), t[0].pub[DIGEST], "pub1.digest offset");
        assertEq(_word(cd, 0x144), t[0].pub[Z], "pub1.z offset");

        // a2 @ 0x164, b2 @ 0x1a4, c2 @ 0x224, pub2 @ 0x264
        assertEq(_word(cd, 0x164), u[0].a[0], "a2.x offset");
        assertEq(_word(cd, 0x184), u[0].a[1], "a2.y offset");
        assertEq(_word(cd, 0x1a4), u[0].b[0][0], "b2[0][0] offset");
        assertEq(_word(cd, 0x1c4), u[0].b[0][1], "b2[0][1] offset");
        assertEq(_word(cd, 0x1e4), u[0].b[1][0], "b2[1][0] offset");
        assertEq(_word(cd, 0x204), u[0].b[1][1], "b2[1][1] offset");
        assertEq(_word(cd, 0x224), u[0].c[0], "c2.x offset");
        assertEq(_word(cd, 0x244), u[0].c[1], "c2.y offset");
        assertEq(_word(cd, 0x264), u[0].pub[Y], "pub2.y offset");
        assertEq(_word(cd, 0x284), u[0].pub[DIGEST], "pub2.digest offset");
        assertEq(_word(cd, 0x2a4), u[0].pub[Z], "pub2.z offset");

        // The transcript is `BATCH_DOMAIN || cd[4 .. 708]`, so the body the
        // assembly copies ends exactly where the last word does.
        assertEq(0x2a4 + 0x20, cd.length, "CD_BODY does not cover the last word");
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
        bad.pub[Y] = type(uint256).max;
        (bool ok, bytes memory ret) = address(batch)
            .staticcall(
                abi.encodeWithSelector(
                    IBatchVerifier.verifyBatch.selector, bad.a, bad.b, bad.c, bad.pub, u[0].a, u[0].b, u[0].c, u[0].pub
                )
            );
        assertTrue(ok, "rejection reverted instead of returning false");
        assertFalse(abi.decode(ret, (bool)), "garbage accepted");
    }

    /// `r2` is a pure function of the calldata, so the result is deterministic:
    /// an accepted instance is accepted again and a rejected one rejected again.
    function test_deterministic() public view {
        assertTrue(_batch(t[0], u[0]), "valid instance rejected");
        assertTrue(_batch(t[0], u[0]), "valid instance rejected on the second call");

        P memory bad = t[0];
        bad.pub[DIGEST] ^= 1;
        assertFalse(_batch(bad, u[0]), "tampered instance accepted");
        assertFalse(_batch(bad, u[0]), "tampered instance accepted on the second call");
    }

    // --- gas -----------------------------------------------------------------

    /// The batched check costs less than two single verifications: six pairings
    /// (45k + 6*34k) against two sets of four (2 * (45k + 4*34k)), plus four
    /// extra `ECMUL`s, one extra `ECADD` and one keccak over 736 bytes. The
    /// six `IC` folds, three per circuit, are common to both.
    ///
    /// Measured here in isolation: most MASP spend tests mock verification, and
    /// `MASPTransferSnarkTest` measures a whole spend rather than the pairing.
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
        // Both fixtures are proved from one circuits package.
        assertEq(
            vm.parseJsonString(tj, ".source.package"), vm.parseJsonString(uj, ".source.package"), "circuits package"
        );
    }
}
