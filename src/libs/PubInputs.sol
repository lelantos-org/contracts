// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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

    /// `4x6.circom` public signals: 50 struct words, then
    /// `3 * TRANSACT_OUT` clue coefficients and the aux digest, all derived in
    /// `compress`. `outCvDep` is the per-output Pedersen value commitment
    /// anchoring (asset, value) into the leaf; it is forwarded into
    /// `tree_update_batch`.
    struct Transact {
        bytes32 merkleRoot;
        bytes32[TRANSACT_IN] nullifier;
        bytes32[TRANSACT_OUT] outCm;
        uint64 publicAssetId;
        uint64 publicIn;
        uint64 publicOut;
        uint256[2][TRANSACT_IN] inCv;
        uint256[2][TRANSACT_OUT] outCv;
        address recipient;
        uint256 chainId;
        address payer;
        address relayer;
        uint256[2][TRANSACT_OUT] outCvDep;
    }

    /// MAX_L of `tree_update_batch.circom`. The coefficient vector is
    /// `4 + 6*MAX_L_BATCH = 52`; drift breaks the circuit-to-contract binding.
    ///
    /// 8 is the smallest fit at the 4x6 transact shape: `COUNT_BITS` requires a
    /// power of two, and a spend emits `TRANSACT_OUT` = 6 leaves that must fit
    /// one batch. A wider transact shape requires a new `tree_update_batch`
    /// ceremony.
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
    /// A deposit occupies two leaves: the depositor's note, and a note paying
    /// the relayer that flushes it. The circuit's deposit binding is per leaf,
    /// so each is pinned independently — `cvDep` to `publicIn` units under
    /// `rcv`, `feeCvDep` to `feeIn` units under `feeRcv`.
    ///
    /// Paying the relayer in a note keeps its identity and the fee amount off
    /// the event, and makes the fee unstealable: `flushBatch` is
    /// permissionless, so an on-chain amount payable to `msg.sender` could be
    /// claimed by whoever front-runs the assembled batch.
    struct DepositRequest {
        /// Full width, matching `Transact.chainId`, and one ABI word in the
        /// Permit2 witness preimage. Dirty high bits fail the `!= block.chainid`
        /// gate instead of being masked off by a narrower type.
        uint256 chainId;
        uint64 publicAssetId;
        uint64 publicIn;
        address payer;
        address recipient;
        bytes32 outCm;
        uint256[2] cvDep;
        uint256 rcv;
        /// Relayer fee note, in the same asset as the deposit.
        ///
        /// `feeIn` may be zero; a deployment that subsidises deposits still
        /// mints the leaf, so a deposit always occupies two leaves.
        uint64 feeIn;
        bytes32 feeCm;
        uint256[2] feeCvDep;
        uint256 feeRcv;
    }

    /// Leaves one deposit occupies: the depositor's note and the relayer's.
    uint256 internal constant LEAVES_PER_DEPOSIT = 2;

    /// The relayer's leaf as it appears in the escrow digest, and therefore in
    /// every call that must resupply that preimage — `flushBatch` and
    /// `cancelDeposit`, plus the adapters that forward to them.
    ///
    /// Distinct from `DepositRequest`'s fee fields, which are the submitted
    /// form: `feeIn` is narrowed here to `uint48`, the digest's width, enforced
    /// at submit; `feeRcv` is absent, as the blinder is published in the event
    /// and not bound into the digest.
    ///
    /// Fully static, so `abi.encode` of this struct yields the same bytes as
    /// the three fields encoded inline. `MASPDepositTest.test_happy_pullsFundsAndEscrows`
    /// pins that encoding.
    struct FeeNote {
        uint48 feeIn;
        bytes32 feeCm;
        uint256[2] feeCvDep;
    }

    /// A walk of the `Transact` calldata block, in struct order, naming the word
    /// index of each sub-word member that `compress` must re-clean: `merkleRoot`,
    /// the nullifiers and the output commitments precede the three `uint64`
    /// publics; those plus both `cv` arrays precede `recipient`, which is
    /// followed by `chainId`, then `payer` and `relayer`. `outCvDep` closes the
    /// block, which is what `TRANSACT_CALLDATA_WORDS` adds back.
    uint256 private constant W_PUBLIC_ASSET_ID = 1 + TRANSACT_IN + TRANSACT_OUT;
    uint256 private constant W_RECIPIENT = W_PUBLIC_ASSET_ID + 3 + 2 * TRANSACT_IN + 2 * TRANSACT_OUT;
    uint256 private constant W_PAYER = W_RECIPIENT + 2;

    /// Coefficient-vector lengths. Both structs are fully static, so their ABI
    /// calldata block is word-for-word identical to the coefficient vector, on
    /// which the calldata `compress` overloads rely. `PubInputs.t.sol` pins that
    /// equivalence against the `memory` reference paths.
    /// Derived from the shape rather than written out, so every offset built on
    /// it follows `TRANSACT_OUT` instead of being restated per shape: `50` at
    /// the 4x6 shape. Expressed as the tail of the walk in `W_*` below, so the
    /// struct layout is stated once.
    uint256 private constant TRANSACT_CALLDATA_WORDS = W_RECIPIENT + 4 + 2 * TRANSACT_OUT;
    /// Struct words, then `(clueRx, clueRy, clueBits)` per output, then the
    /// aux digest: `9 + 3*TRANSACT_IN + 8*TRANSACT_OUT = 69`.
    uint256 internal constant TRANSACT_COEFFS = TRANSACT_CALLDATA_WORDS + 3 * TRANSACT_OUT + 1;
    uint256 private constant BATCH_COEFFS = 4 + 6 * MAX_L_BATCH;

    /// Word index of the first clue triple, and of the aux digest.
    uint256 private constant CLUE_BASE = TRANSACT_CALLDATA_WORDS;
    uint256 private constant AUX_DIGEST_SLOT = TRANSACT_COEFFS - 1;

    uint256 private constant MASK_U64 = 0xffffffffffffffff;
    uint256 private constant MASK_U160 = 0x00ffffffffffffffffffffffffffffffffffffffff;

    // ================= calldata fast paths ===================================

    /// `compress(Transact)` read directly from calldata. The struct's words are
    /// copied verbatim; the trailing clue triples and aux digest are derived
    /// from `aux`. Avoids the
    /// calldata-to-memory ABI decode of the struct and the `abi.encode` copy
    /// performed by `_finalize`.
    function compress(Transact calldata pi, AuxValidation.Output[TRANSACT_OUT] calldata aux)
        internal
        pure
        returns (uint256[2] memory)
    {
        // Lay out `abi.encode(uint256[] memory)` in place: offset word, length
        // word, then the coefficients. Hashing that region reproduces the
        // reference preimage without a second copy.
        uint256 n = TRANSACT_COEFFS;
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

        // Re-clean sub-word members: raw calldata may carry dirty high bits that
        // a typed member read would have masked off. The word indices are the
        // shape-derived constants above, so they follow `TRANSACT_OUT`.
        // Folded at compile time. Computed here rather than inside the block
        // because inline assembly accepts only literal constants, not the
        // derived ones above.
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
        // the clue — and therefore the proof and the recipient's FMD scan —
        // intact. Recomputed here, never read from calldata.
        uint256 digest = auxDigest(aux);
        uint256 digestSlot = d + AUX_DIGEST_SLOT * 0x20;
        assembly ("memory-safe") {
            mstore(digestSlot, digest)
        }
        return _finalizeRaw(head, n);
    }

    /// `keccak256(abi.encode(aux)) mod R` over the aux array encoded as a
    /// dynamic `tuple[]`, so the length joins the preimage and arrays of
    /// different arity cannot collide. Mirrors the off-chain `auxDigest`.
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

    /// `compress(TreeUpdateBatch)` read directly from calldata. The entire
    /// coefficient vector is a single `calldatacopy`.
    function compress(TreeUpdateBatch calldata tpi) internal pure returns (uint256[2] memory) {
        uint256 n = BATCH_COEFFS;
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
        return _finalizeRaw(head, n);
    }

    /// `head` points at an in-memory `abi.encode(uint256[] memory)` image:
    /// `0x20 || n || coefficients`. Hashed for `z`, Horner-evaluated for `y`.
    function _finalizeRaw(uint256 head, uint256 n) private pure returns (uint256[2] memory out) {
        bytes32 h;
        assembly ("memory-safe") {
            h := keccak256(head, add(0x40, mul(n, 0x20)))
        }
        uint256 z = uint256(h) % SnarkCompression.R;
        out[0] = SnarkCompression.evaluatePolyAtRaw(head + 0x40, n, z);
        out[1] = z;
    }

    // ================= memory reference paths ================================
    //
    // Straight-line specification of the coefficient layout, implemented
    // independently of the calldata fast paths above. Not used on-chain;
    // `PubInputs.t.sol` fuzzes `compressRef == compress` to detect drift.

    /// Packs `Transact` into `TRANSACT_COEFFS = 69` coefficients and derives
    /// `(y, z)`. A cursor walk, so the layout itself is what the reference
    /// asserts. Order matches the `4x6.circom` PolyEval.
    function compressRef(Transact memory pi, AuxValidation.Output[TRANSACT_OUT] calldata aux)
        internal
        pure
        returns (uint256[2] memory)
    {
        uint256[] memory s = new uint256[](TRANSACT_COEFFS);
        uint256 i = 0;
        s[i++] = uint256(pi.merkleRoot);
        for (uint256 k; k < TRANSACT_IN; ++k) {
            s[i++] = uint256(pi.nullifier[k]);
        }
        for (uint256 k; k < TRANSACT_OUT; ++k) {
            s[i++] = uint256(pi.outCm[k]);
        }
        s[i++] = uint256(pi.publicAssetId);
        s[i++] = uint256(pi.publicIn);
        s[i++] = uint256(pi.publicOut);
        for (uint256 k; k < TRANSACT_IN; ++k) {
            s[i++] = pi.inCv[k][0];
            s[i++] = pi.inCv[k][1];
        }
        for (uint256 k; k < TRANSACT_OUT; ++k) {
            s[i++] = pi.outCv[k][0];
            s[i++] = pi.outCv[k][1];
        }
        s[i++] = uint256(uint160(pi.recipient));
        s[i++] = pi.chainId;
        s[i++] = uint256(uint160(pi.payer));
        s[i++] = uint256(uint160(pi.relayer));
        for (uint256 k; k < TRANSACT_OUT; ++k) {
            s[i++] = pi.outCvDep[k][0];
            s[i++] = pi.outCvDep[k][1];
        }
        for (uint256 k; k < TRANSACT_OUT; ++k) {
            s[i++] = aux[k].clueRx;
            s[i++] = aux[k].clueRy;
            s[i++] = uint256(uint16(bytes2(aux[k].ciphertext[0:2])));
        }
        s[i++] = auxDigest(aux);
        return _finalize(s);
    }

    /// Packs `TreeUpdateBatch` into `4 + 6*MAX_L_BATCH = 28` coefficients and
    /// derives `(y, z)`. Order matches `tree_update_batch.circom`.
    function compressRef(TreeUpdateBatch memory tpi) internal pure returns (uint256[2] memory) {
        uint256 n = 4 + 6 * MAX_L_BATCH;
        // Allocated uninitialized; every slot [0..n-1] is written below.
        uint256[] memory s;
        assembly ("memory-safe") {
            s := mload(0x40)
            mstore(s, n)
            mstore(0x40, add(s, add(0x20, mul(n, 0x20))))
        }
        s[0] = uint256(tpi.oldRoot);
        s[1] = uint256(tpi.newRoot);
        s[2] = uint256(tpi.startIndex);
        s[3] = uint256(tpi.actualCount);
        uint256 off = 4;
        for (uint256 k = 0; k < MAX_L_BATCH;) {
            s[off + k] = uint256(tpi.cms[k]);
            unchecked {
                ++k;
            }
        }
        off += MAX_L_BATCH;
        for (uint256 k = 0; k < MAX_L_BATCH;) {
            s[off + 2 * k + 0] = tpi.cvDeps[k][0];
            s[off + 2 * k + 1] = tpi.cvDeps[k][1];
            unchecked {
                ++k;
            }
        }
        off += 2 * MAX_L_BATCH;
        for (uint256 k = 0; k < MAX_L_BATCH;) {
            s[off + k] = uint256(tpi.leafAsset[k]);
            unchecked {
                ++k;
            }
        }
        off += MAX_L_BATCH;
        for (uint256 k = 0; k < MAX_L_BATCH;) {
            s[off + k] = uint256(tpi.leafPublicIn[k]);
            unchecked {
                ++k;
            }
        }
        off += MAX_L_BATCH;
        for (uint256 k = 0; k < MAX_L_BATCH;) {
            s[off + k] = uint256(tpi.isDeposit[k]);
            unchecked {
                ++k;
            }
        }
        return _finalize(s);
    }

    function _finalize(uint256[] memory s) private pure returns (uint256[2] memory out) {
        uint256 z = uint256(keccak256(abi.encode(s))) % SnarkCompression.R;
        out[0] = SnarkCompression.evaluatePolyAt(s, z);
        out[1] = z;
    }
}
