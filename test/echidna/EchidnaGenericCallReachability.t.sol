// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { EchidnaGenericCall } from "./EchidnaGenericCall.sol";

/// Reachability gate for `EchidnaGenericCall`: every handler and every swap
/// mode takes its intended path, and every property holds afterwards. A handler
/// that always returned early would leave the properties holding vacuously.
contract EchidnaGenericCallReachabilityTest is Test {
    EchidnaGenericCall internal target;

    function setUp() public {
        target = new EchidnaGenericCall();
        vm.warp(1_000_000);
    }

    function test_swapModes_landOrRefundAsNamed() public {
        _swap(EchidnaGenericCall.SwapMode.Honest, 0);
        _swap(EchidnaGenericCall.SwapMode.UnusedInput, 0);
        _swap(EchidnaGenericCall.SwapMode.DonationMidLeg, 11);
        _swap(EchidnaGenericCall.SwapMode.PrefundedExecutor, 13);
        _swap(EchidnaGenericCall.SwapMode.StaleApproval, 0);
        assertEq(target.successCount(), 5, "landing modes");

        _swap(EchidnaGenericCall.SwapMode.Shortfall, 0);
        _swap(EchidnaGenericCall.SwapMode.FailingCall, 0);
        _swap(EchidnaGenericCall.SwapMode.Expired, 0);
        _swap(EchidnaGenericCall.SwapMode.DeniedTarget, 0);
        _swap(EchidnaGenericCall.SwapMode.HookDrain, 0);
        assertEq(target.refundCount(), 5, "refunding modes");
        assertEq(target.hookDrainRefunds(), 1, "hook drain refunded");

        _assertAllProperties();
    }

    /// Tokens prefunded to a clone address whose execution refunds wait there
    /// until the next landed execution reuses the address and sweeps them.
    function test_strandedPrefund_sweptByNextExecution() public {
        _swap(EchidnaGenericCall.SwapMode.PrefundedExecutor, 17);
        _swap(EchidnaGenericCall.SwapMode.Shortfall, 0);
        _swap(EchidnaGenericCall.SwapMode.Honest, 0);
        _assertAllProperties();
    }

    function test_betweenExecutionHandlers() public {
        _swap(EchidnaGenericCall.SwapMode.Honest, 0);
        _swap(EchidnaGenericCall.SwapMode.StaleApproval, 0);
        target.split(800, 50, 60, 9);
        assertEq(target.splitCount(), 1, "split");

        target.flush(0);
        assertEq(target.flushCount(), 1, "flush");
        target.cancel(1);
        assertEq(target.cancelCount(), 1, "cancel");
        target.cancel(0);
        target.cancel(1);
        assertEq(target.settledCancelAttempts(), 2, "settled cancels attempted");

        target.donate(123);
        target.drainPast(1);
        assertGt(target.drainAttempts(), 0, "drain attempted");

        _assertAllProperties();
    }

    function test_refusalHandlers() public {
        for (uint8 field; field < 8; ++field) {
            target.tamper(300, field);
        }
        target.stranger(300, address(0xB0B));
        target.oversized(300, 5);
        assertEq(target.tamperAttempts(), 8, "tamper");
        assertEq(target.strangerAttempts(), 1, "stranger");
        assertEq(target.oversizedAttempts(), 1, "oversized");

        _assertAllProperties();
    }

    function _swap(EchidnaGenericCall.SwapMode mode, uint64 extra) internal {
        target.swap(500, 300, 7, uint8(mode), extra);
    }

    function _assertAllProperties() internal view {
        assertTrue(target.echidna_poolBalancesMatch(), "pool balances");
        assertTrue(target.echidna_surplusMatches(), "surplus");
        assertTrue(target.echidna_refundsMatch(), "refunds");
        assertTrue(target.echidna_wrapperHoldsOnlyDonations(), "wrapper residue");
        assertTrue(target.echidna_executorsEmpty(), "executors");
        assertTrue(target.echidna_escrowRecordsMatchPool(), "records");
        assertTrue(target.echidna_outcomesAsPredicted(), "outcomes");
        assertTrue(target.echidna_guardsHold(), "guards");
    }
}
