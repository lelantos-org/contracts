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

    /// `4x6.circom` public signals: 50 struct words, then `3 * TRANSACT_OUT`
    /// clue coefficients and the aux digest, all derived in `compress`.
    /// `outCvDep` is the per-output Pedersen value commitment anchoring
    /// (asset, value) into the leaf, forwarded into `tree_update_batch`.
    struct Transact {
        bytes32 merkleRoot;
        bytes32[TRANSACT_IN] nullifier;
        bytes32[TRANSACT_OUT] outCm;
        uint64 publicAssetId;
        uint64 publicIn;
        uint64 publicOut;
        uint256[2][TRANSACT_IN] inCv;
        uint256[2][TRANSACT_OUT] outCv;
        uint256[2][TRANSACT_OUT] outCvDep;
        // Constrained nowhere in `4x6.circom`, so hashed into `z` and never
        // evaluated into `y`. They sit AFTER every pinned member so the
        // coefficients are the calldata block's leading `TRANSACT_COEFFS`
        // words — one Horner span rather than two runs joined by hand.
        address recipient;
        uint256 chainId;
        address payer;
        address relayer;
    }

    /// MAX_L of `tree_update_batch.circom`. The challenge preimage and the
    /// coefficient vector are both `4 + 6*MAX_L_BATCH = 52` words; drift in
    /// either breaks the circuit-to-contract binding.
    ///
    /// 8 is the smallest fit at the 4x6 transact shape: `COUNT_BITS` requires a
    /// power of two and a spend emits `TRANSACT_OUT` = 6 leaves that must fit
    /// one batch. A wider transact shape requires a new ceremony.
    uint256 internal constant MAX_L_BATCH = 8;

    /// `tree_update_batch.circom` public inputs. Layout:
    ///   oldRoot, newRoot, startIndex, actualCount,
    ///   cms[0..MAX_L-1], cvDeps[0..MAX_L-1],
    ///   leafAsset[0..MAX_L-1], leafPublicIn[0..MAX_L-1], isDeposit[0..MAX_L-1].
    /// Every array is indexed by leaf, not by pair: `actualCount` is a leaf
    /// count in `[1, MAX_L_BATCH]`, so a batch may commit an odd number of
    /// leaves. Slots beyond `actualCount` must be zero, both in-circuit and
    /// on-chain.
    struct TreeUpdateBatch {
        bytes32 oldRoot;
        bytes32 newRoot;
        uint64 startIndex;
        uint64 actualCount;
        bytes32[MAX_L_BATCH] cms;
        uint256[2][MAX_L_BATCH] cvDeps;
        uint64[MAX_L_BATCH] leafAsset;
        uint64[MAX_L_BATCH] leafPublicIn;
        uint8[MAX_L_BATCH] isDeposit;
    }

    /// Depositor-signed payload, bound via the Permit2 witness.
    ///
    /// A deposit occupies two leaves: the depositor's note and a note paying the
    /// relayer that flushes it. The circuit's deposit binding is per leaf, so
    /// each is pinned independently — `cvDep` to `publicIn` units under `rcv`,
    /// `feeCvDep` to `feeIn` units under `feeRcv`.
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
        bytes32 outCm;
        uint256[2] cvDep;
        uint256 rcv;
        /// Relayer fee note, in the same asset as the deposit. `feeIn` may be
        /// zero; the leaf is minted either way, so a deposit always occupies
        /// two leaves.
        uint64 feeIn;
        bytes32 feeCm;
        uint256[2] feeCvDep;
        uint256 feeRcv;
    }

    /// Leaves one deposit occupies: the depositor's note and the relayer's.
    uint256 internal constant LEAVES_PER_DEPOSIT = 2;

    /// The relayer's leaf as it appears in the escrow digest, and so in every
    /// call that resupplies that preimage: `flushBatch`, `cancelDeposit`, and
    /// the adapters forwarding to them.
    ///
    /// Distinct from `DepositRequest`'s fee fields, the submitted form: `feeIn`
    /// is narrowed here to `uint48`, the digest's width, enforced at submit, and
    /// `feeRcv` is absent, as the blinder is published in the event rather than
    /// bound into the digest.
    ///
    /// Fully static, so `abi.encode` of this struct yields the same bytes as the
    /// three fields encoded inline;
    /// `MASPDepositTest.test_happy_pullsFundsAndEscrows` pins that encoding.
    struct FeeNote {
        uint48 feeIn;
        bytes32 feeCm;
        uint256[2] feeCvDep;
    }

    /// A walk of the `Transact` calldata block, in struct order, naming the
    /// word index of each sub-word member that `compress` must re-clean:
    /// `merkleRoot`, the nullifiers and the output commitments precede the three
    /// `uint64` publics; those plus both `cv` arrays precede `recipient`,
    /// followed by `outCvDep`, and only then `recipient`, `chainId`, `payer` and
    /// `relayer` — the four unpinned words `TRANSACT_CALLDATA_WORDS` adds back,
    /// placed last so the coefficients are a leading prefix.
    uint256 private constant W_PUBLIC_ASSET_ID = 1 + TRANSACT_IN + TRANSACT_OUT;
    uint256 private constant W_RECIPIENT = W_PUBLIC_ASSET_ID + 3 + 2 * TRANSACT_IN + 4 * TRANSACT_OUT;
    uint256 private constant W_PAYER = W_RECIPIENT + 2;

    /// Both structs are fully static, so their ABI calldata block is
    /// word-for-word identical to the challenge preimage, on which the calldata
    /// `compress` overloads rely; `PubInputs.t.sol` pins that equivalence
    /// against the `memory` reference paths. Derived from the shape (`50` at the
    /// 4x6 shape) as the tail of the `W_*` walk, so the struct layout is stated
    /// once and every offset follows `TRANSACT_OUT`.
    uint256 private constant TRANSACT_CALLDATA_WORDS = W_RECIPIENT + 4;

    /// Words hashed to produce `z`: the struct, then `(clueRx, clueRy,
    /// clueBits)` per output, then the aux digest —
    /// `9 + 3*TRANSACT_IN + 8*TRANSACT_OUT = 69`.
    ///
    /// **Every one of these binds**, and binds by a mechanism that needs no
    /// circuit constraint: alter any of them and `z` moves, so `y` moves, so the
    /// proof fails. That covers the recipient, chain id, payer, relayer, the FMD
    /// clues and the encrypted-payload digest against a tampering relayer.
    uint256 internal constant TRANSACT_CHALLENGE_WORDS = TRANSACT_CALLDATA_WORDS + 3 * TRANSACT_OUT + 1;

    /// Words the polynomial is evaluated over: `4 + 3*TRANSACT_IN +
    /// 5*TRANSACT_OUT = 46`. A strict subset of the challenge preimage — the
    /// four address words in the middle of the struct, the clue triples and the
    /// aux digest are hashed but not evaluated.
    ///
    /// **Not an optimisation.** `y = Σ c_k z^k` is affine in each coefficient
    /// and `z` is derived from calldata the prover authored, so the prover reads
    /// `z` before choosing its witness. One coefficient the circuit does not
    /// constrain is then one linear equation in one unknown: solve it and any
    /// calldata whatsoever verifies against a proof of some other transaction.
    /// Schwartz-Zippel does not rescue this — it needs the vector fixed before
    /// the challenge, and here the challenge comes first.
    ///
    /// `recipient`, `chainId`, `payer`, `relayer`, the clue fields and the aux
    /// digest are constrained nowhere in `4x6.circom`; they were 23 of the
    /// former 69 coefficients and so were 23 such unknowns. They are excluded
    /// here and bound through `z` instead, which costs nothing and needs no
    /// constraint. The circuit's `TransactCompressN` carries the same 46.
    ///
    /// Adding a coefficient means naming the circuit constraint that pins it.
    /// If there is none, hash it into the challenge instead of evaluating it.
    /// Equal to `W_RECIPIENT` by construction, and written that way: the
    /// coefficients end exactly where the first unpinned member begins, which is
    /// the invariant the member order exists to create. Subtracting the tail from
    /// `TRANSACT_CHALLENGE_WORDS` would restate it in a form that has to be kept
    /// in lockstep by hand.
    uint256 internal constant TRANSACT_COEFFS = W_RECIPIENT;
    /// Batch challenge preimage: the whole `4 + 6*MAX_L_BATCH = 52` word block.
    uint256 private constant BATCH_CHALLENGE_WORDS = 4 + 6 * MAX_L_BATCH;

    /// Words the batch polynomial is evaluated over: all `4 + 6*MAX_L_BATCH =
    /// 52` of them. Unlike the transact shape, the batch coefficient vector and
    /// its challenge preimage are the same list.
    ///
    /// `TRANSACT_COEFFS` excludes its trailing words because they are not
    /// signals of `4x6.circom` at all — there is no witness copy of them, so
    /// there is nothing for a prover to disagree with. That reasoning does NOT
    /// carry over here: `leafAsset`, `leafPublicIn` and `isDeposit` ARE signals
    /// of `tree_update_batch.circom` and drive its deposit binding. Hashing a
    /// signal into `z` binds nothing, because the prover reads `z` first and may
    /// hand the verifier a witness that disagrees with the calldata it was
    /// hashed from. Demoting them here would let a `flushBatch` caller escrow
    /// one unit and commit a leaf holding `2**63`.
    ///
    /// So all three are evaluated, and the circuit pins them. The gated deposit
    /// binding pins `leafPublicIn[k]` and `leafAsset[k]` against `cvDep[k]`
    /// under discrete-log hardness — but it degenerates on its own, since
    /// `ValueTimesGen(0, gen)` is the curve identity for every `gen`, leaving
    /// `leafAsset[k]` on a zero-value leaf with only a 64-bit range check. A
    /// range check is not a pin, and four such leaves would be 4 x 64 = 256 bits
    /// of free dial against a 254-bit modulus.
    ///
    /// `tree_update_batch.circom` step 7a closes that per slot, with no
    /// reference to a neighbour: on an active deposit leaf `leafAsset` is 0
    /// exactly when `leafPublicIn` is 0, so a worthless leaf's asset is pinned to
    /// a constant and a valued one's is pinned by the binding. That is what makes
    /// every coefficient here pinned; keep it and this constant in step.
    /// `_drainDeposit` mirrors it on the calldata side.
    ///
    /// Adding a coefficient means naming the circuit constraint that pins it.
    /// If there is none, hash it into the challenge instead of evaluating it.
    uint256 private constant BATCH_COEFFS = BATCH_CHALLENGE_WORDS;

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
    /// Two spans, not one: all `TRANSACT_CHALLENGE_WORDS` are hashed into `z`,
    /// and the `TRANSACT_COEFFS` pinned ones are evaluated into `y`. See the
    /// constants above for why the difference is a soundness requirement.
    function compress(Transact calldata pi, AuxValidation.Output[TRANSACT_OUT] calldata aux)
        internal
        pure
        returns (uint256[2] memory)
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
            // publicAssetId, publicIn, publicOut
            let p := pAsset
            mstore(p, and(mload(p), MASK_U64))
            p := add(p, 0x20)
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
        uint256 digest = auxDigest(aux);
        uint256 digestSlot = d + AUX_DIGEST_SLOT * 0x20;
        assembly ("memory-safe") {
            mstore(digestSlot, digest)
        }
        return _finalizeRaw(head, TRANSACT_CHALLENGE_WORDS, TRANSACT_COEFFS);
    }

    /// `keccak256(abi.encode(aux)) mod R` over the aux array encoded as a
    /// dynamic `tuple[]`, so the length joins the preimage and arrays of
    /// differing arity cannot collide. Mirrors the off-chain `auxDigest`.
    function auxDigest(AuxValidation.Output[TRANSACT_OUT] calldata aux) internal pure returns (uint256) {
        AuxValidation.Output[] memory dyn = new AuxValidation.Output[](TRANSACT_OUT);
        for (uint256 j; j < TRANSACT_OUT;) {
            dyn[j] = aux[j];
            unchecked {
                ++j;
            }
        }
        return uint256(keccak256(abi.encode(dyn))) % SnarkCompression.R;
    }

    /// `compress(TreeUpdateBatch)` read directly from calldata. The whole
    /// challenge preimage is a single `calldatacopy`.
    ///
    /// One span: all `BATCH_CHALLENGE_WORDS` are hashed into `z` and all
    /// `BATCH_COEFFS` are evaluated into `y`, and for this shape the two counts
    /// are equal. The `nCoeffs` argument is still passed explicitly rather than
    /// inferred from `n`, so demoting a word later is a one-line change here
    /// that has to be argued at the constant. See `BATCH_COEFFS` for why no word
    /// is demoted today.
    function compress(TreeUpdateBatch calldata tpi) internal pure returns (uint256[2] memory) {
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
        // [4 + 3*MAX_L .. 4 + 5*MAX_L) is leafAsset ++ leafPublicIn (uint64);
        // [4 + 5*MAX_L .. n) is isDeposit (uint8).
        uint256 u64Start = d + (4 + 3 * MAX_L_BATCH) * 0x20;
        uint256 u64End = d + (4 + 5 * MAX_L_BATCH) * 0x20;
        uint256 u8End = d + n * 0x20;
        assembly ("memory-safe") {
            // [2] startIndex, [3] actualCount
            let p := add(d, 0x40)
            mstore(p, and(mload(p), MASK_U64))
            p := add(p, 0x20)
            mstore(p, and(mload(p), MASK_U64))
            for { p := u64Start } lt(p, u64End) { p := add(p, 0x20) } { mstore(p, and(mload(p), MASK_U64)) }
            for { } lt(p, u8End) { p := add(p, 0x20) } { mstore(p, and(mload(p), 0xff)) }
        }
        return _finalizeRaw(head, n, BATCH_COEFFS);
    }

    /// `head` points at an in-memory `abi.encode(uint256[] memory)` image:
    /// `0x20 || n || words`. All `n` words are hashed for `z`; the first
    /// `nCoeffs` are Horner-evaluated for `y`.
    ///
    /// Serves both shapes. Each one's coefficients are the leading `nCoeffs`
    /// words of its preimage — that is what the member order of `Transact` and
    /// the slot order of `TreeUpdateBatch` are arranged to give — so one Horner
    /// span suffices and `nCoeffs` is the only thing that differs.
    function _finalizeRaw(uint256 head, uint256 n, uint256 nCoeffs) private pure returns (uint256[2] memory out) {
        bytes32 h;
        assembly ("memory-safe") {
            h := keccak256(head, add(0x40, mul(n, 0x20)))
        }
        uint256 z = uint256(h) % SnarkCompression.R;
        out[0] = SnarkCompression.evaluatePolyAtRaw(head + 0x40, nCoeffs, z);
        out[1] = z;
    }

    // ================= memory reference paths ================================
    //
    // Straight-line specification of the coefficient layout, implemented
    // independently of the calldata fast paths above. Not used on-chain;
    // `PubInputs.t.sol` fuzzes `compressRef == compress` for drift.

    /// Packs `Transact` into the `TRANSACT_CHALLENGE_WORDS = 69` challenge
    /// preimage and the `TRANSACT_COEFFS = 46` coefficient vector, and derives
    /// `(y, z)`. Two cursor walks, so both layouts are what the reference
    /// asserts. The coefficient order matches `4x6.circom`'s
    /// `TransactCompressN`; the preimage order matches the calldata block.
    ///
    /// Written as two walks rather than one walk plus a filter so that the
    /// question "is this word a coefficient?" is answered by where it is
    /// written, not by an index computation a reader has to re-derive.
    function compressRef(Transact memory pi, AuxValidation.Output[TRANSACT_OUT] calldata aux)
        internal
        pure
        returns (uint256[2] memory)
    {
        uint256[] memory pre = new uint256[](TRANSACT_CHALLENGE_WORDS);
        uint256[] memory c = new uint256[](TRANSACT_COEFFS);
        uint256 i = 0;
        uint256 j = 0;

        // Pinned by the circuit, so hashed and evaluated both.
        pre[i++] = c[j++] = uint256(pi.merkleRoot);
        for (uint256 k; k < TRANSACT_IN; ++k) {
            pre[i++] = c[j++] = uint256(pi.nullifier[k]);
        }
        for (uint256 k; k < TRANSACT_OUT; ++k) {
            pre[i++] = c[j++] = uint256(pi.outCm[k]);
        }
        pre[i++] = c[j++] = uint256(pi.publicAssetId);
        pre[i++] = c[j++] = uint256(pi.publicIn);
        pre[i++] = c[j++] = uint256(pi.publicOut);
        for (uint256 k; k < TRANSACT_IN; ++k) {
            pre[i++] = c[j++] = pi.inCv[k][0];
            pre[i++] = c[j++] = pi.inCv[k][1];
        }
        for (uint256 k; k < TRANSACT_OUT; ++k) {
            pre[i++] = c[j++] = pi.outCv[k][0];
            pre[i++] = c[j++] = pi.outCv[k][1];
        }

        // Pinned: `outCvDep` is `ValueCommit`-bound per output. Last of them,
        // so `c` is now complete and `pre` and `c` have agreed word for word.
        for (uint256 k; k < TRANSACT_OUT; ++k) {
            pre[i++] = c[j++] = pi.outCvDep[k][0];
            pre[i++] = c[j++] = pi.outCvDep[k][1];
        }

        // Everything from here is constrained nowhere in the circuit: hashed
        // into `z` only. As coefficients these were the free variables an
        // arbitrary `y` is solved for; see `TRANSACT_COEFFS`.
        pre[i++] = uint256(uint160(pi.recipient));
        pre[i++] = pi.chainId;
        pre[i++] = uint256(uint160(pi.payer));
        pre[i++] = uint256(uint160(pi.relayer));

        // The FMD clues and the payload digest.
        for (uint256 k; k < TRANSACT_OUT; ++k) {
            pre[i++] = aux[k].clueRx;
            pre[i++] = aux[k].clueRy;
            pre[i++] = uint256(uint16(bytes2(aux[k].ciphertext[0:2])));
        }
        pre[i++] = auxDigest(aux);

        return _finalize(pre, c);
    }

    /// Packs `TreeUpdateBatch` into its `BATCH_COEFFS = 52` word vector and
    /// derives `(y, z)`. The order matches `tree_update_batch.circom`'s
    /// `BatchCompress` and the calldata block alike.
    ///
    /// One array, unlike the transact path. There the preimage and the
    /// coefficients are built as two walks so that "is this word a
    /// coefficient?" is answered per line by which array it is written to;
    /// here every word is both, so a second array would be a copy of the first
    /// and would document nothing. A future demotion reintroduces the second
    /// walk at that point, which is also when the distinction becomes real.
    function compressRef(TreeUpdateBatch memory tpi) internal pure returns (uint256[2] memory) {
        uint256[] memory c = new uint256[](BATCH_COEFFS);

        c[0] = uint256(tpi.oldRoot);
        c[1] = uint256(tpi.newRoot);
        c[2] = uint256(tpi.startIndex);
        c[3] = uint256(tpi.actualCount);
        uint256 co = 4;
        for (uint256 k = 0; k < MAX_L_BATCH;) {
            c[co + k] = uint256(tpi.cms[k]);
            unchecked {
                ++k;
            }
        }
        co += MAX_L_BATCH;
        for (uint256 k = 0; k < MAX_L_BATCH;) {
            c[co + 2 * k + 0] = tpi.cvDeps[k][0];
            c[co + 2 * k + 1] = tpi.cvDeps[k][1];
            unchecked {
                ++k;
            }
        }
        co += 2 * MAX_L_BATCH;
        for (uint256 k = 0; k < MAX_L_BATCH;) {
            c[co + k] = uint256(tpi.leafAsset[k]);
            unchecked {
                ++k;
            }
        }
        co += MAX_L_BATCH;
        for (uint256 k = 0; k < MAX_L_BATCH;) {
            c[co + k] = uint256(tpi.leafPublicIn[k]);
            unchecked {
                ++k;
            }
        }
        co += MAX_L_BATCH;
        for (uint256 k = 0; k < MAX_L_BATCH;) {
            c[co + k] = uint256(tpi.isDeposit[k]);
            unchecked {
                ++k;
            }
        }

        return _finalize(c, c);
    }

    function _finalize(uint256[] memory p, uint256[] memory c) private pure returns (uint256[2] memory out) {
        uint256 z = uint256(keccak256(abi.encode(p))) % SnarkCompression.R;
        out[0] = SnarkCompression.evaluatePolyAt(c, z);
        out[1] = z;
    }
}
