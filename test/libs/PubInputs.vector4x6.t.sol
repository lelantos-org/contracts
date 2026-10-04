// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { CompressHarness, Y, DIGEST, Z } from "../utils/CompressHarness.sol";

/// Pins `compress(Transact)` against the `transact-4x6` vector of the circuits
/// package (schema `lelantos.circuits.vectors/2`). The circuits version the
/// copy under `test/fixtures/` comes from is recorded in
/// `test/fixtures/README.md`.
///
/// The other layout tests check the contract against reference code in this
/// repo, where a misreading of the circuit would be reproduced on both sides.
/// This one drives the struct from the circuit's own witness and compares to
/// the `[y, digest, z]` the compiled circuit produced, anchoring the 38-word
/// challenge and 13-coefficient order outside the repo.
///
/// `auxDigest` is the one word not taken from the vector: the SDK derives it
/// from its own abi-hash module while the contract recomputes it from aux
/// calldata. The final challenge word is therefore substituted with the
/// contract-computed aux digest and `(y, z)` re-derived over the result. The
/// circuit's `digest` signal commits to the coefficients only, so the
/// substitution leaves it untouched and it is asserted against the published
/// value directly.
///
/// The vector carries two lists, and their split is the property under test:
/// `compression.challenge` is all 38 words `z` hashes; `compression.coeffs` is
/// the 13 the circuit evaluates into `y` and commits to in `digest`. Of the 25
/// in between, the first is that digest, which must precede the challenge it
/// protects; the rest (the five address, chain and intent words, the clue
/// triples, the aux digest) are not signals of the circuit and bind through
/// `z` alone.
contract PubInputsVector4x6Test is Test {
    string internal constant VECTOR = "test/fixtures/transact_4x6_vector.json";
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    CompressHarness internal h;
    string internal json;

    function setUp() public {
        h = new CompressHarness();
        json = vm.readFile(VECTOR);
    }

    function _u(string memory path) internal view returns (uint256) {
        return vm.parseJsonUint(json, path);
    }

    function _base(uint256 i) internal pure returns (string memory) {
        return string.concat(".vectors[", vm.toString(i), "]");
    }

    /// Checks the vector file's metadata against the deployed shape; the
    /// remaining assertions assume the file is the artifact the circuit
    /// published.
    function test_vectorMetadataMatchesDeployedShape() public view {
        assertEq(vm.parseJsonString(json, ".circuit.template"), "Transact(11, 4, 6)", "template");
        assertEq(_u(".circuit.coeffCount"), PubInputs.TRANSACT_COEFFS, "coeff count");
        assertEq(_u(".circuit.challengeWords"), PubInputs.TRANSACT_CHALLENGE_WORDS, "challenge words");
        assertEq(_u(".circuit.shape.nIn"), PubInputs.TRANSACT_IN, "nIn");
        assertEq(_u(".circuit.shape.nOut"), PubInputs.TRANSACT_OUT, "nOut");

        // The order `compress` returns and both verifiers take.
        string[] memory signals = vm.parseJsonStringArray(json, ".circuit.publicSignals");
        assertEq(signals.length, 3, "public signal count");
        assertEq(signals[0], "y", "signal 0");
        assertEq(signals[1], "digest", "signal 1");
        assertEq(signals[2], "z", "signal 2");
    }

    function _loadPi(uint256 v) internal view returns (PubInputs.Transact memory pi) {
        string memory b = string.concat(_base(v), ".witness");
        pi.merkleRoot = bytes32(_u(string.concat(b, ".merkle_root")));
        for (uint256 k = 0; k < PubInputs.TRANSACT_IN; k++) {
            string memory idx = string.concat("[", vm.toString(k), "]");
            pi.nullifier[k] = bytes32(_u(string.concat(b, ".nullifier", idx)));
        }
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; k++) {
            string memory idx = string.concat("[", vm.toString(k), "]");
            pi.outCm[k] = bytes32(_u(string.concat(b, ".out_cm", idx)));
        }
        pi.publicAssetId = uint64(_u(string.concat(b, ".public_asset_id")));
        pi.publicOut = uint64(_u(string.concat(b, ".public_out")));
        // The prover's copy of the circuit's digest signal, as calldata
        // carries it.
        pi.digest = _u(string.concat(b, ".digest"));
        pi.recipient = address(uint160(_u(string.concat(b, ".recipient_address"))));
        pi.chainId = _u(string.concat(b, ".chain_id"));
        pi.payer = address(uint160(_u(string.concat(b, ".payer_address"))));
        pi.relayer = address(uint160(_u(string.concat(b, ".relayer_address"))));
        pi.intentHash = _u(string.concat(b, ".intent_hash"));
    }

    /// Clue words are read from `aux`, so the aux blobs reproduce the witness's
    /// clue values, with `clueBits` in the 2-byte ciphertext prefix the
    /// contract parses.
    function _loadAux(uint256 v) internal view returns (AuxValidation.Output[6] memory aux) {
        string memory b = string.concat(_base(v), ".witness");
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; k++) {
            string memory idx = string.concat("[", vm.toString(k), "]");
            aux[k].clueRx = _u(string.concat(b, ".out_clue_Rx", idx));
            aux[k].clueRy = _u(string.concat(b, ".out_clue_Ry", idx));
            aux[k].ciphertext = abi.encodePacked(uint16(_u(string.concat(b, ".out_clue_bits", idx))));
        }
    }

    /// The vector's published 38-word challenge preimage, verbatim.
    function _publishedChallenge(uint256 v) internal view returns (uint256[] memory c) {
        uint256 n = PubInputs.TRANSACT_CHALLENGE_WORDS;
        c = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            c[i] = _u(string.concat(_base(v), ".compression.challenge[", vm.toString(i), "]"));
        }
    }

    /// The 38-word challenge preimage, with the final word (the aux digest)
    /// replaced by the contract-computed value.
    function _expectedChallenge(uint256 v, uint256 auxDigest) internal view returns (uint256[] memory c) {
        c = _publishedChallenge(v);
        c[c.length - 1] = auxDigest;
    }

    /// The circuit's digest signal, which the vector states three times: as the
    /// circuit's output, in the compression record, and as the witness input
    /// calldata carries. One value, or the file is not self-consistent.
    function _publishedDigest(uint256 v) internal view returns (uint256 digest) {
        digest = _u(string.concat(_base(v), ".circuitOutput.digest"));
        assertEq(_u(string.concat(_base(v), ".compression.digest")), digest, "compression.digest");
        assertEq(_u(string.concat(_base(v), ".witness.digest")), digest, "witness.digest");
    }

    /// The 13 coefficients the polynomial evaluates, read from the vector's own
    /// list rather than sliced from the preimage, so a disagreement about which
    /// words are coefficients fails instead of being reproduced.
    function _expectedCoeffs(uint256 v) internal view returns (uint256[] memory c) {
        uint256 n = PubInputs.TRANSACT_COEFFS;
        c = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            c[i] = _u(string.concat(_base(v), ".compression.coeffs[", vm.toString(i), "]"));
        }
    }

    function _horner(uint256[] memory c, uint256 z) internal pure returns (uint256 y) {
        for (uint256 i = c.length; i > 0; i--) {
            y = addmod(mulmod(y, z, R), c[i - 1], R);
        }
    }

    function _runVector(uint256 v) internal view {
        PubInputs.Transact memory pi = _loadPi(v);
        AuxValidation.Output[6] memory aux = _loadAux(v);

        uint256 auxDigest = h.auxDigest(aux);
        uint256[] memory challenge = _expectedChallenge(v, auxDigest);
        uint256[] memory coeffs = _expectedCoeffs(v);
        uint256 z = uint256(keccak256(abi.encode(challenge))) % R;
        uint256 y = _horner(coeffs, z);

        uint256[3] memory got = h.transact(pi, aux);
        assertEq(got[Y], y, "y mismatch against vector layout");
        assertEq(got[DIGEST], _publishedDigest(v), "digest is not the circuit's");
        assertEq(got[Z], z, "z mismatch against vector layout");
    }

    function test_vector0_internalTransfer() public view {
        _runVector(0);
    }

    function test_vector1_transferOneDummy() public view {
        _runVector(1);
    }

    function test_vector2_withdrawPublicOut() public view {
        _runVector(2);
    }

    /// The vector's own compression record is consistent with the layout this
    /// suite assumes, before any word is substituted: the preimage hashes to
    /// the published `z`, the coefficients are its 13-word prefix and evaluate
    /// to the `y` the circuit output, and the word after them is the digest.
    /// Checked apart from `_runVector`, where an error in reading the file and
    /// one in the contract could cancel out.
    function test_publishedCompressionMatchesVector() public view {
        for (uint256 v = 0; v < 3; v++) {
            uint256[] memory challenge = _publishedChallenge(v);
            uint256[] memory coeffs = _expectedCoeffs(v);
            string memory c = string.concat(_base(v), ".compression");

            assertEq(
                keccak256(abi.encode(challenge)),
                keccak256(vm.parseJsonBytes(json, string.concat(c, ".abiEncodedChallenge"))),
                "abi encoding of the challenge preimage"
            );
            uint256 z = uint256(keccak256(abi.encode(challenge))) % R;
            assertEq(z, _u(string.concat(c, ".z")), "z");
            assertEq(z, _u(string.concat(_base(v), ".witness.z")), "witness z");

            for (uint256 i = 0; i < coeffs.length; i++) {
                assertEq(coeffs[i], challenge[i], "coefficient is the preimage prefix");
            }
            assertEq(challenge[PubInputs.TRANSACT_COEFFS], _publishedDigest(v), "digest follows the coefficients");
            assertEq(
                challenge[challenge.length - 1],
                _u(string.concat(_base(v), ".witness.out_aux_digest")),
                "aux digest closes the preimage"
            );

            uint256 y = _horner(coeffs, z);
            assertEq(y, _u(string.concat(c, ".y")), "y");
            assertEq(y, _u(string.concat(_base(v), ".circuitOutput.y")), "circuit output y");
        }
    }

    /// A transfer names no asset: the two vectors that withdraw nothing carry
    /// `public_asset_id` 0, which the circuit forces and `MASP.transfer`
    /// checks; the withdrawal names the asset it pays out.
    function test_vectorsNameAnAssetOnlyWhenWithdrawing() public view {
        for (uint256 v = 0; v < 3; v++) {
            PubInputs.Transact memory pi = _loadPi(v);
            assertEq(pi.publicAssetId == 0, pi.publicOut == 0, "asset named iff value leaves");
        }
        assertEq(_loadPi(2).publicOut, 150, "vector 2 withdraws");
    }

    /// Every word is the vector's own, so a permuted layout on the contract side
    /// changes `(y, z)`. Confirms the comparison is sensitive: perturbing the
    /// expected layout breaks the match.
    function test_layoutComparisonIsSensitive() public view {
        PubInputs.Transact memory pi = _loadPi(0);
        AuxValidation.Output[6] memory aux = _loadAux(0);
        uint256[] memory challenge = _expectedChallenge(0, h.auxDigest(aux));
        uint256[] memory coeffs = _expectedCoeffs(0);

        // Swaps two same-typed neighbours, as a contract emitting them in the
        // wrong order would. Nullifiers 0 and 1 are words 1 and 2 of both lists,
        // so the perturbation reaches both `z` and `y`.
        (challenge[1], challenge[2]) = (challenge[2], challenge[1]);
        (coeffs[1], coeffs[2]) = (coeffs[2], coeffs[1]);
        uint256 z = uint256(keccak256(abi.encode(challenge))) % R;
        uint256 y = _horner(coeffs, z);

        uint256[3] memory got = h.transact(pi, aux);
        assertTrue(got[Y] != y || got[Z] != z, "permuted layout must not match");
    }

    /// Words hashed but not evaluated still bind; this is what allows them to
    /// have no signal in the circuit.
    ///
    /// The recipient is not a coefficient, so changing it leaves the coefficient
    /// vector, and the digest committing to it, untouched. If it did not reach
    /// `z`, the contract would derive the same signals for a different payee
    /// and a relayer could redirect a withdrawal. `z` changes, and `y`, being
    /// the same polynomial at a new point, with it.
    function test_challengeOnlyWordsStillBind() public view {
        PubInputs.Transact memory pi = _loadPi(2);
        AuxValidation.Output[6] memory aux = _loadAux(2);
        uint256[3] memory before_ = h.transact(pi, aux);

        pi.recipient = address(uint160(pi.recipient) + 1);
        uint256[3] memory after_ = h.transact(pi, aux);

        assertTrue(after_[Z] != before_[Z], "recipient must move z");
        assertTrue(after_[Y] != before_[Y], "recipient must move y");
        assertEq(after_[DIGEST], before_[DIGEST], "recipient is not under the digest");
    }

    /// The digest binds through `z` as well, and only through `z`: a calldata
    /// digest other than the circuit's still compresses, to a different
    /// challenge, and is handed to the verifier as given, where it fails the
    /// proof's own digest signal.
    function test_digestWordReachesZAndTheVerifier() public view {
        PubInputs.Transact memory pi = _loadPi(2);
        AuxValidation.Output[6] memory aux = _loadAux(2);
        uint256[3] memory before_ = h.transact(pi, aux);

        pi.digest = addmod(pi.digest, 1, R);
        uint256[3] memory after_ = h.transact(pi, aux);

        assertEq(after_[DIGEST], pi.digest, "digest returned as given");
        assertTrue(after_[Z] != before_[Z], "digest must move z");
        assertEq(after_[Y], _horner(_expectedCoeffs(2), after_[Z]), "y is the coefficients alone at the new z");
    }
}
