// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { BabyJubJub } from "../BabyJubJub.sol";

/// Validation + struct for per-output FMD payloads. `Output` is opaque
/// beyond length bounds, clue-bits prefix, and Baby-Jubjub on-curve +
/// prime-order checks on clue R and ephemeral E.
library AuxValidation {
    /// 2B clueBits prefix + ChaCha20Poly1305 body, ≤256B total.
    uint256 internal constant MAX_CIPHERTEXT_LEN = 256;
    uint256 internal constant MIN_CIPHERTEXT_LEN = 2;
    /// 14-bit FMD clue mask; upper 2 bits of prefix MUST be zero.
    uint16 internal constant CLUE_BITS_MASK = 0x3FFF;

    /// Per-output FMD payload. Opaque to contract; wallet-computed.
    ///   clueR* : Baby-Jubjub R = [r]·G
    ///   ephPub*: Baby-Jubjub E = [e]·G
    ///   ciphertext: clueBits prefix (2B) || ChaCha20Poly1305 body.
    struct Output {
        uint256 clueRx;
        uint256 clueRy;
        uint256 ephPubX;
        uint256 ephPubY;
        bytes ciphertext;
    }

    error CiphertextTooLong();
    error BadClueBits();
    error OffCurvePoint();
    error LowOrderPoint();

    /// Validate both aux blobs: length bounds, clue-bits prefix, and that
    /// clue R and ephemeral E are on-curve and in the prime-order subgroup.
    function validate(Output[2] calldata aux) internal view {
        for (uint256 j; j < 2;) {
            Output calldata o = aux[j];
            bytes calldata ct = o.ciphertext;
            uint256 len = ct.length;
            if (len < MIN_CIPHERTEXT_LEN || len > MAX_CIPHERTEXT_LEN) revert CiphertextTooLong();
            if (uint16(bytes2(ct[0:2])) & ~CLUE_BITS_MASK != 0) revert BadClueBits();
            if (!BabyJubJub.isOnCurve(o.clueRx, o.clueRy)) revert OffCurvePoint();
            if (BabyJubJub.isLowOrder(o.clueRx, o.clueRy)) revert LowOrderPoint();
            if (!BabyJubJub.isOnCurve(o.ephPubX, o.ephPubY)) revert OffCurvePoint();
            if (BabyJubJub.isLowOrder(o.ephPubX, o.ephPubY)) revert LowOrderPoint();
            unchecked {
                ++j;
            }
        }
    }
}
