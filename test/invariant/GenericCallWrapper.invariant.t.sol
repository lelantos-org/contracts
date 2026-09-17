// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { EchidnaGenericCall } from "../echidna/EchidnaGenericCall.sol";

/// Foundry invariant run over `GenericCallWrapper`, sharing its handlers and
/// books with the Echidna target `EchidnaGenericCall`. The two engines differ
/// in how they search (a fixed seed here, a persistent corpus there), not in
/// what they check, so the properties are the target's own.
contract GenericCallWrapperInvariantTest is Test {
    EchidnaGenericCall internal target;

    function setUp() public {
        target = new EchidnaGenericCall();

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = EchidnaGenericCall.swap.selector;
        selectors[1] = EchidnaGenericCall.split.selector;
        selectors[2] = EchidnaGenericCall.cancel.selector;
        selectors[3] = EchidnaGenericCall.flush.selector;
        selectors[4] = EchidnaGenericCall.donate.selector;
        selectors[5] = EchidnaGenericCall.drainPast.selector;
        selectors[6] = EchidnaGenericCall.tamper.selector;
        selectors[7] = EchidnaGenericCall.stranger.selector;
        selectors[8] = EchidnaGenericCall.oversized.selector;
        targetContract(address(target));
        targetSelector(FuzzSelector({ addr: address(target), selectors: selectors }));
    }

    function invariant_poolBalancesMatch() public view {
        assertTrue(target.echidna_poolBalancesMatch(), "pool balances");
    }

    function invariant_surplusMatches() public view {
        assertTrue(target.echidna_surplusMatches(), "surplusTo balances");
    }

    function invariant_refundsMatch() public view {
        assertTrue(target.echidna_refundsMatch(), "refundTo balances");
    }

    function invariant_wrapperHoldsOnlyDonations() public view {
        assertTrue(target.echidna_wrapperHoldsOnlyDonations(), "wrapper residue");
    }

    function invariant_executorsEmpty() public view {
        assertTrue(target.echidna_executorsEmpty(), "executor residue or drain");
    }

    function invariant_escrowRecordsMatchPool() public view {
        assertTrue(target.echidna_escrowRecordsMatchPool(), "escrow records");
    }

    function invariant_outcomesAsPredicted() public view {
        assertTrue(target.echidna_outcomesAsPredicted(), "outcome mismatch");
    }

    function invariant_guardsHold() public view {
        assertTrue(target.echidna_guardsHold(), "guard breached");
    }

    function invariant_noResidue() public view {
        assertEq(target.optimize_wrapperResidue(), 0, "wrapper residue");
        assertEq(target.optimize_surplusDrift(), 0, "surplus drift");
    }
}
