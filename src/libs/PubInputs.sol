// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { SnarkCompression } from "../SnarkCompression.sol";
import { AuxValidation } from "./AuxValidation.sol";

/// Public-input structs and Fiat-Shamir compression. Layouts must match the
/// circuit-side PolyEval coefficient orders word-for-word.
library PubInputs {
    /// Shielded inputs and outputs of `4x6.circom` — `Transact(11, 4, 6)`.
    /// Changing either requires a new circuit, a new ceremony, and a new
    /// verifier.
    uint256 internal constant TRANSACT_IN = 4;
    uint256 internal constant TRANSACT_OUT = 6;

    /// `4x6.circom` public inputs before compression: 19 struct words, followed
    /// in the challenge preimage by `3 * TRANSACT_OUT` clue words and the aux
    /// digest, which `compress` derives from `aux`.
    ///
    /// A note commits to its asset and value by hash,
    /// `cm = Poseidon(TAG_CM, asset * 2^64 + value, inner)`, and `outCm` is the
    /// tree leaf. There is no value commitment and no `publicIn`: a spend never
    /// moves tokens into the pool.
    struct Transact {
        bytes32 merkleRoot;
        bytes32[TRANSACT_IN] nullifier;
        bytes32[TRANSACT_OUT] outCm;
        // Zero unless `publicOut != 0`: the circuit forces it, so a transfer
        // names no asset.
        uint64 publicAssetId;
        uint64 publicOut;
        // Poseidon commitment to the thirteen words above, which are the
        // PolyEval coefficients. The circuit outputs it as a public signal; this
        // is the prover's copy. `compress` hashes it into `z`, does not evaluate
        // it into `y`, never recomputes it, and returns it for the verifier to
        // compare. See `TRANSACT_COEFFS`.
        uint256 digest;
        // Not signals of `4x6.circom`, so hashed into `z` and never evaluated
        // into `y`. They follow the digest so the coefficients are the calldata
        // block's leading `TRANSACT_COEFFS` words, evaluated in one Horner
        // span.
        address recipient;
        uint256 chainId;
        address payer;
        address relayer;
        // Commitment to what the spend's funds are used for, in the field.
        // `SwapWrapper` requires it to equal the hash of the swap intent, so
        // whoever submits the swap cannot change its output, floor, venue,
        // deadline or refund owner. Every other entry point ignores it, and the
        // SDK sends zero there. Full word: not re-masked in `compress`.
        uint256 intentHash;
    }

    /// MAX_L of `tree_update_batch.circom`. The coefficient vector is
    /// `4 + 4*MAX_L_BATCH = 36` words and the challenge preimage those plus the
    /// digest word; drift in either breaks the circuit-to-contract binding.
    ///
    /// 8 is the smallest fit at the 4x6 transact shape: `COUNT_BITS` requires a
    /// power of two and a spend emits `TRANSACT_OUT` = 6 leaves that must fit
    /// one batch. A wider transact shape requires a new ceremony.
    uint256 internal constant MAX_L_BATCH = 8;

    /// `tree_update_batch.circom` public inputs. Layout:
    ///   oldRoot, newRoot, startIndex, actualCount,
    ///   cms[0..MAX_L-1],
    ///   leafAsset[0..MAX_L-1], leafPublicIn[0..MAX_L-1], isDeposit[0..MAX_L-1],
    ///   digest.
    /// Every array is indexed by leaf, not by pair: `actualCount` is a leaf
    /// count in `[1, MAX_L_BATCH]`, so the circuit admits an odd number of
    /// leaves. Slots beyond `actualCount` must be zero, both in-circuit and
    /// on-chain.
    ///
    /// `cms[k]` is read by `isDeposit[k]`. On a spend leaf it is the note
    /// commitment, and is the tree leaf. On a deposit leaf it is the
    /// depositor's `inner`, and the circuit builds the leaf as
    /// `Poseidon(TAG_CM, leafAsset[k] * 2^64 + leafPublicIn[k], cms[k])`. The
    /// leaf of a deposit is therefore never a calldata word.
    struct TreeUpdateBatch {
        bytes32 oldRoot;
        bytes32 newRoot;
        uint64 startIndex;
        uint64 actualCount;
        bytes32[MAX_L_BATCH] cms;
        uint64[MAX_L_BATCH] leafAsset;
        uint64[MAX_L_BATCH] leafPublicIn;
        uint8[MAX_L_BATCH] isDeposit;
        // Poseidon commitment to the 36 words above; see `Transact.digest`.
        uint256 digest;
    }

    /// The part of a spend's tree update the relayer supplies.
    ///
    /// Everything else in a spend's `TreeUpdateBatch` is fixed: `oldRoot` is the
    /// live root, `actualCount` is `TRANSACT_OUT`, `cms` is the spend's own
    /// `outCm` (the circuit zeroes the two trailing slots), and `leafAsset`,
    /// `leafPublicIn` and `isDeposit` are zero on every spend leaf (circuit
    /// steps 1 and 4). `compressSpend` rebuilds that image from `Transact`
    /// instead of reading a copy from calldata.
    struct SpendTree {
        bytes32 newRoot;
        uint64 startIndex;
        /// Position of `Transact.merkleRoot` in the root ring buffer. A lookup
        /// hint, not a public input: a wrong index only fails `UnknownRoot`.
        uint8 anchorIndex;
        /// The batch circuit's digest public signal for this spend's tree
        /// update, as the prover computed it over the 36 batch coefficients.
        /// The contract knows every one of those coefficients, but cannot
        /// afford the Poseidon fold, so the word is supplied; a wrong one fails
        /// the proof.
        uint256 digest;
    }

    /// Depositor-signed payload, bound via the Permit2 witness.
    ///
    /// A deposit occupies two leaves: the depositor's note and a note paying the
    /// relayer that flushes it. Each is bound independently by the batch
    /// circuit, which builds the leaf from the public amount and `inner`:
    /// `Poseidon(TAG_CM, publicAssetId * 2^64 + publicIn, inner)`, and likewise
    /// for the fee note. That is the commitment a spend opens, so each note can
    /// be spent only as the amount escrowed for it.
    ///
    /// `inner` is `Poseidon(TAG_INNER, pk, rho, rcm)`: the owner half of the
    /// note, hiding `pk` behind `rcm`. One that is not of that form, or whose
    /// preimage the recipient never learns, escrows a deposit nobody can spend,
    /// reclaimable only through `cancelDeposit` before it is flushed.
    ///
    /// Paying the relayer in a note keeps its identity and the fee amount off
    /// the event and makes the fee unstealable: `flushBatch` is permissionless,
    /// so an on-chain amount payable to `msg.sender` could be claimed by
    /// whoever front-runs the assembled batch.
    struct DepositRequest {
        /// Full width, matching `Transact.chainId`, and one ABI word in the
        /// Permit2 witness preimage. Dirty high bits fail the `!= block.chainid`
        /// gate rather than being masked off by a narrower type.
        uint256 chainId;
        uint64 publicAssetId;
        uint64 publicIn;
        address payer;
        address recipient;
        bytes32 inner;
        /// Relayer fee note. `feeIn` may be zero; the leaf is minted either
        /// way, so a deposit always occupies two leaves.
        ///
        /// `feeAssetId` is the registered asset the note is denominated in and
        /// the payer is charged in. It may differ from `publicAssetId`, in which
        /// case the pool pulls two tokens (see `feeInDepositAsset`). Only the
        /// relayer's note moves to it: the treasury's deposit fee stays in the
        /// deposit asset. It must be 0, "no asset", when `feeIn` is 0; a valued
        /// fee note in a yield asset is accepted only when that asset is
        /// `publicAssetId`.
        uint64 feeAssetId;
        uint64 feeIn;
        bytes32 feeInner;
    }

    /// Leaves one deposit occupies: the depositor's note and the relayer's.
    uint256 internal constant LEAVES_PER_DEPOSIT = 2;

    /// Whether a deposit's relayer note is charged in the deposit asset, in one
    /// pull with the principal, rather than separately in `feeAssetId`'s token.
    /// A zero-value note charges nothing and counts as in the deposit asset.
    ///
    /// The single rule for the deposit's path, applied by `MASP` at submit and
    /// cancel, mirrored inline by `MaspEscrowSatellite`, and by the SDK to
    /// choose which permit to sign. Decided by asset id, not token address: a
    /// plain id and a yield id may share one ERC-20 yet price and book
    /// differently, and Permit2's batch transfers accept one token named twice.
    function feeInDepositAsset(uint256 feeIn, uint64 feeAssetId, uint64 publicAssetId) internal pure returns (bool) {
        return feeIn == 0 || feeAssetId == publicAssetId;
    }

    /// The relayer's leaf as it appears in the escrow digest, and so in every
    /// call that resupplies that preimage: `flushBatch`, `cancelDeposit`, and
    /// the adapters forwarding to them.
    ///
    /// Distinct from `DepositRequest`'s fee fields, the submitted form: `feeIn`
    /// is narrowed here to `uint48`, the digest's width, enforced at submit.
    ///
    /// `feeAssetId` is carried so the digest binds the fee note's asset:
    /// `_drainDeposit` fills it from the batch's `leafAsset` of the fee leaf,
    /// and a cancel refunds the note's value in that asset's token.
    ///
    /// Fully static, so `abi.encode` of this struct yields the same three words
    /// as its fields encoded inline;
    /// `MASPDepositTest.test_happy_pullsFundsAndEscrows` pins that encoding.
    struct FeeNote {
        uint48 feeIn;
        uint64 feeAssetId;
        bytes32 feeInner;
    }

    /// Word indices into the `Transact` calldata block, in struct order.
    /// `merkleRoot`, the nullifiers and the output commitments precede the two
    /// `uint64` publics; then the digest; then `recipient`, `chainId`, `payer`,
    /// `relayer` and `intentHash`. The coefficients are the leading words, the
    /// digest is the word after them, and the five words the circuit has no
    /// signal for come last.
    uint256 private constant W_OUT_CM = 1 + TRANSACT_IN;
    uint256 private constant W_PUBLIC_ASSET_ID = W_OUT_CM + TRANSACT_OUT;
    uint256 private constant W_DIGEST = W_PUBLIC_ASSET_ID + 2;
    uint256 private constant W_RECIPIENT = W_DIGEST + 1;
    uint256 private constant W_PAYER = W_RECIPIENT + 2;
    uint256 private constant W_INTENT_HASH = W_RECIPIENT + 4;

    /// Both structs are fully static, so their ABI calldata block is
    /// word-for-word identical to the leading words of the challenge preimage,
    /// on which the calldata `compress` overloads rely; `PubInputs.t.sol` pins
    /// that equivalence against the `memory` reference paths. Derived from the
    /// shape (`19` at the 4x6 shape) as the tail of the `W_*` walk, so the
    /// struct layout is stated once and every offset follows `TRANSACT_OUT`.
    uint256 private constant TRANSACT_CALLDATA_WORDS = W_INTENT_HASH + 1;

    /// Words hashed to produce `z`: the struct, then `(clueRx, clueRy,
    /// clueBits)` per output, then the aux digest —
    /// `10 + TRANSACT_IN + 4*TRANSACT_OUT = 38`.
    ///
    /// The words after the coefficients and the digest are bound without a
    /// circuit constraint: altering any of them changes `z`, which is a public
    /// signal of the proof. This binds the recipient, chain id, payer, relayer,
    /// intent hash, FMD clues and encrypted-payload digest against a tampering
    /// relayer.
    uint256 internal constant TRANSACT_CHALLENGE_WORDS = TRANSACT_CALLDATA_WORDS + 3 * TRANSACT_OUT + 1;

    /// Words the polynomial is evaluated over: `3 + TRANSACT_IN + TRANSACT_OUT
    /// = 13`, the leading run of the challenge preimage and exactly the
    /// coefficient signals of `4x6.circom`'s `TransactCompressN`.
    ///
    /// `y = Σ c_k z^k` is affine in each coefficient and `z` is derived from
    /// calldata the prover authored, so the prover reads `z` before choosing
    /// its witness. On its own the evaluation therefore binds nothing: a prover
    /// can move several coefficients of its witness independently and solve
    /// for the `y` the contract computed from other calldata.
    ///
    /// What binds is the word after the coefficients, `digest`. The circuit
    /// outputs a Poseidon commitment to its own coefficients as a public
    /// signal. `compress` takes the calldata copy of that word, hashes it into
    /// `z`, and returns it for the verifier to compare. So the witness's
    /// coefficients are committed before `z` exists, the calldata coefficients
    /// are in the preimage too, and two different vectors agree at a random
    /// `z` with probability at most `12 / R`. Three things must stay true:
    ///
    ///   * the digest word reaches the verifier unmodified, as the second
    ///     public signal;
    ///   * the digest word is in the keccak preimage of `z`;
    ///   * every coefficient is in the keccak preimage of `z`.
    ///
    /// The digest is not a coefficient and is never recomputed here.
    ///
    /// `recipient`, `chainId`, `payer`, `relayer`, `intentHash`, the clue fields
    /// and the aux digest are not signals of `4x6.circom`: there is no witness
    /// copy of them to disagree with calldata, so hashing them into `z` binds
    /// them.
    ///
    /// Defined as `W_DIGEST`: the coefficients end exactly where the digest
    /// word begins, which is the invariant the member order establishes.
    uint256 internal constant TRANSACT_COEFFS = W_DIGEST;

    /// Words the batch polynomial is evaluated over: `4 + 4*MAX_L_BATCH = 36`,
    /// every word of the struct but its last.
    ///
    /// Unlike the transact shape, nothing here is hashed without being
    /// evaluated, except the digest: every other word is a signal of
    /// `tree_update_batch.circom`. Hashing a signal into `z` without evaluating
    /// it binds nothing, because the prover reads `z` first and may supply a
    /// witness that disagrees with the hashed calldata. Excluding `leafAsset`,
    /// `leafPublicIn` or `isDeposit` would let a `flushBatch` caller escrow one
    /// unit and commit a leaf holding `2**63`.
    uint256 private constant BATCH_COEFFS = 4 + 4 * MAX_L_BATCH;

    /// Batch challenge preimage: the coefficients, then the digest word.
    uint256 private constant BATCH_CHALLENGE_WORDS = BATCH_COEFFS + 1;

    /// First clue word: the FMD triples follow the struct, and the aux digest
    /// closes the preimage. Both blocks are past `TRANSACT_COEFFS`, so neither
    /// is evaluated.
    uint256 private constant CLUE_BASE = TRANSACT_CALLDATA_WORDS;
    uint256 private constant AUX_DIGEST_SLOT = TRANSACT_CHALLENGE_WORDS - 1;

    uint256 private constant MASK_U64 = 0xffffffffffffffff;
    uint256 private constant MASK_U160 = 0x00ffffffffffffffffffffffffffffffffffffffff;

    // ================= calldata fast paths ===================================

    /// `compress(Transact)` read directly from calldata. The struct's words are
    /// copied verbatim; the trailing clue triples and aux digest are derived
    /// from `aux`. Avoids the calldata-to-memory ABI decode of the struct and
    /// the `abi.encode` copy `_finalize` performs.
    ///
    /// Returns `[y, digest, z]`, the verifier's public signals in order. All
    /// `TRANSACT_CHALLENGE_WORDS` are hashed into `z`; the leading
    /// `TRANSACT_COEFFS` are evaluated into `y`; the word after them is the
    /// digest, returned as given. See `TRANSACT_COEFFS`.
    function compress(Transact calldata pi, AuxValidation.Output[TRANSACT_OUT] calldata aux)
        internal
        pure
        returns (uint256[3] memory)
    {
        // Lay out `abi.encode(uint256[] memory)` in place: offset word, length
        // word, then the words. Hashing that region reproduces the reference
        // preimage without a second copy.
        uint256 n = TRANSACT_CHALLENGE_WORDS;
        uint256 copyLen = TRANSACT_CALLDATA_WORDS * 0x20;
        uint256 head;
        assembly ("memory-safe") {
            head := mload(0x40)
            mstore(head, 0x20)
            mstore(add(head, 0x20), n)
            calldatacopy(add(head, 0x40), pi, copyLen)
            mstore(0x40, add(head, add(0x40, mul(n, 0x20))))
        }
        uint256 d = head + 0x40;

        // Re-clean sub-word members: raw calldata may carry dirty high bits a
        // typed member read would have masked off. The word indices are the
        // shape-derived constants above and fold at compile time; they are
        // computed outside the block because inline assembly accepts only
        // literal constants.
        uint256 pAsset = d + W_PUBLIC_ASSET_ID * 0x20;
        uint256 pRecipient = d + W_RECIPIENT * 0x20;
        uint256 pPayer = d + W_PAYER * 0x20;
        assembly ("memory-safe") {
            // publicAssetId, publicOut
            let p := pAsset
            mstore(p, and(mload(p), MASK_U64))
            p := add(p, 0x20)
            mstore(p, and(mload(p), MASK_U64))
            mstore(pRecipient, and(mload(pRecipient), MASK_U160))
            p := pPayer // payer, then relayer
            mstore(p, and(mload(p), MASK_U160))
            p := add(p, 0x20)
            mstore(p, and(mload(p), MASK_U160))
        }

        for (uint256 j; j < TRANSACT_OUT;) {
            AuxValidation.Output calldata o = aux[j];
            uint256 rx = o.clueRx;
            uint256 ry = o.clueRy;
            uint256 clueBits = uint256(uint16(bytes2(o.ciphertext[0:2])));
            uint256 slot = d + (CLUE_BASE + 3 * j) * 0x20;
            assembly ("memory-safe") {
                mstore(slot, rx)
                mstore(add(slot, 0x20), ry)
                mstore(add(slot, 0x40), clueBits)
            }
            unchecked {
                ++j;
            }
        }

        // Final slot binds the whole encrypted-note payload. The per-output
        // clue fields above leave `ephPub` and `ciphertext` unbound, so without
        // it a relayer could corrupt the payload beyond recovery while leaving
        // the clue, and hence the proof and the recipient's FMD scan, intact.
        // Recomputed here, never read from calldata.
        uint256 payloadDigest = auxDigest(aux);
        uint256 payloadSlot = d + AUX_DIGEST_SLOT * 0x20;
        assembly ("memory-safe") {
            mstore(payloadSlot, payloadDigest)
        }
        return _finalizeRaw(head, n, TRANSACT_COEFFS, TRANSACT_COEFFS);
    }

    /// `keccak256(abi.encode(aux)) mod R` over the aux array encoded as a
    /// dynamic `tuple[]`, so the length joins the preimage and arrays of
    /// differing arity cannot collide. Mirrors the off-chain `auxDigest`.
    function auxDigest(AuxValidation.Output[TRANSACT_OUT] calldata aux) internal pure returns (uint256) {
        // The dynamic `tuple[]` encodes as `0x20 || length || X` and the fixed
        // array as `0x20 || X`, with the same `X`: one offset per element,
        // relative to the start of `X`, then the tuples. So the fixed array is
        // encoded straight from calldata and the two words in front of `X`
        // rewritten, rather than every payload decoded into memory first.
        bytes memory enc = abi.encode(aux);
        bytes32 h;
        assembly ("memory-safe") {
            let len := mload(enc)
            mstore(enc, 0x20)
            mstore(add(enc, 0x20), TRANSACT_OUT)
            h := keccak256(enc, add(len, 0x20))
        }
        return uint256(h) % SnarkCompression.R;
    }

    /// `compress(TreeUpdateBatch)` read directly from calldata. The whole
    /// challenge preimage is a single `calldatacopy`.
    ///
    /// Returns `[y, digest, z]`. All `BATCH_CHALLENGE_WORDS` are hashed into
    /// `z`; the leading `BATCH_COEFFS` are evaluated into `y`; the last word is
    /// the digest, returned as given. `nCoeffs` is passed explicitly rather
    /// than inferred from `n`, so excluding a word from evaluation is a change
    /// to the constant, where it must be justified. See `BATCH_COEFFS`.
    function compress(TreeUpdateBatch calldata tpi) internal pure returns (uint256[3] memory) {
        uint256 n = BATCH_CHALLENGE_WORDS;
        uint256 head;
        assembly ("memory-safe") {
            head := mload(0x40)
            mstore(head, 0x20)
            mstore(add(head, 0x20), n)
            calldatacopy(add(head, 0x40), tpi, mul(n, 0x20))
            mstore(0x40, add(head, add(0x40, mul(n, 0x20))))
        }
        uint256 d = head + 0x40;

        // Re-clean sub-word members (see the Transact path).
        // [4 + MAX_L .. 4 + 3*MAX_L) is leafAsset ++ leafPublicIn (uint64);
        // [4 + 3*MAX_L .. 4 + 4*MAX_L) is isDeposit (uint8). The digest word
        // that follows is a full word and is left as given.
        uint256 u64Start = d + (4 + MAX_L_BATCH) * 0x20;
        uint256 u64End = d + (4 + 3 * MAX_L_BATCH) * 0x20;
        uint256 u8End = d + BATCH_COEFFS * 0x20;
        assembly ("memory-safe") {
            // [2] startIndex, [3] actualCount
            let p := add(d, 0x40)
            mstore(p, and(mload(p), MASK_U64))
            p := add(p, 0x20)
            mstore(p, and(mload(p), MASK_U64))
            for { p := u64Start } lt(p, u64End) { p := add(p, 0x20) } { mstore(p, and(mload(p), MASK_U64)) }
            for { } lt(p, u8End) { p := add(p, 0x20) } { mstore(p, and(mload(p), 0xff)) }
        }
        return _finalizeRaw(head, n, BATCH_COEFFS, BATCH_COEFFS);
    }

    /// Words of a spend's batch image the polynomial is evaluated over: the
    /// header and the `outCm` slots, `4 + TRANSACT_OUT = 10`.
    ///
    /// This leaves no coefficient out. Every later word of the `BATCH_COEFFS`
    /// vector is zero padding `compressSpend` writes itself, never prover
    /// input, and a zero coefficient adds nothing to `y`. All
    /// `BATCH_CHALLENGE_WORDS` are still hashed into `z`.
    uint256 private constant SPEND_COEFFS = 4 + TRANSACT_OUT;

    /// `compress(TreeUpdateBatch)` for the batch a spend implies, without that
    /// batch in calldata. Word-for-word the image `compress(tpi)` hashes when
    /// `tpi` is the only batch `MASP` and the circuit accept for this spend:
    ///   [0] oldRoot  [1] newRoot  [2] startIndex  [3] TRANSACT_OUT
    ///   cms     = pi.outCm ++ zero padding
    ///   leafAsset, leafPublicIn, isDeposit = zero
    ///   digest  = st.digest
    /// and the same `[y, digest, z]`, with `y` evaluated over the
    /// `SPEND_COEFFS` words that can be non-zero.
    ///
    /// The prover supplies the batch circuit's digest word in `st` (see
    /// `SpendTree.digest`); it is hashed and returned exactly as on the flush
    /// path.
    function compressSpend(Transact calldata pi, SpendTree calldata st, bytes32 oldRoot)
        internal
        pure
        returns (uint256[3] memory)
    {
        uint256 n = BATCH_CHALLENGE_WORDS;
        uint256 startIndex = st.startIndex;
        bytes32 newRoot = st.newRoot;
        uint256 digest = st.digest;
        uint256 outCm = uint256(W_OUT_CM) * 0x20;
        uint256 cmsLen = TRANSACT_OUT * 0x20;
        uint256 padLen = (BATCH_COEFFS - SPEND_COEFFS) * 0x20;
        uint256 head;
        assembly ("memory-safe") {
            head := mload(0x40)
            mstore(head, 0x20)
            mstore(add(head, 0x20), n)
            let d := add(head, 0x40)
            mstore(d, oldRoot)
            mstore(add(d, 0x20), newRoot)
            mstore(add(d, 0x40), startIndex)
            mstore(add(d, 0x60), TRANSACT_OUT)
            d := add(d, 0x80)
            calldatacopy(d, add(pi, outCm), cmsLen)
            d := add(d, cmsLen)
            // Copying from past the end of calldata yields zeros.
            calldatacopy(d, calldatasize(), padLen)
            mstore(add(d, padLen), digest)
            mstore(0x40, add(head, add(0x40, mul(n, 0x20))))
        }
        return _finalizeRaw(head, n, SPEND_COEFFS, BATCH_COEFFS);
    }

    /// `head` points at an in-memory `abi.encode(uint256[] memory)` image:
    /// `0x20 || n || words`. All `n` words are hashed for `z`; the first
    /// `nCoeffs` are Horner-evaluated for `y`; word `digestAt` is the digest,
    /// returned unmodified.
    ///
    /// Serves both shapes. Each one's coefficients are the leading words of its
    /// preimage — that is what the member order of `Transact` and the slot
    /// order of `TreeUpdateBatch` are arranged to give — so one Horner span
    /// suffices. `digestAt` is the full coefficient count: it differs from
    /// `nCoeffs` only on the spend path, which skips coefficients known to be
    /// zero.
    ///
    /// The digest is not range-checked here. It is a public signal, and both
    /// verifiers reject a public signal outside the scalar field.
    function _finalizeRaw(uint256 head, uint256 n, uint256 nCoeffs, uint256 digestAt)
        private
        pure
        returns (uint256[3] memory out)
    {
        bytes32 h;
        uint256 digest;
        assembly ("memory-safe") {
            h := keccak256(head, add(0x40, mul(n, 0x20)))
            digest := mload(add(head, add(0x40, mul(digestAt, 0x20))))
        }
        uint256 z = uint256(h) % SnarkCompression.R;
        out[0] = SnarkCompression.evaluatePolyAtRaw(head + 0x40, nCoeffs, z);
        out[1] = digest;
        out[2] = z;
    }

    // ================= memory reference paths ================================
    //
    // Straight-line specification of the coefficient layout, implemented
    // independently of the calldata fast paths above. Not used on-chain;
    // `PubInputs.t.sol` fuzzes `compressRef == compress` for drift.

    /// `auxDigest` by decoding the payloads into a dynamic array and encoding
    /// that, which is the definition the fast path shortcuts.
    /// `AuxDigestDiff.t.sol` fuzzes the two against each other over
    /// non-canonical calldata as well.
    function auxDigestRef(AuxValidation.Output[TRANSACT_OUT] calldata aux) internal pure returns (uint256) {
        AuxValidation.Output[] memory dyn = new AuxValidation.Output[](TRANSACT_OUT);
        for (uint256 j; j < TRANSACT_OUT;) {
            dyn[j] = aux[j];
            unchecked {
                ++j;
            }
        }
        return uint256(keccak256(abi.encode(dyn))) % SnarkCompression.R;
    }

    /// Packs `Transact` into the `TRANSACT_CHALLENGE_WORDS = 38` challenge
    /// preimage and the `TRANSACT_COEFFS = 13` coefficient vector, and derives
    /// `[y, digest, z]`. The coefficient order matches `4x6.circom`'s
    /// `TransactCompressN`; the preimage order matches the calldata block.
    ///
    /// Each layout has its own cursor walk, rather than one walk plus a filter,
    /// so whether a word is a coefficient is stated by where it is written, not
    /// by an index computation.
    function compressRef(Transact memory pi, AuxValidation.Output[TRANSACT_OUT] calldata aux)
        internal
        pure
        returns (uint256[3] memory)
    {
        uint256[] memory pre = new uint256[](TRANSACT_CHALLENGE_WORDS);
        uint256[] memory c = new uint256[](TRANSACT_COEFFS);
        uint256 i = 0;
        uint256 j = 0;

        // Signals of the circuit, so hashed and evaluated both.
        pre[i++] = c[j++] = uint256(pi.merkleRoot);
        for (uint256 k; k < TRANSACT_IN; ++k) {
            pre[i++] = c[j++] = uint256(pi.nullifier[k]);
        }
        for (uint256 k; k < TRANSACT_OUT; ++k) {
            pre[i++] = c[j++] = uint256(pi.outCm[k]);
        }
        pre[i++] = c[j++] = uint256(pi.publicAssetId);
        pre[i++] = c[j++] = uint256(pi.publicOut);

        // The commitment to `c`, which is now complete: hashed, not evaluated.
        pre[i++] = pi.digest;

        // Everything from here has no signal in the circuit: hashed into `z`
        // only; see `TRANSACT_COEFFS`.
        pre[i++] = uint256(uint160(pi.recipient));
        pre[i++] = pi.chainId;
        pre[i++] = uint256(uint160(pi.payer));
        pre[i++] = uint256(uint160(pi.relayer));
        pre[i++] = pi.intentHash;

        // The FMD clues and the payload digest.
        for (uint256 k; k < TRANSACT_OUT; ++k) {
            pre[i++] = aux[k].clueRx;
            pre[i++] = aux[k].clueRy;
            pre[i++] = uint256(uint16(bytes2(aux[k].ciphertext[0:2])));
        }
        pre[i++] = auxDigestRef(aux);

        return _finalize(pre, c, pi.digest);
    }

    /// Packs `TreeUpdateBatch` into its `BATCH_COEFFS = 36` coefficient vector
    /// and its 37-word preimage, and derives `[y, digest, z]`. The order
    /// matches `tree_update_batch.circom`'s `BatchCompress` and the calldata
    /// block alike.
    function compressRef(TreeUpdateBatch memory tpi) internal pure returns (uint256[3] memory) {
        uint256[] memory pre = new uint256[](BATCH_CHALLENGE_WORDS);
        uint256[] memory c = new uint256[](BATCH_COEFFS);

        // Every word but the last is a signal of the circuit, so hashed and
        // evaluated both.
        pre[0] = c[0] = uint256(tpi.oldRoot);
        pre[1] = c[1] = uint256(tpi.newRoot);
        pre[2] = c[2] = uint256(tpi.startIndex);
        pre[3] = c[3] = uint256(tpi.actualCount);
        for (uint256 k; k < MAX_L_BATCH; ++k) {
            uint256 i = 4 + k;
            pre[i] = c[i] = uint256(tpi.cms[k]);
            i += MAX_L_BATCH;
            pre[i] = c[i] = uint256(tpi.leafAsset[k]);
            i += MAX_L_BATCH;
            pre[i] = c[i] = uint256(tpi.leafPublicIn[k]);
            i += MAX_L_BATCH;
            pre[i] = c[i] = uint256(tpi.isDeposit[k]);
        }

        // The commitment to `c`: hashed, not evaluated.
        pre[BATCH_COEFFS] = tpi.digest;

        return _finalize(pre, c, tpi.digest);
    }

    function _finalize(uint256[] memory p, uint256[] memory c, uint256 digest)
        private
        pure
        returns (uint256[3] memory out)
    {
        uint256 z = uint256(keccak256(abi.encode(p))) % SnarkCompression.R;
        out[0] = SnarkCompression.evaluatePolyAt(c, z);
        out[1] = digest;
        out[2] = z;
    }
}
