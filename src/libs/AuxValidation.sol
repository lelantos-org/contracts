// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BabyJubJub } from "../BabyJubJub.sol";

/// Struct and validation for per-output FMD payloads. `Output` is opaque to
/// the contract beyond its length bounds, its clue-bits prefix, and the
/// Baby-Jubjub on-curve and small-subgroup checks on clue R and ephemeral E.
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

    /// Validates every aux payload: length bounds, clue-bits prefix, and that
    /// clue R and ephemeral E are on-curve and outside the small subgroup. The
    /// loop bound is `aux.length`, so it follows the transact shape.
    ///
    /// This is not a prime-order-subgroup check. `isLowOrder` rejects points
    /// whose order divides the cofactor 8; Baby-Jubjub has order `8L`, so a
    /// point of order `2L`, `4L` or `8L` passes here. The full test is
    /// `[L]P == O`, a 252-bit scalar multiplication, paid six times per spend to
    /// duplicate a constraint the circuit already carries.
    ///
    /// The consequence is off-chain: pool funds do not depend on this, but a
    /// detector computing `[x]R` on an accepted mixed-order `R` leaks
    /// `x mod ord(T)`, up to three bits of the FMD detection key. Off-chain
    /// detection must clear the cofactor itself rather than treat an accepted
    /// clue as subgroup-clean.
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
        if (!BabyJubJub.isOnCurve(o.clueRx, o.clueRy)) revert OffCurvePoint();
        if (BabyJubJub.isLowOrder(o.clueRx, o.clueRy)) revert LowOrderPoint();
        if (!BabyJubJub.isOnCurve(o.ephPubX, o.ephPubY)) revert OffCurvePoint();
        if (BabyJubJub.isLowOrder(o.ephPubX, o.ephPubY)) revert LowOrderPoint();
    }
}
