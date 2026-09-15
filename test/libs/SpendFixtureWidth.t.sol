// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { SpendFixture, SPEND_OUTPUTS } from "../utils/SpendFixture.sol";

/// `AuxValidation.validate` takes `calldata`, so reaching it from a memory
/// fixture needs one external hop.
contract AuxHarness {
    function validate(AuxValidation.Output[SPEND_OUTPUTS] calldata aux) external pure {
        AuxValidation.validate(aux);
    }
}

/// Pins the three places the transact output width is written down.
///
/// `PubInputs.TRANSACT_OUT` is the source of truth. The other two are literals
/// because Solidity does not accept a library `internal constant` as an array
/// length: `SPEND_OUTPUTS` in the test fixture, and the `Output[6]` parameter
/// of `AuxValidation.validate`. No declaration ties the literals to
/// `TRANSACT_OUT`, and a mismatch can leave trailing payloads unvalidated.
contract SpendFixtureWidthTest is Test {
    AuxHarness internal harness;

    function setUp() public {
        harness = new AuxHarness();
    }

    function test_fixtureWidthMatchesTransactShape() public pure {
        assertEq(SPEND_OUTPUTS, PubInputs.TRANSACT_OUT, "SPEND_OUTPUTS != PubInputs.TRANSACT_OUT");
    }

    /// The aux array `AuxValidation.validate` accepts is exactly as wide as the
    /// shape, so no output goes unchecked. Asserted through the fixture's
    /// return type, which is the same `Output[N]` the validator takes; diverging
    /// widths fail to compile.
    function test_validatorAcceptsFullWidthAux() public view {
        AuxValidation.Output[SPEND_OUTPUTS] memory aux = SpendFixture.validAux();
        assertEq(aux.length, PubInputs.TRANSACT_OUT, "aux width != TRANSACT_OUT");
        harness.validate(aux);
    }

    /// Every slot is populated, not only the leading ones. A helper that filled
    /// `n-1` slots would leave the last ciphertext empty and fail later inside
    /// an unrelated spend test.
    function test_validAuxPopulatesEverySlot() public pure {
        AuxValidation.Output[SPEND_OUTPUTS] memory aux = SpendFixture.validAux();
        for (uint256 k; k < aux.length; ++k) {
            assertGt(aux[k].ciphertext.length, 0, "empty ciphertext slot");
            assertTrue(aux[k].clueRx != 0 && aux[k].ephPubX != 0, "unset point slot");
        }
    }
}
