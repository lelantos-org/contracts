// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BabyJubJub } from "../BabyJubJub.sol";

/// Struct and validation for per-output FMD payloads. `Output` is opaque to
/// the contract beyond its length bounds, its clue-bits prefix, and the
/// Baby-Jubjub checks on clue R and ephemeral E.
library AuxValidation {
    /// 2-byte clueBits prefix plus ChaCha20-Poly1305 body, 256 bytes at most.
    uint256 internal constant MAX_CIPHERTEXT_LEN = 256;
    uint256 internal constant MIN_CIPHERTEXT_LEN = 2;
    /// 14-bit FMD clue mask; the upper 2 bits of the prefix must be zero.
    uint16 internal constant CLUE_BITS_MASK = 0x3FFF;

    /// Per-output FMD payload, computed by the wallet.
    ///   clueR* : FMD clue point R, in the prime-order subgroup
    ///   clueQ* : subgroup witness for R, Q = [8^-1 mod L]·R, so [8]·Q = R
    ///   ephPub*: ECDH ephemeral public key E
    ///   ciphertext: 2-byte clueBits prefix || ChaCha20-Poly1305 body.
    struct Output {
        uint256 clueRx;
        uint256 clueRy;
        uint256 clueQx;
        uint256 clueQy;
        uint256 ephPubX;
        uint256 ephPubY;
        bytes ciphertext;
    }

    error CiphertextTooLong();
    error CiphertextTooShort();
    error BadClueBits();
    error OffCurvePoint();
    error LowOrderPoint();
    error BadClueWitness();

    /// Validates every aux payload: length bounds, clue-bits prefix, and the
    /// point checks below. The loop bound is `aux.length`, so it follows the
    /// transact shape.
    ///
    /// Clue `R` is in the prime-order subgroup and is not the identity: the
    /// witness `Q` is on-curve and `[8]Q == R`. A detector may compute `[x]R`
    /// on an accepted clue without leaking `x mod 8`.
    ///
    /// Ephemeral `E` is on-curve and outside the small subgroup, which is not a
    /// prime-order-subgroup check: `E` of order `2L`, `4L` or `8L` passes.
    /// Trial decryption must clear the cofactor of `E` itself.
    ///
    /// The arity is a literal because `PubInputs` imports this file and the
    /// dependency cannot be reversed. It must equal `PubInputs.TRANSACT_OUT`;
    /// drift fails to compile at every call site.
    function validate(Output[6] calldata aux) internal pure {
        for (uint256 j; j < aux.length;) {
            validate(aux[j]);
            unchecked {
                ++j;
            }
        }
    }

    /// Single-payload form, applying the same checks. A deposit occupies two
    /// leaves, the depositor's note and the relayer's fee note, so the deposit
    /// path calls this once per leaf.
    function validate(Output calldata o) internal pure {
        bytes calldata ct = o.ciphertext;
        uint256 len = ct.length;
        if (len < MIN_CIPHERTEXT_LEN) revert CiphertextTooShort();
        if (len > MAX_CIPHERTEXT_LEN) revert CiphertextTooLong();
        if (uint16(bytes2(ct[0:2])) & ~CLUE_BITS_MASK != 0) revert BadClueBits();
        if (!BabyJubJub.isOnCurve(o.clueQx, o.clueQy)) revert OffCurvePoint();
        if (!BabyJubJub.isEightfold(o.clueQx, o.clueQy, o.clueRx, o.clueRy)) revert BadClueWitness();
        if (o.clueRx == 0) revert LowOrderPoint();
        if (!BabyJubJub.isOnCurve(o.ephPubX, o.ephPubY)) revert OffCurvePoint();
        if (BabyJubJub.isLowOrder(o.ephPubX, o.ephPubY)) revert LowOrderPoint();
    }
}
