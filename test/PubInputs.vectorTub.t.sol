// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../src/libs/PubInputs.sol";

/// Exposes the library across an external call boundary so the `calldata`
/// fast path receives real calldata.
contract VectorTubHarness {
    using PubInputs for PubInputs.TreeUpdateBatch;

    function compress(PubInputs.TreeUpdateBatch calldata tpi) external pure returns (uint256[2] memory) {
        return PubInputs.compress(tpi);
    }

    function compressRef(PubInputs.TreeUpdateBatch memory tpi) external pure returns (uint256[2] memory) {
        return PubInputs.compressRef(tpi);
    }
}

/// Pins `compress(TreeUpdateBatch)` against the `tree-update-batch-8` vector
/// published by the circuits package (version 0.8.0).
///
/// `PubInputs.t.sol` fuzzes `compress == compressRef`, but both are written in
/// this repo: a misreading of the circuit's 52-slot order would be reproduced
/// identically on both sides and pass. This drives the struct from the
/// circuit's own witness and compares against the `(y, z)` the compiled circuit
/// produced, so the layout is anchored outside the repo.
///
/// Unlike the 3x3 vector there is no substituted slot — the batch circuit takes
/// every coefficient as a public input, so all 52 come from the vector verbatim
/// and the published `(y, z)` can be asserted directly.
contract PubInputsVectorTubTest is Test {
    string internal constant VECTOR = "test/fixtures/tree_update_batch_vector.json";
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant COEFFS = 4 + 6 * PubInputs.MAX_L_BATCH;

    VectorTubHarness internal h;
    string internal json;

    function setUp() public {
        h = new VectorTubHarness();
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
        assertEq(vm.parseJsonString(json, ".circuit.template"), "TreeUpdateBatch(10, 8)", "template");
        assertEq(_u(".circuit.coeffCount"), COEFFS, "coeff count");
        assertEq(_u(".circuit.shape.maxL"), PubInputs.MAX_L_BATCH, "maxL");
    }

    function _loadTpi(uint256 v) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        string memory b = string.concat(_base(v), ".witness");
        tpi.oldRoot = bytes32(_u(string.concat(b, ".old_root")));
        tpi.newRoot = bytes32(_u(string.concat(b, ".new_root")));
        tpi.startIndex = uint64(_u(string.concat(b, ".start_index")));
        tpi.actualCount = uint64(_u(string.concat(b, ".actual_count")));
        for (uint256 k = 0; k < PubInputs.MAX_L_BATCH; k++) {
            string memory idx = string.concat("[", vm.toString(k), "]");
            tpi.cms[k] = bytes32(_u(string.concat(b, ".cms", idx)));
            tpi.cvDeps[k][0] = _u(string.concat(b, ".cv_dep", idx, "[0]"));
            tpi.cvDeps[k][1] = _u(string.concat(b, ".cv_dep", idx, "[1]"));
            tpi.leafAsset[k] = uint64(_u(string.concat(b, ".leaf_asset", idx)));
            tpi.leafPublicIn[k] = uint64(_u(string.concat(b, ".leaf_public_in", idx)));
            tpi.isDeposit[k] = uint8(_u(string.concat(b, ".is_deposit", idx)));
        }
    }

    function _horner(uint256[] memory c, uint256 z) internal pure returns (uint256 y) {
        for (uint256 i = c.length; i > 0; i--) {
            y = addmod(mulmod(y, z, R), c[i - 1], R);
        }
    }

    /// Both the calldata fast path and the memory reference must reproduce the
    /// `(y, z)` the circuit itself committed to.
    function _runVector(uint256 v) internal view {
        PubInputs.TreeUpdateBatch memory tpi = _loadTpi(v);
        uint256 z = _u(string.concat(_base(v), ".compression.z"));
        uint256 y = _u(string.concat(_base(v), ".compression.y"));

        uint256[2] memory got = h.compress(tpi);
        assertEq(got[1], z, "z mismatch against vector layout");
        assertEq(got[0], y, "y mismatch against vector layout");

        uint256[2] memory ref = h.compressRef(tpi);
        assertEq(ref[1], z, "compressRef z mismatch");
        assertEq(ref[0], y, "compressRef y mismatch");
    }

    function test_vector0_singleDepositEmptyTree() public view {
        _runVector(0);
    }

    function test_vector1_oddThreeLeafBatch() public view {
        _runVector(1);
    }

    function test_vector2_mixedBatchNonzeroStart() public view {
        _runVector(2);
    }

    /// The struct fields are loaded from the witness, so a permuted layout on
    /// the contract side changes `(y, z)`. Guard that the comparison is
    /// actually sensitive: the vector's own coefficient vector, perturbed, must
    /// not reproduce what `compress` returns.
    function test_layoutComparisonIsSensitive() public view {
        PubInputs.TreeUpdateBatch memory tpi = _loadTpi(2);

        uint256[] memory coeffs = new uint256[](COEFFS);
        for (uint256 i = 0; i < COEFFS; i++) {
            coeffs[i] = _u(string.concat(_base(2), ".compression.coeffs[", vm.toString(i), "]"));
        }
        // Swap oldRoot and newRoot: same-typed neighbours a contract that
        // emitted them in the wrong order would produce exactly.
        (coeffs[0], coeffs[1]) = (coeffs[1], coeffs[0]);
        uint256 z = uint256(keccak256(abi.encode(coeffs))) % R;
        uint256 y = _horner(coeffs, z);

        uint256[2] memory got = h.compress(tpi);
        assertTrue(got[0] != y || got[1] != z, "permuted layout must not match");
    }

    /// The vector's published coefficient vector must be exactly what the
    /// contract hashes — checked independently of `(y, z)`, which a
    /// compensating error in both the layout and the Horner evaluation could
    /// otherwise hide.
    function test_coefficientVectorMatchesVector() public view {
        for (uint256 v = 0; v < 3; v++) {
            uint256[] memory coeffs = new uint256[](COEFFS);
            for (uint256 i = 0; i < COEFFS; i++) {
                coeffs[i] = _u(string.concat(_base(v), ".compression.coeffs[", vm.toString(i), "]"));
            }
            assertEq(
                keccak256(abi.encode(coeffs)),
                keccak256(vm.parseJsonBytes(json, string.concat(_base(v), ".compression.abiEncodedCoeffs"))),
                "abi encoding of the coefficient vector"
            );
            assertEq(uint256(keccak256(abi.encode(coeffs))) % R, _u(string.concat(_base(v), ".compression.z")), "z");
        }
    }
}
