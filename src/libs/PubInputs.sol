// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { SnarkCompression } from "../SnarkCompression.sol";
import { AuxValidation } from "./AuxValidation.sol";

/// SNARK PI structs + Fiat-Shamir compression. Layouts MUST match the
/// circuit-side PolyEval coefficient orders byte-for-byte.
library PubInputs {
    /// transact_2x2.circom public signals (24 base + 6 clue PIs via `compress`).
    /// `outCvDep` is the per-output Pedersen value commitment anchoring
    /// (asset, value) into the leaf; forwarded into tree_update_batch.
    struct Transact {
        bytes32 merkleRoot;
        bytes32[2] nullifier;
        bytes32[2] outCm;
        uint64 publicAssetId;
        uint64 publicIn;
        uint64 publicOut;
        uint256[2][2] inCv;
        uint256[2][2] outCv;
        address recipient;
        uint256 chainId;
        address payer;
        address relayer;
        uint256[2][2] outCvDep;
    }

    /// MAX_N of `tree_update_batch.circom`. Coefficient vector is
    /// `4 + 9*MAX_N_BATCH = 76`. Drift breaks circuit ↔ contract binding.
    uint256 internal constant MAX_N_BATCH = 8;

    /// tree_update_batch.circom PIs. Layout:
    ///   oldRoot, newRoot, startIndex, actualCount,
    ///   cms[0..2*MAX_N-1], cvDeps[0..2*MAX_N-1],
    ///   pairAsset[0..MAX_N-1], pairPublicIn[0..MAX_N-1], isDeposit[0..MAX_N-1].
    /// `actualCount ∈ [1, MAX_N_BATCH]`; slots beyond `actualCount` MUST be
    /// zero (in-circuit + on-chain).
    struct TreeUpdateBatch {
        bytes32 oldRoot;
        bytes32 newRoot;
        uint64 startIndex;
        uint64 actualCount;
        bytes32[2 * MAX_N_BATCH] cms;
        uint256[2][2 * MAX_N_BATCH] cvDeps;
        uint64[MAX_N_BATCH] pairAsset;
        uint64[MAX_N_BATCH] pairPublicIn;
        uint8[MAX_N_BATCH] isDeposit;
    }

    /// Depositor-signed payload (bound via Permit2 witness). `cvDep*` are
    /// per-output Pedersen commitments. `rcvTotal = rcv_dep_0 + rcv_dep_1`.
    struct DepositIntent {
        /// Full-width, matching `Transact.chainId`. Both encode to a single
        /// ABI word, so the Permit2 witness preimage is identical either way.
        /// The wider type also causes dirty high bits to fail the
        /// `!= block.chainid` gate rather than being masked before it.
        uint256 chainId;
        uint64 publicAssetId;
        uint64 publicIn;
        address payer;
        address recipient;
        bytes32[2] outCm;
        uint256[2] cvDep0;
        uint256[2] cvDep1;
        uint256 rcvTotal;
    }

    /// Coefficient-vector lengths. Both structs are fully static, so their ABI
    /// calldata block is word-for-word identical to the coefficient vector,
    /// which the calldata `compress` overloads rely on. `PubInputs.t.sol` pins
    /// that equivalence against the `memory` reference paths.
    uint256 private constant TRANSACT_COEFFS = 30;
    uint256 private constant TRANSACT_CALLDATA_WORDS = 24;
    uint256 private constant BATCH_COEFFS = 4 + 9 * MAX_N_BATCH;

    uint256 private constant MASK_U64 = 0xffffffffffffffff;
    uint256 private constant MASK_U160 = 0x00ffffffffffffffffffffffffffffffffffffffff;

    // ================= calldata fast paths (hot) =============================

    /// `compress(Transact)` read directly from calldata. Words [0..23] are
    /// copied verbatim; [24..29] are derived from `aux`. Avoids the
    /// calldata-to-memory ABI decode of the struct and the `abi.encode` copy
    /// performed by `_finalize`.
    function compress(Transact calldata pi, AuxValidation.Output[2] calldata aux)
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

        // Re-clean sub-word members: raw calldata may carry dirty high bits
        // that a typed member read would have masked off.
        assembly ("memory-safe") {
            let p := add(d, 0xa0) // [5] publicAssetId, [6] publicIn, [7] publicOut
            mstore(p, and(mload(p), MASK_U64))
            p := add(p, 0x20)
            mstore(p, and(mload(p), MASK_U64))
            p := add(p, 0x20)
            mstore(p, and(mload(p), MASK_U64))
            p := add(d, 0x200) // [16] recipient
            mstore(p, and(mload(p), MASK_U160))
            p := add(d, 0x240) // [18] payer, [19] relayer
            mstore(p, and(mload(p), MASK_U160))
            p := add(p, 0x20)
            mstore(p, and(mload(p), MASK_U160))
        }

        for (uint256 j; j < 2;) {
            AuxValidation.Output calldata o = aux[j];
            uint256 rx = o.clueRx;
            uint256 ry = o.clueRy;
            uint256 clueBits = uint256(uint16(bytes2(o.ciphertext[0:2])));
            uint256 slot = d + (24 + 3 * j) * 0x20;
            assembly ("memory-safe") {
                mstore(slot, rx)
                mstore(add(slot, 0x20), ry)
                mstore(add(slot, 0x40), clueBits)
            }
            unchecked {
                ++j;
            }
        }
        return _finalizeRaw(head, n);
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
        // [4 + 6*MAX_N .. 4 + 8*MAX_N) = pairAsset ++ pairPublicIn (uint64),
        // then [4 + 8*MAX_N .. n) = isDeposit (uint8).
        uint256 u64Start = d + (4 + 6 * MAX_N_BATCH) * 0x20;
        uint256 u64End = d + (4 + 8 * MAX_N_BATCH) * 0x20;
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
    /// `0x20 || n || coefficients`. Hash it for `z`, Horner-eval for `y`.
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

    /// Pack `Transact` into 30 coeffs and derive `(y, z)`. Coeffs [20..23] =
    /// out_cv_dep, [24..29] = (clueRx, clueRy, clueBits) per output. Order
    /// matches `2x2.circom` PolyEval.
    function compressRef(Transact memory pi, AuxValidation.Output[2] calldata aux)
        internal
        pure
        returns (uint256[2] memory)
    {
        // Allocate uninitialized — every slot [0..29] is written below.
        uint256[] memory s;
        assembly ("memory-safe") {
            s := mload(0x40)
            mstore(s, 30)
            mstore(0x40, add(s, 0x3e0)) // 32 (length) + 30*32 = 0x3e0
        }
        s[0] = uint256(pi.merkleRoot);
        s[1] = uint256(pi.nullifier[0]);
        s[2] = uint256(pi.nullifier[1]);
        s[3] = uint256(pi.outCm[0]);
        s[4] = uint256(pi.outCm[1]);
        s[5] = uint256(pi.publicAssetId);
        s[6] = uint256(pi.publicIn);
        s[7] = uint256(pi.publicOut);
        s[8] = pi.inCv[0][0];
        s[9] = pi.inCv[0][1];
        s[10] = pi.inCv[1][0];
        s[11] = pi.inCv[1][1];
        s[12] = pi.outCv[0][0];
        s[13] = pi.outCv[0][1];
        s[14] = pi.outCv[1][0];
        s[15] = pi.outCv[1][1];
        s[16] = uint256(uint160(pi.recipient));
        s[17] = pi.chainId;
        s[18] = uint256(uint160(pi.payer));
        s[19] = uint256(uint160(pi.relayer));
        s[20] = pi.outCvDep[0][0];
        s[21] = pi.outCvDep[0][1];
        s[22] = pi.outCvDep[1][0];
        s[23] = pi.outCvDep[1][1];
        for (uint256 j; j < 2;) {
            uint256 base = 24 + 3 * j;
            s[base + 0] = aux[j].clueRx;
            s[base + 1] = aux[j].clueRy;
            s[base + 2] = uint256(uint16(bytes2(aux[j].ciphertext[0:2])));
            unchecked {
                ++j;
            }
        }
        return _finalize(s);
    }

    /// Pack `TreeUpdateBatch` into `4 + 9*MAX_N_BATCH = 76` coeffs and
    /// derive `(y, z)`. Order matches `tree_update_batch.circom`.
    function compressRef(TreeUpdateBatch memory tpi) internal pure returns (uint256[2] memory) {
        uint256 n = 4 + 9 * MAX_N_BATCH;
        // Allocate uninitialized — every slot [0..n-1] is written below.
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
        for (uint256 i = 0; i < 2 * MAX_N_BATCH;) {
            s[off + i] = uint256(tpi.cms[i]);
            unchecked {
                ++i;
            }
        }
        off += 2 * MAX_N_BATCH;
        for (uint256 i = 0; i < 2 * MAX_N_BATCH;) {
            s[off + 2 * i + 0] = tpi.cvDeps[i][0];
            s[off + 2 * i + 1] = tpi.cvDeps[i][1];
            unchecked {
                ++i;
            }
        }
        off += 4 * MAX_N_BATCH;
        for (uint256 i = 0; i < MAX_N_BATCH;) {
            s[off + i] = uint256(tpi.pairAsset[i]);
            unchecked {
                ++i;
            }
        }
        off += MAX_N_BATCH;
        for (uint256 i = 0; i < MAX_N_BATCH;) {
            s[off + i] = uint256(tpi.pairPublicIn[i]);
            unchecked {
                ++i;
            }
        }
        off += MAX_N_BATCH;
        for (uint256 i = 0; i < MAX_N_BATCH;) {
            s[off + i] = uint256(tpi.isDeposit[i]);
            unchecked {
                ++i;
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
