// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

/// Exposes the library across an external call boundary so the `calldata`
/// fast path receives real calldata.
contract Vector4x6Harness {
    using PubInputs for PubInputs.Transact;

    function compress(PubInputs.Transact calldata pi, AuxValidation.Output[6] calldata aux)
        external
        pure
        returns (uint256[2] memory)
    {
        return PubInputs.compress(pi, aux);
    }

    function auxDigest(AuxValidation.Output[6] calldata aux) external pure returns (uint256) {
        return PubInputs.auxDigest(aux);
    }
}

/// Pins `compress(Transact)` against the `transact-4x6` vector published by
/// the circuits package (version 0.11.2).
///
/// The other layout tests check the contract against reference code written in
/// this repo, so a misreading of the circuit would be reproduced identically on
/// both sides and pass. This one drives the struct from the circuit's own
/// witness and compares to the `(y, z)` the compiled circuit produced, so the
/// 42-slot order is anchored outside the repo.
///
/// `auxDigest` is the one word that cannot come from the vector: the SDK derives
/// it from its own abi-hash module while the contract recomputes it from aux
/// calldata, by design. The final challenge word is therefore substituted with
/// the contract-computed digest and `(y, z)` re-derived over the result; every
/// other word is the vector's verbatim.
///
/// Two vectors, and the split is the property under test: `compression.challenge`
/// is all 69 logical public inputs and is what `z` hashes; the 46 the circuit
/// pins are what `y` evaluates. The 23 in between — the four address words, the
/// clue triples, the aux digest — bind through `z` alone. As coefficients they
/// were free variables a prover could solve `y = Σ c[k]·z^k` with after reading
/// `z`, since the circuit constrains none of them.
contract PubInputsVector4x6Test is Test {
    string internal constant VECTOR = "test/fixtures/transact_4x6_vector.json";
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    Vector4x6Harness internal h;
    string internal json;

    function setUp() public {
        h = new Vector4x6Harness();
        json = vm.readFile(VECTOR);
    }

    function _u(string memory path) internal view returns (uint256) {
        return vm.parseJsonUint(json, path);
    }

    function _base(uint256 i) internal pure returns (string memory) {
        return string.concat(".vectors[", vm.toString(i), "]");
    }

    /// The vector file must be the artifact the circuit published, not a
    /// hand-edited copy: every assertion below is only as good as its
    /// provenance.
    function test_vectorMetadataMatchesDeployedShape() public view {
        assertEq(vm.parseJsonString(json, ".circuit.template"), "Transact(11, 4, 6)", "template");
        assertEq(_u(".circuit.coeffCount"), PubInputs.TRANSACT_COEFFS, "coeff count");
        assertEq(_u(".circuit.challengeWords"), PubInputs.TRANSACT_CHALLENGE_WORDS, "challenge words");
        assertEq(_u(".circuit.shape.nIn"), PubInputs.TRANSACT_IN, "nIn");
        assertEq(_u(".circuit.shape.nOut"), PubInputs.TRANSACT_OUT, "nOut");
    }

    function _loadPi(uint256 v) internal view returns (PubInputs.Transact memory pi) {
        string memory b = string.concat(_base(v), ".witness");
        pi.merkleRoot = bytes32(_u(string.concat(b, ".merkle_root")));
        for (uint256 k = 0; k < PubInputs.TRANSACT_IN; k++) {
            string memory idx = string.concat("[", vm.toString(k), "]");
            pi.nullifier[k] = bytes32(_u(string.concat(b, ".nullifier", idx)));
            pi.inCv[k][0] = _u(string.concat(b, ".in_cv", idx, "[0]"));
            pi.inCv[k][1] = _u(string.concat(b, ".in_cv", idx, "[1]"));
        }
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; k++) {
            string memory idx = string.concat("[", vm.toString(k), "]");
            pi.outCm[k] = bytes32(_u(string.concat(b, ".out_cm", idx)));
            pi.outCv[k][0] = _u(string.concat(b, ".out_cv", idx, "[0]"));
            pi.outCv[k][1] = _u(string.concat(b, ".out_cv", idx, "[1]"));
            pi.outCvDep[k][0] = _u(string.concat(b, ".out_cv_dep", idx, "[0]"));
            pi.outCvDep[k][1] = _u(string.concat(b, ".out_cv_dep", idx, "[1]"));
        }
        pi.publicAssetId = uint64(_u(string.concat(b, ".public_asset_id")));
        pi.publicIn = uint64(_u(string.concat(b, ".public_in")));
        pi.publicOut = uint64(_u(string.concat(b, ".public_out")));
        pi.recipient = address(uint160(_u(string.concat(b, ".recipient_address"))));
        pi.chainId = _u(string.concat(b, ".chain_id"));
        pi.payer = address(uint160(_u(string.concat(b, ".payer_address"))));
        pi.relayer = address(uint160(_u(string.concat(b, ".relayer_address"))));
    }

    /// Clue coefficients are read off `aux`, so the aux blobs must reproduce
    /// the witness's clue values — `clueBits` via the 2-byte ciphertext prefix
    /// the contract parses.
    function _loadAux(uint256 v) internal view returns (AuxValidation.Output[6] memory aux) {
        string memory b = string.concat(_base(v), ".witness");
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; k++) {
            string memory idx = string.concat("[", vm.toString(k), "]");
            aux[k].clueRx = _u(string.concat(b, ".out_clue_Rx", idx));
            aux[k].clueRy = _u(string.concat(b, ".out_clue_Ry", idx));
            aux[k].ciphertext = abi.encodePacked(uint16(_u(string.concat(b, ".out_clue_bits", idx))));
        }
    }

    /// The 69-word challenge preimage, with the final word — the aux digest —
    /// replaced by what the contract recomputes. See the contract docs.
    function _expectedChallenge(uint256 v, uint256 digest) internal view returns (uint256[] memory c) {
        uint256 n = PubInputs.TRANSACT_CHALLENGE_WORDS;
        c = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            c[i] = _u(string.concat(_base(v), ".compression.challenge[", vm.toString(i), "]"));
        }
        c[n - 1] = digest;
    }

    /// The 46 coefficients the polynomial evaluates, read from the vector's own
    /// list rather than sliced out of the preimage — so a disagreement about
    /// WHICH words are coefficients fails here rather than being reproduced.
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

        uint256 digest = h.auxDigest(aux);
        uint256[] memory challenge = _expectedChallenge(v, digest);
        uint256[] memory coeffs = _expectedCoeffs(v);
        uint256 z = uint256(keccak256(abi.encode(challenge))) % R;
        uint256 y = _horner(coeffs, z);

        uint256[2] memory got = h.compress(pi, aux);
        assertEq(got[1], z, "z mismatch against vector layout");
        assertEq(got[0], y, "y mismatch against vector layout");
    }

    function test_vector0_internalTransfer() public view {
        _runVector(0);
    }

    function test_vector1_depositPublicIn() public view {
        _runVector(1);
    }

    function test_vector2_withdrawPublicOut() public view {
        _runVector(2);
    }

    /// Every word is the vector's own, so a permuted layout on the contract side
    /// changes `(y, z)`. Guard that the comparison is actually sensitive:
    /// perturbing one word must break it.
    function test_layoutComparisonIsSensitive() public view {
        PubInputs.Transact memory pi = _loadPi(0);
        AuxValidation.Output[6] memory aux = _loadAux(0);
        uint256 digest = h.auxDigest(aux);
        uint256[] memory challenge = _expectedChallenge(0, digest);
        uint256[] memory coeffs = _expectedCoeffs(0);

        // Swap two same-typed neighbours: a contract that emitted them in the
        // wrong order would produce exactly this vector. Nullifiers 0 and 1 are
        // words 1 and 2 of both vectors, so the perturbation reaches `z` and `y`
        // alike.
        (challenge[1], challenge[2]) = (challenge[2], challenge[1]);
        (coeffs[1], coeffs[2]) = (coeffs[2], coeffs[1]);
        uint256 z = uint256(keccak256(abi.encode(challenge))) % R;
        uint256 y = _horner(coeffs, z);

        uint256[2] memory got = h.compress(pi, aux);
        assertTrue(got[0] != y || got[1] != z, "permuted layout must not match");
    }

    /// The words hashed but not evaluated still bind, and that is the whole
    /// reason they may be unconstrained in the circuit.
    ///
    /// Moving the recipient leaves the coefficient vector untouched — it is not
    /// a coefficient — so if it did not reach `z` the contract would derive the
    /// same `(y, z)` for a different payee and a relayer could redirect any
    /// withdrawal. Both outputs must move.
    function test_challengeOnlyWordsStillBind() public view {
        PubInputs.Transact memory pi = _loadPi(2);
        AuxValidation.Output[6] memory aux = _loadAux(2);
        uint256[2] memory before_ = h.compress(pi, aux);

        pi.recipient = address(uint160(pi.recipient) + 1);
        uint256[2] memory after_ = h.compress(pi, aux);

        assertTrue(after_[1] != before_[1], "recipient must move z");
        assertTrue(after_[0] != before_[0], "recipient must move y");
    }
}
