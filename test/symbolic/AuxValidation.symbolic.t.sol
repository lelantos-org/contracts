// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";

import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../../src/BabyJubJub.sol";

/// Exposes the library's per-output validation as an external call, so a
/// rejection can be observed as a revert rather than unwinding the test.
contract AuxValidationHarness {
    function validate(AuxValidation.Output calldata o) external pure {
        AuxValidation.validate(o);
    }
}

/// Symbolic proofs for the aux payload's shape checks.
///
/// `AuxValidation.validate` runs four kinds of check in order: the ciphertext
/// length bounds, the clue-bits prefix mask, and then the Baby-Jubjub on-curve
/// and small-subgroup tests. Only the first two are provable here — the curve
/// checks are `mulmod` chains over a 254-bit prime, which is the shape no solver
/// in this suite finishes. The points are therefore held concrete at the
/// prime-order generator, which constant-folds those checks away and leaves the
/// shape rules as the subject. `test/fuzz/BabyJubJub.fuzz.t.sol` covers the
/// curve half differentially, which is the right tool for it.
///
/// Both proofs state the accept/reject boundary in both directions. A too-strict
/// bound would reject payloads a wallet legitimately produces, which a
/// rejection-only proof would not notice.
contract AuxValidationSymbolicTest is GuardAsserts {
    AuxValidationHarness internal h;

    function setUp() public {
        h = new AuxValidationHarness();
    }

    /// The Baby-Jubjub prime-order generator: on-curve and outside the small
    /// subgroup, so both curve checks pass concretely.
    function _payload(bytes memory ciphertext) internal pure returns (AuxValidation.Output memory o) {
        o.clueRx = BabyJubJub.BASE8_X;
        o.clueRy = BabyJubJub.BASE8_Y;
        o.ephPubX = BabyJubJub.BASE8_X;
        o.ephPubY = BabyJubJub.BASE8_Y;
        o.ciphertext = ciphertext;
    }

    function _validate(AuxValidation.Output memory o) internal view returns (bool ok, bytes memory ret) {
        (ok, ret) = address(h).staticcall(abi.encodeCall(AuxValidationHarness.validate, (o)));
    }

    /// A payload is accepted exactly when its ciphertext is within the length
    /// bounds and its clue-bits prefix is confined to 14 bits.
    ///
    /// The lengths are chosen either side of both boundaries. Halmos's default
    /// for a `bytes` parameter is `0,65,1024`, which straddles the valid range
    /// without landing on either edge — the off-by-one a length check is most
    /// likely to get wrong would go unnoticed. `2` and `256` are the inclusive
    /// bounds; `1`, `3`, `255` and `257` are their neighbours.
    ///
    /// @custom:halmos --array-lengths ct={0,1,2,3,255,256,257}
    function check_aux_acceptsExactlyWellFormedPayloads(bytes memory ct) public view {
        uint256 len = ct.length;
        bool lengthOk = len >= AuxValidation.MIN_CIPHERTEXT_LEN && len <= AuxValidation.MAX_CIPHERTEXT_LEN;

        // The prefix is only read once the length check has passed.
        bool clueOk = true;
        if (lengthOk) {
            uint16 prefix = (uint16(uint8(ct[0])) << 8) | uint16(uint8(ct[1]));
            clueOk = prefix & ~AuxValidation.CLUE_BITS_MASK == 0;
        }

        (bool ok,) = _validate(_payload(ct));

        assertEq(ok, lengthOk && clueOk);
    }

    /// The two bits above the 14-bit clue mask must be clear, for every prefix.
    ///
    /// The prefix is the FMD clue the recipient filters on; bits outside the
    /// mask are not part of that field, so accepting them would let a sender
    /// smuggle a distinguisher into what is meant to be an opaque payload.
    ///
    /// @custom:halmos --array-lengths ct=2
    function check_aux_rejectsPrefixOutsideTheClueMask(bytes memory ct) public view {
        vm.assume(ct.length == 2);
        uint16 prefix = (uint16(uint8(ct[0])) << 8) | uint16(uint8(ct[1]));
        vm.assume(prefix & ~AuxValidation.CLUE_BITS_MASK != 0);

        (bool ok, bytes memory ret) = _validate(_payload(ct));

        _assertRejected(ok, ret, AuxValidation.BadClueBits.selector);
    }
}
