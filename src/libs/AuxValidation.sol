// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { BabyJubJub } from "../BabyJubJub.sol";

/// Struct and validation for per-output FMD payloads. `Output` is opaque to the
/// contract beyond its length bounds, its clue-bits prefix, and the Baby-Jubjub
/// on-curve and prime-order checks on clue R and ephemeral E.
library AuxValidation {
    /// 2-byte clueBits prefix plus ChaCha20-Poly1305 body, 256 bytes at most.
    uint256 internal constant MAX_CIPHERTEXT_LEN = 256;
    uint256 internal constant MIN_CIPHERTEXT_LEN = 2;
    /// 14-bit FMD clue mask; the upper 2 bits of the prefix must be zero.
    uint16 internal constant CLUE_BITS_MASK = 0x3FFF;

    /// Per-output FMD payload, computed by the wallet.
    ///   clueR* : Baby-Jubjub R = [r]·G
    ///   ephPub*: Baby-Jubjub E = [e]·G
    ///   ciphertext: 2-byte clueBits prefix || ChaCha20-Poly1305 body.
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

    /// Validate every aux payload: length bounds, clue-bits prefix, and that
    /// clue R and ephemeral E are on-curve and in the prime-order subgroup.
    function validate(Output[3] calldata aux) internal pure {
        for (uint256 j; j < 3;) {
            validate(aux[j]);
            unchecked {
                ++j;
            }
        }
    }

    /// Single-payload form. A deposit occupies one leaf and so carries exactly
    /// one aux payload; the `[3]` form above runs the transact path's three
    /// outputs through the same checks.
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
