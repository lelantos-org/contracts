// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../../src/libs/PubInputs.sol";

import { CompressHarness, Y, DIGEST, Z } from "../utils/CompressHarness.sol";

/// Pins `compress(TreeUpdateBatch)` against the `tree-update-batch-8` vector
/// of the circuits package.
///
/// `test/fixtures/tree_update_batch_vector.json` is a copy of
/// `circuits/vectors/tree-update-batch-8.json`, since forge cannot read across
/// the repository boundary; the circuits version it comes from is recorded in
/// `test/fixtures/README.md`. `just vectors-consumers-check` in the circuits
/// repo fails when the two disagree; without it this suite would pass against
/// a stale copy of the layout.
///
/// `PubInputs.t.sol` fuzzes `compress == compressRef`, but both are written in
/// this repo, so a misreading of the circuit's 36-slot order would be
/// reproduced on both sides. This suite drives the struct from the circuit's
/// own witness and compares against the `[y, digest, z]` the compiled circuit
/// produced, anchoring the layout outside the repo.
///
/// Unlike the 4x6 transact vector there is no substituted slot: every word of
/// the preimage comes from the vector verbatim, so the published signals are
/// asserted directly. The digest is not a witness input here; the struct takes
/// it from `compression.digest`, the value the circuit output, which is what a
/// flusher puts in calldata.
contract PubInputsVectorTubTest is Test {
    string internal constant VECTOR = "test/fixtures/tree_update_batch_vector.json";
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    /// Evaluated into `y` and committed to by `digest`: every word of the
    /// struct but the digest itself, including the `leafAsset` /
    /// `leafPublicIn` / `isDeposit` blocks. They are signals of
    /// `tree_update_batch.circom`, so hashing them into `z` alone would bind
    /// nothing; see `PubInputs.sol :: BATCH_COEFFS`.
    uint256 internal constant COEFFS = 4 + 4 * PubInputs.MAX_L_BATCH;

    /// Hashed into `z`: the coefficients, then the digest word.
    uint256 internal constant CHALLENGE_WORDS = COEFFS + 1;

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
        assertEq(vm.parseJsonString(json, ".circuit.template"), "TreeUpdateBatch(11, 8)", "template");
        assertEq(_u(".circuit.coeffCount"), COEFFS, "coeff count");
        assertEq(_u(".circuit.challengeWords"), CHALLENGE_WORDS, "challenge words");
        assertEq(_u(".circuit.shape.maxL"), PubInputs.MAX_L_BATCH, "maxL");

        // The order `compress` returns and both verifiers take.
        string[] memory signals = vm.parseJsonStringArray(json, ".circuit.publicSignals");
        assertEq(signals.length, 3, "public signal count");
        assertEq(signals[0], "y", "signal 0");
        assertEq(signals[1], "digest", "signal 1");
        assertEq(signals[2], "z", "signal 2");
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
            tpi.leafAsset[k] = uint64(_u(string.concat(b, ".leaf_asset", idx)));
            tpi.leafPublicIn[k] = uint64(_u(string.concat(b, ".leaf_public_in", idx)));
            tpi.isDeposit[k] = uint8(_u(string.concat(b, ".is_deposit", idx)));
        }
        tpi.digest = _digest(v);
    }

    /// The circuit's digest signal, which the vector states as the circuit's
    /// output and again in the compression record.
    function _digest(uint256 v) internal view returns (uint256 digest) {
        digest = _u(string.concat(_base(v), ".circuitOutput.digest"));
        assertEq(_u(string.concat(_base(v), ".compression.digest")), digest, "compression.digest");
    }

    function _horner(uint256[] memory c, uint256 z) internal pure returns (uint256 y) {
        for (uint256 i = c.length; i > 0; i--) {
            y = addmod(mulmod(y, z, R), c[i - 1], R);
        }
    }

    /// Both the calldata fast path and the memory reference reproduce the
    /// `[y, digest, z]` the circuit committed to.
    function _runVector(uint256 v) internal view {
        PubInputs.TreeUpdateBatch memory tpi = _loadTpi(v);
        uint256 z = _u(string.concat(_base(v), ".compression.z"));
        uint256 y = _u(string.concat(_base(v), ".compression.y"));
        uint256 digest = _digest(v);
        assertEq(_u(string.concat(_base(v), ".circuitOutput.y")), y, "circuit output y");
        assertEq(_u(string.concat(_base(v), ".witness.z")), z, "witness z");

        uint256[3] memory got = h.batch(tpi);
        assertEq(got[Y], y, "y mismatch against vector layout");
        assertEq(got[DIGEST], digest, "digest is not the circuit's");
        assertEq(got[Z], z, "z mismatch against vector layout");

        uint256[3] memory ref = h.batchRef(tpi);
        assertEq(ref[Y], y, "compressRef y mismatch");
        assertEq(ref[DIGEST], digest, "compressRef digest mismatch");
        assertEq(ref[Z], z, "compressRef z mismatch");
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
    /// the contract side changes `(y, z)`. Confirms the comparison is
    /// sensitive: the vector's own preimage, perturbed, does not reproduce what
    /// `compress` returns.
    function test_layoutComparisonIsSensitive() public view {
        PubInputs.TreeUpdateBatch memory tpi = _loadTpi(2);

        uint256[] memory challenge = _challenge(2);
        // Swaps oldRoot and newRoot, as a contract emitting these same-typed
        // neighbours in the wrong order would. They are words [0] and [1] of
        // both the preimage and the coefficient prefix.
        (challenge[0], challenge[1]) = (challenge[1], challenge[0]);

        uint256 z = uint256(keccak256(abi.encode(challenge))) % R;
        uint256[] memory coeffs = new uint256[](COEFFS);
        for (uint256 i = 0; i < COEFFS; i++) {
            coeffs[i] = challenge[i];
        }
        uint256 y = _horner(coeffs, z);

        uint256[3] memory got = h.batch(tpi);
        assertTrue(got[Y] != y || got[Z] != z, "permuted layout must not match");
    }

    /// The vector's published challenge preimage, as an array.
    function _challenge(uint256 v) internal view returns (uint256[] memory c) {
        c = new uint256[](CHALLENGE_WORDS);
        for (uint256 i = 0; i < CHALLENGE_WORDS; i++) {
            c[i] = _u(string.concat(_base(v), ".compression.challenge[", vm.toString(i), "]"));
        }
    }

    /// The vector's published preimage matches its ABI encoding and `z`, its
    /// coefficient list is the preimage prefix and evaluates to the published
    /// `y`, and the one word after the coefficients is the digest. Checked
    /// independently of `_runVector`, where compensating errors in the layout
    /// and the Horner evaluation could cancel out.
    function test_coefficientVectorMatchesVector() public view {
        for (uint256 v = 0; v < 3; v++) {
            uint256[] memory challenge = _challenge(v);
            assertEq(
                keccak256(abi.encode(challenge)),
                keccak256(vm.parseJsonBytes(json, string.concat(_base(v), ".compression.abiEncodedChallenge"))),
                "abi encoding of the challenge preimage"
            );
            uint256 z = uint256(keccak256(abi.encode(challenge))) % R;
            assertEq(z, _u(string.concat(_base(v), ".compression.z")), "z");

            // The coefficients are the preimage's prefix, not a separate list.
            uint256[] memory coeffs = new uint256[](COEFFS);
            for (uint256 i = 0; i < COEFFS; i++) {
                coeffs[i] = _u(string.concat(_base(v), ".compression.coeffs[", vm.toString(i), "]"));
                assertEq(coeffs[i], challenge[i], "coefficient is the preimage prefix");
            }
            // The digest is hashed after them and is not one of them.
            assertEq(challenge[COEFFS], _digest(v), "digest closes the preimage");
            assertEq(_horner(coeffs, z), _u(string.concat(_base(v), ".compression.y")), "y");
        }
    }

    /// A deposit slot's `cms` word is the depositor's `inner`, not the tree
    /// leaf: the vector records the leaf the circuit built from it, and for a
    /// deposit the two differ, while a spend slot's `cms` is inserted as it
    /// stands. This is the reading of `cms[k]` that `MASP._drainDeposit`
    /// relies on when it pins `isDeposit` to 1 for an escrowed `inner`.
    function test_depositLeafIsBuiltFromInner() public view {
        for (uint256 v = 0; v < 3; v++) {
            PubInputs.TreeUpdateBatch memory tpi = _loadTpi(v);
            for (uint256 k = 0; k < tpi.actualCount; k++) {
                string memory leafPath = string.concat(_base(v), ".intermediates.leaves[", vm.toString(k), "]");
                uint256 leaf = _u(string.concat(leafPath, ".leaf"));
                assertEq(_u(string.concat(leafPath, ".cms")), uint256(tpi.cms[k]), "cms is the witness word");
                if (tpi.isDeposit[k] == 1) {
                    assertTrue(leaf != uint256(tpi.cms[k]), "a deposit's leaf is not its inner");
                } else {
                    assertEq(leaf, uint256(tpi.cms[k]), "a spend's leaf is its commitment");
                }
            }
        }
    }
}
