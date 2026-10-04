// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { GuardAsserts } from "./GuardAsserts.sol";

import { SnarkCompression } from "../../src/SnarkCompression.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { SpendFixture } from "../utils/SpendFixture.sol";

/// Exposes the three calldata compressions as external calls, so a proof can
/// hand them raw calldata words and observe a rejection as a revert.
contract PubInputsCompressHarness {
    function transact(PubInputs.Transact calldata pi, AuxValidation.Output[6] calldata aux)
        external
        pure
        returns (uint256[3] memory)
    {
        return PubInputs.compress(pi, aux);
    }

    function batch(PubInputs.TreeUpdateBatch calldata tpi) external pure returns (uint256[3] memory) {
        return PubInputs.compress(tpi);
    }

    function spend(PubInputs.Transact calldata pi, PubInputs.SpendTree calldata st, bytes32 oldRoot)
        external
        pure
        returns (uint256[3] memory)
    {
        return PubInputs.compressSpend(pi, st, oldRoot);
    }
}

/// Symbolic proofs for the shape of the three public-input compressions: which
/// calldata words are hashed into the challenge `z`, which are evaluated into
/// `y`, and what happens to the digest word.
///
/// Each circuit has three public signals, `[y, digest, z]`. `digest` is the
/// circuit's Poseidon commitment to its own coefficients; calldata carries the
/// prover's copy. The binding rests on three facts about that copy, stated in
/// `PubInputs.TRANSACT_COEFFS`: it reaches the verifier unmodified, it is in the
/// keccak preimage of `z`, and it is not one of the words `y` is evaluated
/// over. Every coefficient must be in that preimage too. The proofs below state
/// those facts for every calldata word, where `PubInputs.t.sol` samples them
/// against `compressRef`.
///
/// The compressions are keccak and `mulmod` folds, but the proofs stay
/// tractable because none asks the solver about either. Each proof rebuilds the
/// expected word with the same operations in the same order (one keccak over
/// the same bytes, one Horner fold over the same words), so the two sides are
/// the same term and the comparison is settled without arithmetic. The only
/// branches are the range checks on the evaluated words. Out of reach is any
/// property of the value of `y` or `z`: that two preimages give different
/// challenges, or that two coefficient vectors evaluate differently.
///
/// The words are symbolic as raw calldata, dirty high bits included, wherever
/// the compression reads calldata raw. The aux payloads are held concrete at
/// `SpendFixture.validAux()`: they contribute the clue words and the aux
/// digest, which are derived values, not calldata words of the struct.
contract PubInputsSymbolicTest is GuardAsserts {
    uint256 internal constant R = SnarkCompression.R;

    /// `Transact` in calldata words: 13 coefficients, the digest, then the five
    /// words the circuit has no signal for.
    uint256 internal constant TRANSACT_WORDS = 19;
    uint256 internal constant TRANSACT_COEFFS = 13;
    uint256 internal constant TRANSACT_DIGEST = 13;
    uint256 internal constant TRANSACT_CHALLENGE_WORDS = 38;

    /// `TreeUpdateBatch` in calldata words: 36 coefficients, then the digest.
    uint256 internal constant BATCH_WORDS = 37;
    uint256 internal constant BATCH_COEFFS = 36;
    uint256 internal constant BATCH_DIGEST = 36;

    /// The spend's batch image: the header and the six `outCm` slots can be
    /// non-zero, the rest of the 36 coefficients is zero padding.
    uint256 internal constant SPEND_COEFFS = 10;

    uint256 internal constant MASK_U64 = type(uint64).max;
    uint256 internal constant MASK_U160 = type(uint160).max;

    PubInputsCompressHarness internal h;

    function setUp() public {
        h = new PubInputsCompressHarness();
    }

    // --- references ---------------------------------------------------------

    /// `keccak256(abi.encode(uint256[])) mod R`, the challenge derivation.
    function _challenge(uint256[] memory pre) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(pre))) % R;
    }

    /// Horner evaluation of the first `n` words of `pre` at `z`, top
    /// coefficient first.
    function _evaluate(uint256[] memory pre, uint256 n, uint256 z) internal pure returns (uint256 y) {
        for (uint256 k = n; k > 0; --k) {
            y = addmod(mulmod(y, z, R), pre[k - 1], R);
        }
    }

    // --- tree-update batch --------------------------------------------------

    /// The batch preimage as `compress` must build it from raw calldata words:
    /// the sub-word members cleaned to their widths, the digest word as given.
    function _batchPreimage(uint256[BATCH_WORDS] memory w) internal pure returns (uint256[] memory pre) {
        pre = new uint256[](BATCH_WORDS);
        pre[0] = w[0]; // oldRoot
        pre[1] = w[1]; // newRoot
        pre[2] = w[2] & MASK_U64; // startIndex
        pre[3] = w[3] & MASK_U64; // actualCount
        for (uint256 k = 4; k < 12; ++k) {
            pre[k] = w[k]; // cms
        }
        for (uint256 k = 12; k < 28; ++k) {
            pre[k] = w[k] & MASK_U64; // leafAsset, leafPublicIn
        }
        for (uint256 k = 28; k < 36; ++k) {
            pre[k] = w[k] & 0xff; // isDeposit
        }
        pre[BATCH_DIGEST] = w[BATCH_DIGEST];
    }

    function _compressBatch(uint256[BATCH_WORDS] memory w) internal view returns (bool ok, bytes memory ret) {
        // The struct is fully static, so its calldata block is the 37 words.
        (ok, ret) = address(h).staticcall(abi.encodePacked(PubInputsCompressHarness.batch.selector, w));
    }

    /// The batch compression returns `[y, digest, z]` with: the digest word
    /// exactly as calldata gave it, dirty bits and out-of-field values
    /// included; `z` the hash of all 37 words, the digest among them; and `y`
    /// the evaluation of the 36 coefficients alone.
    ///
    /// The third clause is what "hashed but not evaluated" means: were the
    /// digest folded into `y` as a 37th coefficient, the two sides would
    /// differ. The first is what lets the verifier compare the word against the
    /// circuit's own output.
    function check_batch_digestIsHashedReturnedAndNotEvaluated(uint256[BATCH_WORDS] memory w) public view {
        (bool ok, bytes memory ret) = _compressBatch(w);
        vm.assume(ok);
        uint256[3] memory out = abi.decode(ret, (uint256[3]));

        uint256[] memory pre = _batchPreimage(w);
        uint256 z = _challenge(pre);

        assertEq(out[1], w[BATCH_DIGEST], "digest word modified");
        assertEq(out[2], z, "z is not the hash of the 37 words");
        assertEq(out[0], _evaluate(pre, BATCH_COEFFS, z), "y is not the 36 coefficients at z");
    }

    /// The batch compression rejects exactly an out-of-field coefficient, and
    /// never the digest.
    ///
    /// Only the full-word coefficients can be out of field: the roots and the
    /// eight `cms` slots. Every other coefficient is cleaned to at most 64
    /// bits. The digest is a public signal the verifier range-checks, so
    /// `compress` accepts any word there.
    function check_batch_rejectsExactlyOutOfFieldCoefficients(uint256[BATCH_WORDS] memory w) public view {
        bool inField = w[0] < R && w[1] < R;
        for (uint256 k = 4; k < 12; ++k) {
            inField = inField && w[k] < R;
        }

        (bool ok, bytes memory ret) = _compressBatch(w);

        assertEq(ok, inField);
        if (!ok) assertEq(bytes4(ret), SnarkCompression.CoefficientOutOfField.selector);
    }

    // --- transact -----------------------------------------------------------

    /// One aux payload per output with the given clue points and the fixture's
    /// ciphertext. `compress` reads the clue coordinates and the two-byte
    /// clue-bits prefix and hashes the whole payload; it validates none of it
    /// (`AuxValidation` does, before the pool calls it), so the coordinates
    /// can be any words.
    function _aux(uint256[2][6] memory clue) internal pure returns (AuxValidation.Output[6] memory aux) {
        aux = SpendFixture.validAux();
        for (uint256 j; j < aux.length; ++j) {
            aux[j].clueRx = clue[j][0];
            aux[j].clueRy = clue[j][1];
        }
    }

    /// The transact preimage as `compress` must build it: the 19 struct words
    /// with the sub-word members cleaned, then `(clueRx, clueRy, clueBits)` per
    /// output, then the aux digest.
    function _transactPreimage(uint256[TRANSACT_WORDS] memory w, AuxValidation.Output[6] memory aux)
        internal
        pure
        returns (uint256[] memory pre)
    {
        pre = new uint256[](TRANSACT_CHALLENGE_WORDS);
        for (uint256 k; k < TRANSACT_WORDS; ++k) {
            pre[k] = w[k];
        }
        pre[11] = w[11] & MASK_U64; // publicAssetId
        pre[12] = w[12] & MASK_U64; // publicOut
        // [13] digest, [15] chainId and [18] intentHash are full words.
        pre[14] = w[14] & MASK_U160; // recipient
        pre[16] = w[16] & MASK_U160; // payer
        pre[17] = w[17] & MASK_U160; // relayer

        AuxValidation.Output[] memory dyn = new AuxValidation.Output[](aux.length);
        for (uint256 j; j < aux.length; ++j) {
            uint256 slot = TRANSACT_WORDS + 3 * j;
            pre[slot] = aux[j].clueRx;
            pre[slot + 1] = aux[j].clueRy;
            pre[slot + 2] = (uint256(uint8(aux[j].ciphertext[0])) << 8) | uint256(uint8(aux[j].ciphertext[1]));
            dyn[j] = aux[j];
        }
        pre[TRANSACT_CHALLENGE_WORDS - 1] = uint256(keccak256(abi.encode(dyn))) % R;
    }

    /// Calls a harness entry point whose first argument is `Transact`, with the
    /// struct's calldata block replaced by the raw words `w`. The struct is
    /// static, so its 19 words lead the arguments.
    function _withTransactWords(bytes memory data, uint256[TRANSACT_WORDS] memory w)
        internal
        view
        returns (bool ok, bytes memory ret)
    {
        for (uint256 k; k < TRANSACT_WORDS; ++k) {
            uint256 word = w[k];
            uint256 offset = 0x24 + k * 0x20; // past the length word and the selector
            assembly ("memory-safe") {
                mstore(add(data, offset), word)
            }
        }
        (ok, ret) = address(h).staticcall(data);
    }

    function _compressTransact(uint256[TRANSACT_WORDS] memory w, AuxValidation.Output[6] memory aux)
        internal
        view
        returns (bool ok, bytes memory ret)
    {
        PubInputs.Transact memory blank;
        return _withTransactWords(abi.encodeCall(PubInputsCompressHarness.transact, (blank, aux)), w);
    }

    /// The transact compression returns `[y, digest, z]` with: the digest word
    /// (word 13) exactly as calldata gave it; `z` the hash of all 38 words (the
    /// 13 coefficients, the digest, the five words the circuit has no signal
    /// for, the 18 clue words and the aux digest); and `y` the evaluation of
    /// the 13 coefficients alone.
    ///
    /// So the digest, `recipient`, `chainId`, `payer`, `relayer`, `intentHash`
    /// and the clues move `z` and nothing else: none of them is a coefficient.
    function check_transact_digestIsHashedReturnedAndNotEvaluated(
        uint256[TRANSACT_WORDS] memory w,
        uint256[2][6] memory clue
    ) public view {
        AuxValidation.Output[6] memory aux = _aux(clue);
        (bool ok, bytes memory ret) = _compressTransact(w, aux);
        vm.assume(ok);
        uint256[3] memory out = abi.decode(ret, (uint256[3]));

        uint256[] memory pre = _transactPreimage(w, aux);
        uint256 z = _challenge(pre);

        assertEq(out[1], w[TRANSACT_DIGEST], "digest word modified");
        assertEq(out[2], z, "z is not the hash of the 38 words");
        assertEq(out[0], _evaluate(pre, TRANSACT_COEFFS, z), "y is not the 13 coefficients at z");
    }

    /// The transact compression rejects exactly an out-of-field coefficient.
    ///
    /// The root, the four nullifiers and the six output commitments are the
    /// full-word coefficients; `publicAssetId` and `publicOut` are cleaned to 64
    /// bits. Everything from the digest on is hashed only, so no value there is
    /// rejected: the verifier range-checks the digest as a public signal, and
    /// the rest never reaches a field operation.
    function check_transact_rejectsExactlyOutOfFieldCoefficients(uint256[TRANSACT_WORDS] memory w) public view {
        bool inField = true;
        for (uint256 k; k < 11; ++k) {
            inField = inField && w[k] < R;
        }

        (bool ok, bytes memory ret) = _compressTransact(w, SpendFixture.validAux());

        assertEq(ok, inField);
        if (!ok) assertEq(bytes4(ret), SnarkCompression.CoefficientOutOfField.selector);
    }

    // --- spend image --------------------------------------------------------

    /// The batch image a spend implies:
    /// `[oldRoot, newRoot, startIndex, 6, outCm[0..5], 26 zero words, digest]`.
    function _spendPreimage(uint256[TRANSACT_WORDS] memory w, PubInputs.SpendTree memory st, bytes32 oldRoot)
        internal
        pure
        returns (uint256[] memory pre)
    {
        pre = new uint256[](BATCH_WORDS);
        pre[0] = uint256(oldRoot);
        pre[1] = uint256(st.newRoot);
        pre[2] = st.startIndex;
        pre[3] = 6; // actualCount: TRANSACT_OUT
        for (uint256 k; k < 6; ++k) {
            pre[4 + k] = w[5 + k]; // outCm follows merkleRoot and four nullifiers
        }
        pre[BATCH_DIGEST] = st.digest;
    }

    function _compressSpend(uint256[TRANSACT_WORDS] memory w, PubInputs.SpendTree memory st, bytes32 oldRoot)
        internal
        view
        returns (bool ok, bytes memory ret)
    {
        PubInputs.Transact memory blank;
        return _withTransactWords(abi.encodeCall(PubInputsCompressHarness.spend, (blank, st, oldRoot)), w);
    }

    /// The spend's tree-update image is built from the spend's own `outCm`, the
    /// live root and the three words the relayer supplies, and from nothing
    /// else in the request: the digest returned is `st.digest` as given, `z` is
    /// the hash of the 37-word image with that digest as its last word, and `y`
    /// is the evaluation of the ten words that can be non-zero.
    ///
    /// Every other word of `Transact` is symbolic and appears nowhere in the
    /// expected values, and neither does `anchorIndex`, a lookup hint. The
    /// contract cannot afford the Poseidon fold over the image, which is why
    /// the digest is supplied; it is hashed and returned like the flush path's.
    function check_spend_imageBindsOutCmAndCarriesTheDigest(
        uint256[TRANSACT_WORDS] memory w,
        bytes32 newRoot,
        uint64 startIndex,
        uint8 anchorIndex,
        uint256 digest,
        bytes32 oldRoot
    ) public view {
        PubInputs.SpendTree memory st = PubInputs.SpendTree({
            newRoot: newRoot, startIndex: startIndex, anchorIndex: anchorIndex, digest: digest
        });
        (bool ok, bytes memory ret) = _compressSpend(w, st, oldRoot);
        vm.assume(ok);
        uint256[3] memory out = abi.decode(ret, (uint256[3]));

        uint256[] memory pre = _spendPreimage(w, st, oldRoot);
        uint256 z = _challenge(pre);

        assertEq(out[1], digest, "digest word modified");
        assertEq(out[2], z, "z is not the hash of the spend's batch image");
        assertEq(out[0], _evaluate(pre, SPEND_COEFFS, z), "y is not the image's ten live coefficients at z");
    }

    /// The spend image is, word for word, the challenge preimage the flush
    /// path hashes for the one batch the pool accepts for this spend: the same
    /// `z` and the same digest out of `compress(TreeUpdateBatch)`.
    ///
    /// `y` is left to `PubInputsSpendTest`: the flush path folds the 26 zero
    /// coefficients the spend path skips, which is the same value but not the
    /// same term, and the solvers do not reduce it.
    function check_spend_challengeMatchesTheFlushPath(
        uint256[TRANSACT_WORDS] memory w,
        bytes32 newRoot,
        uint64 startIndex,
        uint256 digest,
        bytes32 oldRoot
    ) public view {
        PubInputs.SpendTree memory st = PubInputs.SpendTree({
            newRoot: newRoot, startIndex: startIndex, anchorIndex: 0, digest: digest
        });
        (bool ok, bytes memory ret) = _compressSpend(w, st, oldRoot);
        vm.assume(ok);
        uint256[3] memory spent = abi.decode(ret, (uint256[3]));

        uint256[] memory pre = _spendPreimage(w, st, oldRoot);
        uint256[BATCH_WORDS] memory image;
        for (uint256 k; k < BATCH_WORDS; ++k) {
            image[k] = pre[k];
        }
        (ok, ret) = _compressBatch(image);
        vm.assume(ok);
        uint256[3] memory flushed = abi.decode(ret, (uint256[3]));

        assertEq(spent[1], flushed[1], "digest differs between the two paths");
        assertEq(spent[2], flushed[2], "challenge differs between the two paths");
    }
}
