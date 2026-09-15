// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";
import { YieldOps } from "../../src/yield/YieldOps.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";

import { YieldBase } from "./YieldBase.t.sol";

/// Behaviour of the pool-managed yield index.
contract YieldIndexTest is YieldBase {
    uint64 internal constant N = 1_000_000; // units; fee at 25bps is 2_500

    // ============== Shielding ================================================

    /// An empty asset has no ratio yet, so one unit is worth exactly `scale`
    /// and the index reads `RAY`, which fixes the first deposit's price.
    function test_firstDeposit_indexIsRay_andPullIsExact() public {
        (, uint256 pulled) = _deposit(YIELD_ID, N, 0x101);
        uint256 nFee = (uint256(N) * FEE_BPS) / 10_000;
        uint256 expected = (uint256(N) + nFee) * SCALE;

        assertEq(pulled, expected, "pull is (publicIn + fee) * scale");
        assertEq(masp.index(YIELD_ID), RAY, "index starts at RAY");
        assertEq(_supply(YIELD_ID), uint256(N) + nFee, "fee units held as principal until flush");
    }

    /// Everything above the buffer target is supplied to the venue at submit,
    /// not at flush: a note minted at `n` must be backed by `n` at the index at
    /// which the pool received it.
    function test_deposit_fundsVenueDownToBuffer() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 g = _gross(YIELD_ID);
        assertEq(_idle(YIELD_ID), (g * BUFFER_BPS) / 10_000, "idle held at the buffer target");
        assertGt(vault.balanceOf(address(venue)), 0, "remainder supplied to the venue");
    }

    // ============== Earning ==================================================

    /// Units stay fixed while their value grows.
    function test_earn_thenWithdraw_paysMoreThanWasDeposited() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 perUnitBefore = masp.index(YIELD_ID);

        _earn(1_000 * SCALE);
        assertGt(masp.index(YIELD_ID), perUnitBefore, "index rises with the venue");

        uint256 recipientBefore = token.balanceOf(RECIPIENT);
        _withdraw(YIELD_ID, N, 0x1111);
        uint256 paid = token.balanceOf(RECIPIENT) - recipientBefore;

        uint256 nFee = (uint256(N) * FEE_BPS) / 10_000;
        assertGt(paid, (uint256(N) - nFee) * SCALE, "payout exceeds the flat-rate value of the same units");
    }

    /// `publicOut == publicIn` across a round trip that earned. The circuit
    /// never sees the index, so the published integers are unchanged.
    function test_unitsAreStableAcrossEarning() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 unitsAfterDeposit = _supply(YIELD_ID);
        _earn(5_000 * SCALE);
        assertEq(_supply(YIELD_ID), unitsAfterDeposit, "earning mints no units to holders");
    }

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

    // ============== Venue liveness ===========================================

    /// A drained venue is a liveness failure, not a loss: the spend reverts
    /// entirely, so its nullifiers stay unspent and the note remains.
    function test_drainedVenue_revertsWithdraw_andLeavesNullifiersUnspent() public {
        _deposit(YIELD_ID, N, 0x101);
        vault.setLiquidityCap(0);

        PubInputs.Transact memory pi;
        pi.chainId = block.chainid;
        pi.publicAssetId = YIELD_ID;
        pi.publicOut = N;
        pi.recipient = RECIPIENT;
        pi.payer = SPEND_PAYER;
        pi.relayer = RELAYER;
        pi.merkleRoot = masp.currentRoot();

        vm.expectRevert();
        this.attemptWithdraw(YIELD_ID, N, 0x2222);

        assertFalse(masp.spent(bytes32(uint256(0x2222))), "nullifier untouched by the reverted spend");
    }

    /// External so `vm.expectRevert` has a call boundary to catch.
    function attemptWithdraw(uint64 id, uint64 publicOut, uint256 seed) external {
        _withdraw(id, publicOut, seed);
    }

    /// After an unwind the venue is off the withdrawal path; venue liveness
    /// recovery depends on this.
    function test_emergencyUnwind_takesVenueOffTheWithdrawalPath() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 idxBefore = masp.index(YIELD_ID);

        vm.prank(OWNER);
        masp.emergencyUnwind(YIELD_ID);

        assertEq(masp.index(YIELD_ID), idxBefore, "unwind moves tokens, it does not revalue notes");
        assertEq(_idle(YIELD_ID), _gross(YIELD_ID), "everything is idle");

        // The vault becomes fully illiquid; withdrawals still succeed.
        vault.setLiquidityCap(0);
        uint256 before = token.balanceOf(RECIPIENT);
        _withdraw(YIELD_ID, N, 0x3333);
        assertGt(token.balanceOf(RECIPIENT) - before, 0, "served entirely from idle");
    }

    /// Unwind must not clear the binding: doing so would flip the asset onto
    /// the plain arithmetic, where the same integers mean underlying.
    function test_emergencyUnwind_keepsVenueBoundAndAssetIndexed() public {
        _deposit(YIELD_ID, N, 0x101);
        vm.prank(OWNER);
        masp.emergencyUnwind(YIELD_ID);

        YieldIndex.YieldState memory st = masp.yieldState(YIELD_ID);
        assertEq(st.venue, address(venue), "venue still bound after unwind");
        assertTrue(st.halted, "halted instead");
        assertTrue(masp.isYieldAsset(YIELD_ID), "still an indexed asset");
    }

    function test_setHalted_resumesFundingTheSameVault() public {
        _deposit(YIELD_ID, N, 0x101);
        vm.prank(OWNER);
        masp.emergencyUnwind(YIELD_ID);
        assertEq(vault.balanceOf(address(venue)), 0, "position closed");

        vm.prank(OWNER);
        masp.setHalted(YIELD_ID, false);
        masp.rebalance(YIELD_ID);
        assertGt(vault.balanceOf(address(venue)), 0, "re-supplied to the one bound vault");
    }

    /// A draw leaves the buffer replenished, not empty. Otherwise the first
    /// withdrawal to exceed the buffer would leave `idle` at zero and every
    /// later withdrawal, however small, would also reach the venue.
    function test_venueDraw_refillsTheBuffer() public {
        _deposit(YIELD_ID, N, 0x101);
        // Larger than the 5% buffer, so the venue must be drawn on.
        _withdraw(YIELD_ID, N / 4, 0x7001);

        uint256 g = _gross(YIELD_ID);
        assertApproxEqRel(_idle(YIELD_ID), (g * BUFFER_BPS) / 10_000, 1e16, "buffer restored in the same draw");
    }

    /// Funding is banded: a deposit supplies the venue only once idle reaches
    /// twice the target, then brings it back down to the target. The band keeps
    /// the ERC-4626 mint off the common deposit path.
    function test_funding_isBandedNotPerDeposit() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 shares = vault.balanceOf(address(venue));

        // A deposit far too small to cross the band leaves the venue untouched.
        _deposit(YIELD_ID, 1_000, 0x501);
        assertEq(vault.balanceOf(address(venue)), shares, "small deposit does not touch the venue");
        assertGt(_idle(YIELD_ID), (_gross(YIELD_ID) * BUFFER_BPS) / 10_000, "it accumulates as idle instead");
    }

    /// A vault at its deposit cap takes only what fits. The supply is clamped to
    /// `maxDeposit` and the rest stays idle, rather than the ERC-4626 deposit
    /// reverting and taking the shield with it.
    function test_deposit_capacityCappedVenueKeepsExcessIdle() public {
        uint256 room = 1_000 * SCALE;
        vault.setDepositCap(room);

        _deposit(YIELD_ID, N, 0x101);

        uint256 g = _gross(YIELD_ID);
        assertEq(vault.convertToAssets(vault.balanceOf(address(venue))), room, "venue filled to its cap");
        assertEq(_idle(YIELD_ID), g - room, "the excess stays idle");
        assertGt(_idle(YIELD_ID), (g * BUFFER_BPS) / 10_000, "above the buffer target");
        assertEq(token.balanceOf(address(masp)), _idle(YIELD_ID), "idle is exactly what the pool holds");
    }

    /// A paused vault (`maxDeposit == 0`) is skipped: the shield lands with
    /// everything idle, and the next `rebalance` after the vault reopens
    /// supplies it.
    function test_deposit_pausedVenueStillAcceptsShield() public {
        vault.setDepositCap(0);

        (uint256 id,) = _deposit(YIELD_ID, N, 0x101);

        assertTrue(masp.escrowed(id) != bytes32(0), "shield escrowed");
        assertEq(vault.balanceOf(address(venue)), 0, "nothing supplied to the paused vault");
        assertEq(_idle(YIELD_ID), _gross(YIELD_ID), "everything idle");

        vault.setDepositCap(type(uint256).max);
        masp.rebalance(YIELD_ID);
        assertEq(_idle(YIELD_ID), (_gross(YIELD_ID) * BUFFER_BPS) / 10_000, "rebalance supplies it once reopened");
    }

    /// `idle` is credited with what the venue delivered, not with what the pool
    /// asked for. A vault with an exit fee that still covers the withdrawal's
    /// shortfall lets it through, and the fee comes out of the refill: `idle`
    /// stays equal to the pool's balance, so nothing is paid from another id's
    /// share of the ERC-20.
    function test_venueDraw_creditsMeasuredDelivery() public {
        _deposit(YIELD_ID, N, 0x101);
        assertEq(token.balanceOf(address(masp)), _idle(YIELD_ID), "books match before the draw");
        vault.setWithdrawHaircut(1_000);

        // Larger than the 5% buffer, so the venue must be drawn on.
        _withdraw(YIELD_ID, N / 4, 0x7001);

        assertEq(token.balanceOf(address(masp)), _idle(YIELD_ID), "idle credits the delivery, not the request");
    }

    /// A venue that delivers less than the withdrawal's shortfall reverts the
    /// spend, as a drained one does, instead of paying the difference out of
    /// balances held for other ids.
    function test_revert_VenueUnderDelivered_drawShortOfTheNeed() public {
        _deposit(YIELD_ID, N, 0x101);
        _deposit(PLAIN_ID, N, 0x201);
        vault.setWithdrawHaircut(1_000 * SCALE * 100);

        vm.expectPartialRevert(YieldOps.VenueUnderDelivered.selector);
        this.attemptWithdraw(YIELD_ID, N / 4, 0x7002);
        assertFalse(masp.spent(bytes32(uint256(0x7002))), "nullifier untouched by the reverted spend");
    }

    /// An unwind from a vault with an exit fee credits what arrived. It does not
    /// revert, since it is the recovery path; the fee reads as a venue loss.
    function test_emergencyUnwind_creditsMeasuredRecovery() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 haircut = 1_000;
        vault.setWithdrawHaircut(haircut);
        uint256 position = vault.convertToAssets(vault.balanceOf(address(venue)));

        vm.prank(OWNER);
        uint256 recovered = masp.emergencyUnwind(YIELD_ID);

        assertEq(recovered, position - haircut, "reports the delivery");
        assertEq(token.balanceOf(address(masp)), _idle(YIELD_ID), "idle is exactly what the pool holds");
    }

    /// `rebalance` targets the buffer exactly, so calling it twice does not
    /// oscillate: the second call is a no-op.
    function test_rebalance_isIdempotent() public {
        _deposit(YIELD_ID, N, 0x101);
        _deposit(YIELD_ID, 1_000, 0x501);

        masp.rebalance(YIELD_ID);
        uint256 idleAfterFirst = _idle(YIELD_ID);
        uint256 sharesAfterFirst = vault.balanceOf(address(venue));

        masp.rebalance(YIELD_ID);
        assertEq(_idle(YIELD_ID), idleAfterFirst, "idle unchanged by a second rebalance");
        assertEq(vault.balanceOf(address(venue)), sharesAfterFirst, "and so is the position");
    }

    // ============== Zero backing ============================================

    /// Loses everything the asset holds while units are outstanding: a zero
    /// buffer keeps nothing idle, and the venue's vault is wiped.
    function _wipeBacking() internal {
        vault.lose(vault.totalAssetsHeld());
        assertEq(_idle(YIELD_ID), 0, "nothing idle");
        assertEq(_gross(YIELD_ID), 0, "nothing backs the units");
        assertGt(_supply(YIELD_ID), 0, "units still outstanding");
    }

    function _unbufferedDeposit() internal returns (uint256 id) {
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, 0, PERF_BPS);
        (id,) = _deposit(YIELD_ID, N, 0x101);
    }

    /// A shield against zero backing would price every unit at zero and mint
    /// units for free against any later recovery.
    function test_revert_NoBacking_depositAtZeroGross() public {
        _unbufferedDeposit();
        _wipeBacking();

        vm.expectRevert(abi.encodeWithSelector(YieldOps.NoBacking.selector, YIELD_ID));
        this.attemptDeposit(YIELD_ID, N, 0x301);
    }

    /// An unshield against zero backing would burn the note's claim for
    /// nothing, forfeiting its share of any recovery.
    function test_revert_NoBacking_withdrawAtZeroGross() public {
        _unbufferedDeposit();
        _wipeBacking();

        vm.expectRevert(abi.encodeWithSelector(YieldOps.NoBacking.selector, YIELD_ID));
        this.attemptWithdraw(YIELD_ID, N / 2, 0x6666);
        assertFalse(masp.spent(bytes32(uint256(0x6666))), "nullifier untouched by the reverted spend");
    }

    /// A cancel against zero backing would burn the escrow's units and refund
    /// nothing; it is refused and the escrow survives until the asset is backed.
    function test_revert_NoBacking_cancelAtZeroGross() public {
        uint32 submittedAt = uint32(vm.getBlockNumber());
        uint256 id = _unbufferedDeposit();
        _wipeBacking();
        vm.roll(block.number + 7_201);

        vm.expectRevert(abi.encodeWithSelector(YieldOps.NoBacking.selector, YIELD_ID));
        this.attemptCancel(id, N, 0x101, submittedAt);
        assertTrue(masp.escrowed(id) != bytes32(0), "escrow survives the refused cancel");
    }

    /// External so `vm.expectRevert` has a call boundary to catch.
    function attemptDeposit(uint64 id, uint64 publicIn, uint256 seed) external {
        _deposit(id, publicIn, seed);
    }

    /// External so `vm.expectRevert` has a call boundary to catch.
    function attemptCancel(uint256 id, uint64 publicIn, uint256 seed, uint32 submittedAt) external {
        masp.cancelDeposit(
            id,
            uint48(publicIn),
            bytes32(seed),
            [uint256(0), 0],
            YIELD_ID,
            FEE_BPS,
            payer,
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(seed + 1), feeCvDep: [uint256(0), 0] })
        );
    }

    // ============== Immutability =============================================

    /// The binding is permanent because the registry is add-only and there is
    /// no `setVenue`.
    function test_venueBindingIsImmutable() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.DuplicateAsset.selector, YIELD_ID));
        masp.addYieldAsset(
            YIELD_ID, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(venue), BUFFER_BPS, PERF_BPS
        );
    }

    /// A venue pinned to some other pool cannot be bound here.
    function test_addYieldAsset_rejectsUnpinnedVenue() public {
        ERC4626VenueStub bad = new ERC4626VenueStub(address(0xdead), address(vault));
        vm.prank(OWNER);
        vm.expectRevert(YieldOps.VenueNotPinned.selector);
        masp.addYieldAsset(77, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(bad), BUFFER_BPS, PERF_BPS);
    }

    /// A venue already backing one id cannot back another. Both ids would count
    /// its whole position in `gross`, so a deposit into one would raise the
    /// other's index.
    function test_revert_VenueAlreadyBound_secondIdSameVenue() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(YieldOps.VenueAlreadyBound.selector, address(venue)));
        masp.addYieldAsset(77, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(venue), BUFFER_BPS, PERF_BPS);

        assertFalse(masp.isYieldAsset(77), "nothing bound");
        // The registry write reverted with the binding.
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(77)));
        masp.asset(77);
    }

    // ============== Isolation ================================================

    /// Two ids over one ERC-20: the plain id is ordinary custody and is
    /// untouched by anything the venue does.
    function test_plainIdIsUnaffectedByTheYieldId() public {
        _deposit(PLAIN_ID, N, 0x201);

        _deposit(YIELD_ID, N, 0x301);
        _earn(1_000 * SCALE);
        vault.lose(500 * SCALE);

        assertFalse(masp.isYieldAsset(PLAIN_ID), "plain id carries no venue");
        uint256 before = token.balanceOf(RECIPIENT);
        _withdraw(PLAIN_ID, N, 0x4444);
        uint256 paid = token.balanceOf(RECIPIENT) - before;
        uint256 outAmt = uint256(N) * SCALE;
        assertEq(paid, outAmt - (outAmt * FEE_BPS) / 10_000, "flat-rate payout, unmoved by the venue");
    }

    /// A donation to the pool cannot move the index, because `idle` is tracked
    /// rather than read from `balanceOf`; this also lets two ids share a token.
    function test_donationToPoolCannotMoveTheIndex() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 idxBefore = masp.index(YIELD_ID);
        token.mint(address(masp), 10_000 * SCALE);
        assertEq(masp.index(YIELD_ID), idxBefore, "index is blind to unattributed balance");
    }

    /// A donation to the *venue* is indistinguishable from interest and is
    /// treated as such.
    function test_donationToVenueIsTreatedAsYield() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 idxBefore = masp.index(YIELD_ID);
        _earn(1_000 * SCALE);
        assertGt(masp.index(YIELD_ID), idxBefore, "venue growth reaches holders");
    }

    // ============== Withdraw-only retirement =================================

    /// `setAssetDisabled` stops new deposits and nothing else. `transfer` in
    /// particular must keep working, or a holder cannot decompose an odd note
    /// into ladder denominations before exiting.
    function test_disabledYieldAsset_blocksDepositsButNotExits() public {
        _deposit(YIELD_ID, N, 0x101);
        vm.prank(OWNER);
        masp.setAssetDisabled(YIELD_ID, true);

        token.mint(payer, type(uint128).max);
        _allow(type(uint160).max);
        PubInputs.DepositRequest memory d = _request(YIELD_ID, N, 0, 0x401);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetDisabled.selector, YIELD_ID));
        masp.depositAuthorized(d, SpendFixture.validAux()[0], SpendFixture.validAux()[1]);

        uint256 before = token.balanceOf(RECIPIENT);
        _withdraw(YIELD_ID, N / 2, 0x5555);
        assertGt(token.balanceOf(RECIPIENT) - before, 0, "holders can still exit");
    }
}

/// A venue that answers `POOL`/`VAULT` but is pinned elsewhere.
contract ERC4626VenueStub {
    address public immutable POOL;
    address public immutable VAULT;

    constructor(address pool, address vault) {
        POOL = pool;
        VAULT = vault;
    }
}
