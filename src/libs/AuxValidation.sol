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
    error CiphertextTooShort();
    error BadClueBits();
    error OffCurvePoint();
    error LowOrderPoint();

    /// Validate every aux blob: length bounds, clue-bits prefix, and that
    /// clue R and ephemeral E are on-curve and in the prime-order subgroup.
    function validate(Output[3] calldata aux) internal pure {
        for (uint256 j; j < 3;) {
            validate(aux[j]);
            unchecked {
                ++j;
            }
        }
    }

    /// Single-blob form. A deposit occupies one leaf and so carries exactly
    /// one aux payload; the `[3]` form above is the transact path's three
    /// outputs run through the same checks.
    function validate(Output calldata o) internal pure {
        bytes calldata ct = o.ciphertext;
        uint256 len = ct.length;
        if (len < MIN_CIPHERTEXT_LEN) revert CiphertextTooShort();
        if (len > MAX_CIPHERTEXT_LEN) revert CiphertextTooLong();
        if (uint16(bytes2(ct[0:2])) & ~CLUE_BITS_MASK != 0) revert BadClueBits();
        if (!BabyJubJub.isOnCurve(o.clueRx, o.clueRy)) revert OffCurvePoint();
        if (BabyJubJub.isLowOrder(o.clueRx, o.clueRy)) revert LowOrderPoint();
        if (!BabyJubJub.isOnCurve(o.ephPubX, o.ephPubY)) revert OffCurvePoint();
        if (BabyJubJub.isLowOrder(o.ephPubX, o.ephPubY)) revert LowOrderPoint();
    }
}
