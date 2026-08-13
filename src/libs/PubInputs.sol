// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { SnarkCompression } from "../SnarkCompression.sol";
import { AuxValidation } from "./AuxValidation.sol";

/// Public-input structs and Fiat-Shamir compression. Layouts must match the
/// circuit-side PolyEval coefficient orders word-for-word.
library PubInputs {
    /// Shielded inputs and outputs of `transact_3x3.circom`. Changing either
    /// requires a new circuit, a new ceremony, and a new verifier.
    uint256 internal constant TRANSACT_IN = 3;
    uint256 internal constant TRANSACT_OUT = 3;

    /// `transact_3x3.circom` public signals: 32 struct words, then
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

    /// Depositor-signed payload, bound via the Permit2 witness. A deposit
    /// occupies exactly one leaf, whose Pedersen commitment `cvDep` the batch
    /// circuit pins to `publicIn` units of `publicAssetId` under blinder `rcv`.
    struct DepositRequest {
        /// Full-width, matching `Transact.chainId`. Both encode to a single ABI
        /// word, so the Permit2 witness preimage is identical either way. The
        /// wider type also makes dirty high bits fail the `!= block.chainid`
        /// gate rather than being masked before it.
        uint256 chainId;
        uint64 publicAssetId;
        uint64 publicIn;
        address payer;
        address recipient;
        bytes32 outCm;
        uint256[2] cvDep;
        uint256 rcv;
    }

    /// Coefficient-vector lengths. Both structs are fully static, so their ABI
    /// calldata block is word-for-word identical to the coefficient vector, on
    /// which the calldata `compress` overloads rely. `PubInputs.t.sol` pins that
    /// equivalence against the `memory` reference paths.
    /// `1 + TRANSACT_IN + TRANSACT_OUT + 3 + 2*TRANSACT_IN + 2*TRANSACT_OUT
    /// + 4 + 2*TRANSACT_OUT = 32` at the 3x3 shape.
    uint256 private constant TRANSACT_CALLDATA_WORDS = 32;
    /// Struct words, then `(clueRx, clueRy, clueBits)` per output, then the
    /// aux digest: `9 + 3*TRANSACT_IN + 8*TRANSACT_OUT = 42`.
    uint256 internal constant TRANSACT_COEFFS = TRANSACT_CALLDATA_WORDS + 3 * TRANSACT_OUT + 1;
    uint256 private constant BATCH_COEFFS = 4 + 6 * MAX_L_BATCH;

    /// Word index of the first clue triple, and of the aux digest.
    uint256 private constant CLUE_BASE = TRANSACT_CALLDATA_WORDS;
    uint256 private constant AUX_DIGEST_SLOT = TRANSACT_COEFFS - 1;

    uint256 private constant MASK_U64 = 0xffffffffffffffff;
    uint256 private constant MASK_U160 = 0x00ffffffffffffffffffffffffffffffffffffffff;

    // ================= calldata fast paths ===================================

    /// `compress(Transact)` read directly from calldata. Words [0..31] are
    /// copied verbatim; [32..41] are derived from `aux`. Avoids the
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
        // a typed member read would have masked off. Word indices follow the
        // 3x3 layout: [7..9] the three uint64 publics, [22] recipient,
        // [24] payer, [25] relayer.
        assembly ("memory-safe") {
            let p := add(d, 0xe0) // [7] publicAssetId, [8] publicIn, [9] publicOut
            mstore(p, and(mload(p), MASK_U64))
            p := add(p, 0x20)
            mstore(p, and(mload(p), MASK_U64))
            p := add(p, 0x20)
            mstore(p, and(mload(p), MASK_U64))
            p := add(d, 0x2c0) // [22] recipient
            mstore(p, and(mload(p), MASK_U160))
            p := add(d, 0x300) // [24] payer, [25] relayer
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

        // Final slot binds the whole encrypted-note payload. The clue fields
        // above are per-output but leave `ephPub` and `ciphertext` unbound, so
        // without this a relayer could keep the clue intact — the proof still
        // verifies and the recipient's FMD scan still flags the note — while
        // corrupting the payload beyond recovery. Recomputed here rather than
        // read from calldata, so it cannot be forged.
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

    /// Pack `Transact` into `TRANSACT_COEFFS = 42` coefficients and derive
    /// `(y, z)`. Written as a cursor walk rather than fixed indices, so the
    /// layout is what the reference asserts. Order matches the
    /// `transact_3x3.circom` PolyEval.
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

    /// Pack `TreeUpdateBatch` into `4 + 6*MAX_L_BATCH = 52` coefficients and
    /// derive `(y, z)`. Order matches `tree_update_batch.circom`.
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
