// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { YieldIndex } from "../../src/yield/YieldIndex.sol";
import { YieldOps } from "../../src/yield/YieldOps.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";

import { YieldTestBase } from "../utils/YieldTestBase.sol";

/// Performance fee on the pool-managed yield index: accrual on growth only, the
/// high-water mark, treasury sweeps, and the delayed-raise / immediate-decrease
/// rules for `perfBps`.
contract YieldIndexPerfFeeTest is YieldTestBase {
    uint64 internal constant N = 1_000_000; // units; fee at 25bps is 2_500

    // ============== Performance fee ==========================================

    function test_perfFee_accruesOnGrowthOnly() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 feeBefore = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertEq(feeBefore, 0, "nothing owed before any growth");

        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);
        uint256 feeAfter = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertGt(feeAfter, 0, "treasury minted units against the growth");

        // ~10% of the growth, valued at the post-accrual index.
        // Floored to whole normalized units, so at `scale = 1e10` the cut can
        // be up to one unit short of the nominal 10%, never over: every rounding
        // step favours holders over the treasury.
        uint256 treasuryValue = (feeAfter * _gross(YIELD_ID)) / _supply(YIELD_ID);
        uint256 nominal = (1_000 * SCALE * PERF_BPS) / 10_000;
        assertLe(treasuryValue, nominal, "never charges more than perfBps of the growth");
        assertGe(treasuryValue + SCALE, nominal, "and is short by less than one unit");
    }

    /// The high-water mark needs no extra state: a loss leaves `lastIdx`
    /// unchanged, so nothing is charged until the previous peak is exceeded.
    function test_perfFee_highWaterMark_chargesNothingUntilRecovered() public {
        _deposit(YIELD_ID, N, 0x101);
        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);
        uint256 afterFirst = masp.yieldState(YIELD_ID).accruedFeeNormalized;

        vault.lose(800 * SCALE);
        masp.accruePerf(YIELD_ID);
        uint256 afterLoss = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertEq(afterLoss, afterFirst, "no fee charged through a loss");

        // Recovering only part of the way back still owes nothing.
        _earn(500 * SCALE);
        masp.accruePerf(YIELD_ID);
        uint256 afterPartial = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertEq(afterPartial, afterFirst, "no fee until the old peak is exceeded");

        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);
        uint256 afterRecovery = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertGt(afterRecovery, afterFirst, "charged again only above the mark");
    }

    /// A performance cut worth less than one unit does not follow the growth
    /// onto the next depositor.
    ///
    /// The sub-unit cut mints nothing and carries forward. Were the mark left
    /// at the old index when a deposit grows the supply, the next accrual would
    /// measure the entrant's units against it and bill them for growth that
    /// predates them. At `scale = 1` a dust position can carry a large backlog:
    /// a one-unit deposit plus a 1e6-wei donation to the venue was enough to
    /// take about a tenth of the next deposit's value.
    function test_perfFee_subUnitAccrualDoesNotBillTheNextDepositor() public {
        // A one-unit position on the empty id: two units with the fee.
        _deposit(FINE_ID, 1, 0x101);
        _earnInto(vaultFine, 1e6);
        masp.accruePerf(FINE_ID);
        assertEq(masp.yieldState(FINE_ID).accruedFeeNormalized, 0, "a sub-unit cut mints nothing");

        uint256 unitsBefore = masp.yieldState(FINE_ID).totalNormalized;
        (, uint256 victimPull) = _deposit(FINE_ID, 20_000, 0x301);
        uint256 victimUnits = masp.yieldState(FINE_ID).totalNormalized - unitsBefore;
        uint256 feeAtArrival = masp.yieldState(FINE_ID).accruedFeeNormalized;

        masp.accruePerf(FINE_ID);
        assertEq(
            masp.yieldState(FINE_ID).accruedFeeNormalized, feeAtArrival, "billed growth that predates the depositor"
        );

        uint256 victimValue = (victimUnits * _grossFine()) / _supply(FINE_ID);
        uint256 loss = victimValue >= victimPull ? 0 : victimPull - victimValue;
        assertLe(loss, victimPull / 10_000, "depositor lost more than 1 bps");
    }

    /// The growth the rounded-up mark hides is forgiven too.
    ///
    /// `hwm` is ceilinged, so `gross` can sit a wei above the stored mark while
    /// `g <= hwm` still holds. Left in place, a large arrival multiplies that wei
    /// by its share of the new supply and the next accrual bills it; on a dust
    /// pool at scale 1 this cost the arrival 62.5 bps.
    function test_perfFee_roundedMarkDoesNotBillTheNextDepositor() public {
        vm.prank(OWNER);
        masp.setYieldParams(FINE_ID, 0, PERF_BPS);
        _deposit(FINE_ID, 3, 0x101);
        _earnInto(vaultFine, 1);
        // Raises the mark to a ceiling that sits above `gross` by under a wei.
        _deposit(FINE_ID, 1, 0x201);

        uint256 unitsBefore = masp.yieldState(FINE_ID).totalNormalized;
        (, uint256 victimPull) = _deposit(FINE_ID, 1_000_000_000_000, 0x301);
        uint256 victimUnits = masp.yieldState(FINE_ID).totalNormalized - unitsBefore;
        uint256 feeAtArrival = masp.yieldState(FINE_ID).accruedFeeNormalized;

        masp.accruePerf(FINE_ID);
        assertEq(
            masp.yieldState(FINE_ID).accruedFeeNormalized, feeAtArrival, "billed growth hidden by the rounded mark"
        );

        uint256 victimValue = (victimUnits * _grossFine()) / _supply(FINE_ID);
        uint256 loss = victimValue >= victimPull ? 0 : victimPull - victimValue;
        assertLe(loss, victimPull / 10_000, "depositor lost more than 1 bps");
    }

    /// The entrant-only forgiveness is not reachable from `accruePerf`.
    ///
    /// Anyone may call `accruePerf`. If every call raised the mark while the cut
    /// was below one unit, calling it each block would erase the fee on any
    /// asset whose per-block growth stays sub-unit. Instead the mark holds and the
    /// growth accumulates until it is billed.
    function test_perfFee_permissionlessAccrueDoesNotForgiveSubUnitGrowth() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 s = _supply(YIELD_ID);
        uint256 markValue = s * SCALE; // the mark is still `RAY`

        // One unit's worth per step; a tenth of it is well under one unit.
        for (uint256 i = 0; i < 5; ++i) {
            _earn(SCALE);
            masp.accruePerf(YIELD_ID);
            assertEq(masp.yieldState(YIELD_ID).lastIdx, RAY, "a sub-unit accrual moved the mark");
            assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, 0, "a sub-unit accrual minted");
        }

        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);

        // Billed from the original mark, so the five sub-unit steps are included.
        uint256 g = _gross(YIELD_ID);
        uint256 cut = ((g - markValue) * PERF_BPS) / 10_000;
        uint256 expected = Math.mulDiv(cut, s, g - cut);
        assertGt(expected, 0, "the later growth is billable");
        assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, expected, "carried growth was forgiven");
    }

    function test_sweepNormalized_paysTreasuryAndClears() public {
        _deposit(YIELD_ID, N, 0x101);
        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);

        uint256 before = token.balanceOf(TREASURY);
        uint256 amount = masp.sweepNormalized(YIELD_ID);
        assertGt(amount, 0, "treasury paid");
        assertEq(token.balanceOf(TREASURY) - before, amount, "tokens actually moved");
        uint256 feeAfter = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertEq(feeAfter, 0, "accumulator cleared");
    }

    /// A sweep worth less than one base unit leaves the accrual unchanged.
    ///
    /// The accumulator must not be zeroed before the payout is checked;
    /// otherwise a single permissionless call while the pool is deeply under
    /// water would discard the treasury's entire accrual without emitting
    /// `NormalizedFeeSwept`, which follows the zero-payout early return.
    function test_sweepNormalized_zeroValueSweepKeepsTheAccrual() public {
        // Zero buffer, so a vault loss can drive `gross` down to dust; a `scale`
        // of one allows the floored payout to reach zero.
        vm.prank(OWNER);
        masp.setYieldParams(FINE_ID, 0, PERF_BPS);

        _deposit(FINE_ID, N, 0x101);
        _earnInto(vaultFine, 5e17);
        masp.accruePerf(FINE_ID);
        masp.rebalance(FINE_ID);

        uint256 accrued = masp.yieldState(FINE_ID).accruedFeeNormalized;
        assertGt(accrued, 0, "fee accrued");

        // Near-total loss: those units are now worth less than one base unit.
        vaultFine.lose(vaultFine.totalAssetsHeld() - 1);

        uint256 treasuryBefore = token.balanceOf(TREASURY);
        assertEq(masp.sweepNormalized(FINE_ID), 0, "payout floors to zero");
        assertEq(token.balanceOf(TREASURY), treasuryBefore, "nothing moved");
        assertEq(masp.yieldState(FINE_ID).accruedFeeNormalized, accrued, "accrual survives");

        // Still claimable once the vault recovers.
        _earnInto(vaultFine, 5e17);
        assertGt(masp.sweepNormalized(FINE_ID), 0, "claimable after recovery");
    }

    /// A parameter change does not lower the high-water mark.
    ///
    /// `setParams` re-marks `lastIdx` so that enabling a fee cannot bill
    /// earlier growth, but it only raises the mark. With a plain assignment, an
    /// owner could lower the mark to the post-loss index with a no-op parameter
    /// change and then bill the recovery, defeating the high-water mark.
    function test_setYieldParams_cannotResetTheHighWaterMarkAfterALoss() public {
        _deposit(YIELD_ID, N, 0x101);
        _earn(2_000 * SCALE);
        masp.accruePerf(YIELD_ID);

        uint256 markAtPeak = masp.yieldState(YIELD_ID).lastIdx;
        uint256 feeAtPeak = masp.yieldState(YIELD_ID).accruedFeeNormalized;

        vault.lose(1_500 * SCALE);

        // A no-op parameter change, at the bottom.
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, PERF_BPS);
        assertEq(masp.yieldState(YIELD_ID).lastIdx, markAtPeak, "mark moved down on a parameter change");

        // Recovering part of the way back must still owe nothing.
        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);
        assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, feeAtPeak, "billed a recovery below the old peak");
    }

    // ============== Delayed perf raises ======================================

    /// The treasury's units a call to `accruePerf` would mint right now, read
    /// without keeping the accrual.
    function _accrualNow(uint64 id) internal returns (uint256 fee) {
        uint256 snap = vm.snapshotState();
        masp.accruePerf(id);
        fee = masp.yieldState(id).accruedFeeNormalized;
        vm.revertToState(snap);
    }

    /// Committing a perf raise bills growth up to the commit at the old rate,
    /// growth during the notice included, and only later growth at the new one.
    ///
    /// From zero, the old rate bills nothing and the commit re-marks, so the
    /// fee-free period stays free. From a non-zero rate, the commit mints exactly
    /// what an accrual at the old rate would have, then the new rate applies to
    /// growth from there.
    function test_perfRaiseCommitDoesNotBillEarlierGrowth() public {
        // --- 0 -> X ---
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, 0);
        _deposit(YIELD_ID, N, 0x101);
        _earn(500 * SCALE);

        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, PERF_BPS);
        assertEq(masp.yieldState(YIELD_ID).perfBps, 0, "raise applied without notice");
        _earn(500 * SCALE); // during the notice, still fee-free

        _commit(YIELD_ID);
        YieldIndex.YieldState memory st = masp.yieldState(YIELD_ID);
        assertEq(st.perfBps, PERF_BPS);
        assertEq(st.accruedFeeNormalized, 0, "commit billed the fee-free period");
        assertGe(st.lastIdx, masp.index(YIELD_ID), "mark not raised to the commit");
        masp.accruePerf(YIELD_ID);
        assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, 0, "fee-free growth billed after the commit");

        // --- X -> Y ---
        uint16 raised = 2_000;
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, raised);
        _earn(1_000 * SCALE); // during the notice, billable at X

        vm.warp(vm.getBlockTimestamp() + ExitTerms.DELAY);
        uint256 atOldRate = _accrualNow(YIELD_ID);
        assertGt(atOldRate, 0, "fixture: notice-period growth is billable");
        masp.commitExitTerms(YIELD_ID);
        st = masp.yieldState(YIELD_ID);
        assertEq(st.perfBps, raised);
        assertEq(st.accruedFeeNormalized, atOldRate, "notice-period growth not billed at the old rate");

        // Later growth is billed at Y, from the commit's mark.
        uint256 s = _supply(YIELD_ID);
        uint256 hwm = Math.mulDiv(s * SCALE, st.lastIdx, RAY, Math.Rounding.Ceil);
        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);
        uint256 g = _gross(YIELD_ID);
        uint256 cut = ((g - hwm) * raised) / 10_000;
        assertEq(
            masp.yieldState(YIELD_ID).accruedFeeNormalized - atOldRate,
            Math.mulDiv(cut, s, g - cut),
            "post-commit growth not billed at the new rate"
        );
    }

    /// Lowering the rate applies in the same call, after settling at the old
    /// rate, and leaves nothing queued.
    function test_perfDecreaseIsImmediate() public {
        _deposit(YIELD_ID, N, 0x101);
        _earn(1_000 * SCALE);
        uint256 atOldRate = _accrualNow(YIELD_ID);
        assertGt(atOldRate, 0);

        vm.expectEmit(address(masp));
        emit YieldOps.YieldParamsSet(YIELD_ID, BUFFER_BPS, 100);
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, 100);

        YieldIndex.YieldState memory st = masp.yieldState(YIELD_ID);
        assertEq(st.perfBps, 100, "decrease was not immediate");
        assertEq(st.accruedFeeNormalized, atOldRate, "growth before the change not settled at the old rate");

        vm.warp(vm.getBlockTimestamp() + ExitTerms.DELAY);
        vm.expectRevert(ExitTerms.NoPendingRaise.selector);
        masp.commitExitTerms(YIELD_ID);
    }

    /// The buffer changes no holder's claim, so it applies at once even when
    /// the same call queues a perf raise; the commit later leaves it alone.
    function test_bufferChangeIsImmediateEvenWithPerfRaise() public {
        uint256 due = vm.getBlockTimestamp() + ExitTerms.DELAY;
        vm.expectEmit(address(masp));
        emit ExitTerms.ExitTermRaisePending(YIELD_ID, ExitTerms.PERF_BPS, 2_000, due);
        vm.expectEmit(address(masp));
        emit YieldOps.YieldParamsSet(YIELD_ID, 3_000, PERF_BPS);
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, 3_000, 2_000);

        YieldIndex.YieldState memory st = masp.yieldState(YIELD_ID);
        assertEq(st.bufferBps, 3_000, "buffer not immediate");
        assertEq(st.perfBps, PERF_BPS, "raise applied without notice");

        vm.warp(due - 1);
        vm.expectRevert(abi.encodeWithSelector(ExitTerms.RaiseNotDue.selector, due));
        masp.commitExitTerms(YIELD_ID);

        vm.warp(due);
        vm.expectEmit(address(masp));
        emit YieldOps.YieldParamsSet(YIELD_ID, 3_000, 2_000);
        masp.commitExitTerms(YIELD_ID);
        st = masp.yieldState(YIELD_ID);
        assertEq(st.bufferBps, 3_000);
        assertEq(st.perfBps, 2_000);
    }

    /// Only a yield asset has a perf rate: proposing one for a plain id reverts
    /// before anything is queued.
    function test_revert_NotYieldAsset_perfRaiseOnPlainId() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(YieldOps.NotYieldAsset.selector, PLAIN_ID));
        masp.setYieldParams(PLAIN_ID, 0, 2_000);
    }
}
