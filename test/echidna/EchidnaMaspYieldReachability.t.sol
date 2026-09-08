// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { EchidnaMaspYield } from "./EchidnaMaspYield.sol";

/// Reachability gate for the yield target, run by `forge test`.
///
/// Every handler in `EchidnaMaspYield` wraps its pool call in `try`, which is
/// what lets a random sequence continue through an invalid combination — and
/// also what lets an entire path revert on every attempt while the properties
/// pass over a history that never reached it. `YieldSolvency.invariant.t.sol`
/// carries the same guard for the same reason.
///
/// The optimization targets are the point of that file, and they are the most
/// exposed of all: `optimize_freeMoney` reports 0 both when the accounting is
/// exact and when nothing was ever paid out.
contract EchidnaMaspYieldReachabilityTest is Test {
    EchidnaMaspYield internal target;

    function setUp() public {
        target = new EchidnaMaspYield();
    }

    function test_yieldHandlersReachEveryPath() public {
        // --- shield both ids over the shared ERC-20 ---
        target.depositYield(500_000);
        target.depositPlain(400_000);
        assertEq(target.shields(), 2, "shield path");
        assertGt(target.yieldPaidIn(), 0, "yield id took funds in");
        assertGt(target.plainHeld(), 0, "plain id took funds in");

        // --- settle ---
        target.flush(0);
        target.flush(1);
        assertEq(target.flushes(), 2, "flush path");

        // --- venue movement ---
        target.earn(1e18);
        assertEq(target.earns(), 1, "earn path");
        assertGt(target.venueEarned(), 0, "venue earned");

        target.rebalance();
        target.accruePerf();

        target.lose(1e15);
        assertEq(target.losses(), 1, "loss path");
        assertGt(target.venueLost(), 0, "venue lost");

        target.squeeze(type(uint96).max);
        target.setParams(1_000, 10);

        // --- exit ---
        target.withdrawYield(1);
        assertEq(target.exits(), 1, "yield exit path");
        assertGt(target.yieldPaidOut(), 0, "yield id paid out");

        target.withdrawPlain(1);
        assertEq(target.exits(), 2, "plain exit path");

        // --- fee sweep ---
        target.accruePerf();
        target.sweepYield();

        // Every property must hold after a full lap, otherwise the Echidna run
        // would be reporting on a handler set that cannot complete one.
        assertTrue(target.echidna_noFreeMoney(), "no free money");
        assertTrue(target.echidna_poolCoversIdlePlusPlainLiability(), "pool covers idle + plain");
        assertTrue(target.echidna_idleNeverExceedsGross(), "idle within backing");
        assertTrue(target.echidna_everyUnitIsBacked(), "units backed");
        assertTrue(target.echidna_highWaterMarkNeverFalls(), "high-water mark held");
        assertTrue(target.echidna_venueBindingImmutable(), "venue binding held");
    }

    /// The optimization targets must be reporting on a history that actually
    /// moved value. A maximum of 0 over a run that never paid anything out is
    /// indistinguishable from exact accounting, and the whole reason the file
    /// exists is to measure that slack.
    function test_optimizationTargetsSeeRealFlow() public {
        target.depositYield(500_000);
        target.flush(0);
        target.earn(1e18);
        target.accruePerf();
        target.withdrawYield(1);

        assertGt(target.yieldPaidIn(), 0, "optimization target has inflow to price against");
        assertGt(target.yieldPaidOut(), 0, "optimization target has outflow to price");

        // Non-positive is the passing direction: the pool has not paid out
        // more than came in plus what was earned. The optimizer's job is to
        // find how close to zero it can drive this from below.
        assertLe(target.optimize_freeMoney(), int256(0), "free money found");
        assertLe(target.optimize_idleOverGross(), int256(0), "idle exceeds backing");
    }
}
