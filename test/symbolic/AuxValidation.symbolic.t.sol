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
/// `AuxValidation.validate` checks, in order: ciphertext length bounds, the
/// clue-bits prefix mask, then Baby-Jubjub on-curve and small-subgroup membership.
/// Only the first two are proved here: the curve checks are `mulmod` chains over a
/// 254-bit prime that the bundled solvers do not finish. The points are held
/// concrete at the prime-order generator, which constant-folds the curve checks.
/// `test/fuzz/BabyJubJub.fuzz.t.sol` covers the curve checks differentially.
///
/// The proofs state the accept/reject boundary in both directions, so an
/// over-strict bound that rejects well-formed wallet payloads also fails.
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
    /// The lengths sit on and around both boundaries. Halmos's default `bytes`
    /// lengths (`0,65,1024`) straddle the valid range without hitting either edge,
    /// so they miss off-by-one errors. `2` and `256` are the inclusive bounds;
    /// `1`, `3`, `255` and `257` are their neighbours.
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
    /// The prefix is the FMD clue the recipient filters on. Bits outside the mask
    /// are not part of that field; accepting them would let a sender embed a
    /// distinguisher in an otherwise opaque payload.
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
