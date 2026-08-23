// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { SnarkCompression } from "../src/SnarkCompression.sol";

/// Exposes the library across an external call boundary so the `calldata`
/// fast path receives real calldata.
contract Vector3x3Harness {
    using PubInputs for PubInputs.Transact;

    function compress(PubInputs.Transact calldata pi, AuxValidation.Output[3] calldata aux)
        external
        pure
        returns (uint256[2] memory)
    {
        return PubInputs.compress(pi, aux);
    }

    function auxDigest(AuxValidation.Output[3] calldata aux) external pure returns (uint256) {
        return PubInputs.auxDigest(aux);
    }
}

/// Pins `compress(Transact)` against the `transact-3x3` vector published by
/// the circuits package (version 0.9.2).
///
/// The other layout tests check the contract against reference code written in
/// this repo, so a misreading of the circuit would be reproduced identically on
/// both sides and pass. This one drives the struct from the circuit's own
/// witness and compares to the `(y, z)` the compiled circuit produced, so the
/// 42-slot order is anchored outside the repo.
///
/// `auxDigest` is the one slot that cannot come from the vector: the circuit
/// takes it as an input while the contract recomputes it from aux calldata, by
/// design. Slot 41 is therefore substituted with the contract-computed digest
/// and `(y, z)` re-derived over the result; slots 0..40 are the vector's
/// verbatim.
contract PubInputsVector3x3Test is Test {
    string internal constant VECTOR = "test/fixtures/transact_3x3_vector.json";
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    Vector3x3Harness internal h;
    string internal json;

    function setUp() public {
        h = new Vector3x3Harness();
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
        assertEq(vm.parseJsonString(json, ".circuit.template"), "Transact(10, 3, 3)", "template");
        assertEq(_u(".circuit.coeffCount"), PubInputs.TRANSACT_COEFFS, "coeff count");
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
    function _loadAux(uint256 v) internal view returns (AuxValidation.Output[3] memory aux) {
        string memory b = string.concat(_base(v), ".witness");
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; k++) {
            string memory idx = string.concat("[", vm.toString(k), "]");
            aux[k].clueRx = _u(string.concat(b, ".out_clue_Rx", idx));
            aux[k].clueRy = _u(string.concat(b, ".out_clue_Ry", idx));
            aux[k].ciphertext = abi.encodePacked(uint16(_u(string.concat(b, ".out_clue_bits", idx))));
        }
    }

    function _expectedCoeffs(uint256 v, uint256 digest) internal view returns (uint256[] memory c) {
        uint256 n = PubInputs.TRANSACT_COEFFS;
        c = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            c[i] = _u(string.concat(_base(v), ".compression.coeffs[", vm.toString(i), "]"));
        }
        // Slot 41: circuit input vs contract-recomputed. See contract docs.
        c[n - 1] = digest;
    }

    function _horner(uint256[] memory c, uint256 z) internal pure returns (uint256 y) {
        for (uint256 i = c.length; i > 0; i--) {
            y = addmod(mulmod(y, z, R), c[i - 1], R);
        }
    }

    function _runVector(uint256 v) internal view {
        PubInputs.Transact memory pi = _loadPi(v);
        AuxValidation.Output[3] memory aux = _loadAux(v);

        uint256 digest = h.auxDigest(aux);
        uint256[] memory coeffs = _expectedCoeffs(v, digest);
        uint256 z = uint256(keccak256(abi.encode(coeffs))) % R;
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

    /// Slots 0..40 are the vector's own values, so a permuted layout on the
    /// contract side changes `(y, z)`. Guard that the comparison is actually
    /// sensitive: perturbing one coefficient must break it.
    function test_layoutComparisonIsSensitive() public view {
        PubInputs.Transact memory pi = _loadPi(0);
        AuxValidation.Output[3] memory aux = _loadAux(0);
        uint256[] memory coeffs = _expectedCoeffs(0, h.auxDigest(aux));

        // Swap two same-typed neighbours: a contract that emitted them in the
        // wrong order would produce exactly this vector.
        (coeffs[1], coeffs[2]) = (coeffs[2], coeffs[1]);
        uint256 z = uint256(keccak256(abi.encode(coeffs))) % R;
        uint256 y = _horner(coeffs, z);

        uint256[2] memory got = h.compress(pi, aux);
        assertTrue(got[0] != y || got[1] != z, "permuted layout must not match");
    }
}
