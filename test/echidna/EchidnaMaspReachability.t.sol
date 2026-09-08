// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { EchidnaMasp } from "./EchidnaMasp.sol";

/// Reachability gate for the Echidna handlers, run by `forge test`.
///
/// Echidna reports a property as passing whether it held across a thousand
/// real state transitions or across a thousand calls that all reverted on
/// entry. `MaspFlowInvariantTest.test_handlerReachesEveryPath` exists because
/// exactly that happened to the Foundry suite: `flushOne` built a one-leaf
/// batch, `_validateBatchHeader` rejected it, and with reverts tolerated the
/// call rolled back leaving no trace — so `invariant_rootCoherence` spent its
/// whole life comparing 0 to 0.
///
/// The Echidna suite is more exposed to that failure than the Foundry one,
/// not less: its handlers were rewritten around hevm's cheatcode set, and
/// `cancelOne` deliberately leaves the `cancelDelay` guard live, so an
/// unreachable cancel path looks identical to a correctly-guarded one from
/// the outside. This drives each handler directly and asserts it changed
/// state, which a fuzzer cannot do for itself.
///
/// It is not a substitute for the Echidna run — it proves the paths are
/// reachable, not that the properties hold across sequences.
contract EchidnaMaspReachabilityTest is Test {
    EchidnaMasp internal target;

    function setUp() public {
        target = new EchidnaMasp();
    }

    function test_handlersReachEveryPath() public {
        // --- submit ---
        target.submit(100, 7);
        target.submit(200, 9);
        assertEq(target.submitCount(), 2, "submit path");
        assertGt(target.token().balanceOf(address(target.masp())), 0, "pool took custody");

        // --- flush ---
        target.flushOne(0);
        assertEq(target.flushCount(), 1, "flush path");
        // Not merely "a flush landed": it must have inserted the principal
        // *and* the relayer note. A one-leaf flush is the bug this exists for.
        assertEq(target.masp().committedCount(), 2, "flush inserted both leaves");
        assertGt(target.masp().accruedFee(IERC20(address(target.token()))), 0, "flush accrued the fee");

        // --- cancel ---
        // The remaining deposit is still inside its cancel window, so the
        // guard must reject it. Asserting the rejection pins that `cancelOne`
        // is gated by real timing rather than by an early return.
        vm.expectRevert();
        target.cancelOne(0);
        assertEq(target.cancelCount(), 0, "cancel rejected inside the window");

        vm.roll(block.number + target.masp().cancelDelay());
        target.cancelOne(0);
        assertEq(target.cancelCount(), 1, "cancel path");

        // --- withdraw ---
        // The flush above left shielded principal behind, which is what bounds
        // `withdrawOne`. Without it the handler returns early and the five
        // withdraw properties would hold vacuously.
        target.withdrawOne(50, 0x2000);
        assertEq(target.withdrawCount(), 1, "withdraw path");
        assertGt(target.token().balanceOf(address(0xbe11e)), 0, "recipient credited");
        assertTrue(target.echidna_recipientCredited(), "recipient credit matches ghost");
        assertTrue(target.echidna_withdrawFeeSplitExact(), "fee split exact");
        assertTrue(target.echidna_spentNullifiersStaySpent(), "nullifiers stay spent");

        // Both negative withdraw handlers must reach their call and be
        // rejected by it. An attempt counter that stays at zero means the
        // guard was never put to the question.
        target.withdrawReplay(0, 50, 0x3000);
        assertEq(target.nullifierReuseAttempts(), 1, "replay reached the pool");
        assertTrue(target.echidna_noNullifierReuse(), "double spend rejected");

        target.withdrawUnknownRoot(50, 0x4000, 12345);
        assertEq(target.unknownRootAttempts(), 1, "unknown-root attempt reached the pool");
        assertTrue(target.echidna_unknownRootRejected(), "unknown root rejected");

        // --- root ring size ---
        // `EchidnaMasp.ROOT_HISTORY` mirrors an `internal constant` that
        // cannot be read across the contract boundary. Pin the two: the last
        // in-range slot must read, and one past it must not. Without this a
        // change to the ring size would leave the eviction properties quietly
        // inspecting the wrong slot and passing.
        // `masp` is hoisted because `vm.expectRevert` arms the *next* call,
        // and `target.masp()` is itself one — leaving it inline would arm the
        // getter, which does not revert.
        MASP pool = target.masp();
        pool.roots(63);
        vm.expectRevert();
        pool.roots(64);

        // --- sweep ---
        target.sweep();
        assertEq(target.masp().accruedFee(IERC20(address(target.token()))), 0, "sweep path");

        // Every property must still hold after a full lap of the state
        // machine — otherwise the Echidna run would be reporting on a
        // handler set that cannot even complete one.
        assertTrue(target.echidna_solvency(), "solvency");
        assertTrue(target.echidna_feeAccrualAccounted(), "fee accrual accounted");
        assertTrue(target.echidna_rootCoherence(), "root coherence");
        assertTrue(target.echidna_lifecycleExclusivity(), "lifecycle exclusivity");
        assertTrue(target.echidna_escrowMatchesLifecycle(), "escrow matches lifecycle");
        assertTrue(target.echidna_treasuryConservation(), "treasury conservation");
    }

    /// The shielded-transfer path, and the property that makes it worth
    /// having: a transfer consumes notes and advances the tree while moving no
    /// tokens at all.
    function test_transferReachesAndMovesNoTokens() public {
        target.submit(100, 7);
        target.flushOne(0);

        uint256 before = target.token().balanceOf(address(target.masp()));
        uint64 leavesBefore = target.masp().committedCount();

        target.transferShielded(0x9000);

        assertEq(target.transferCount(), 1, "transfer path");
        assertEq(target.token().balanceOf(address(target.masp())), before, "transfer moved tokens");
        assertGt(target.masp().committedCount(), leavesBefore, "transfer advanced the tree");
        assertTrue(target.echidna_transferMovesNoTokens(), "transfer moves no tokens");
        assertTrue(target.echidna_solvency(), "solvency across a transfer");
    }

    /// Multi-deposit batches, both the honest one and the one that names the
    /// same deposit twice. `flushOne` only ever builds a one-deposit batch, so
    /// without this the loop in `flushBatch` runs at n = 1 and nowhere else.
    function test_batchFlushPathsReach() public {
        target.submit(100, 7);
        target.submit(200, 9);
        target.submit(300, 11);

        // The duplicate must be rejected while a deposit is still pending;
        // run it first so a successful `flushMany` cannot be what rejects it.
        target.flushDuplicateId(0);
        assertEq(target.duplicateIdAttempts(), 1, "duplicate-id attempt reached the pool");
        assertTrue(target.echidna_noDuplicateIdInBatch(), "duplicate id rejected");

        target.flushMany(0);
        assertEq(target.batchFlushCount(), 1, "batch flush path");
        assertEq(target.flushCount(), 2, "batch flushed both deposits");
        assertEq(target.masp().committedCount(), 4, "batch inserted four leaves");
        assertTrue(target.echidna_solvency(), "solvency after a batch flush");
        assertTrue(target.echidna_lifecycleExclusivity(), "lifecycle after a batch flush");
    }

    /// Root-ring eviction. Transfers are used to advance the root because they
    /// need no funds and no pending deposit, so wrapping the ring costs one
    /// call per root instead of a deposit and a flush.
    function test_rootRingEvictionReaches() public {
        target.submit(100, 7);
        target.flushOne(0);

        // One past ROOT_HISTORY, so the buffer has wrapped and the oldest
        // entry has been displaced.
        for (uint256 i = 0; i < 65; i++) {
            target.transferShielded(0xa000 + i);
        }

        assertTrue(target.echidna_rootRingConsistent(), "ring and known-root map agree");
        assertTrue(target.echidna_evictedRootsUnknown(), "evicted roots are forgotten");

        target.withdrawEvictedRoot(1, 0xb000, 0);
        assertEq(target.evictedRootAttempts(), 1, "evicted-root attempt reached the pool");
        assertTrue(target.echidna_evictedRootRejected(), "evicted root rejected");
    }

    /// The guardian pause, and the asymmetry that is the point of it: spends
    /// and deposits stop, refunds do not.
    function test_pausePathsReach() public {
        target.submit(100, 7);
        target.submit(200, 9);
        target.submit(300, 11);
        target.flushOne(0);

        // Two must remain pending: `pauseSpends` refuses to trip over an
        // escrow too small to outlast its own window, since `cancelDeposit`
        // keeps draining it while `submit` is frozen.
        vm.roll(block.number + target.masp().cancelDelay());

        target.pauseSpends(600);
        assertGt(target.pausedUntil(), block.timestamp, "pause is live");

        target.pausedDepositRejected(150);
        assertEq(target.pausedDepositAttempts(), 1, "paused-deposit attempt ran");
        assertTrue(target.echidna_pauseBlocksDeposits(), "pause blocks deposits");

        target.pausedSpendRejected(0xc000);
        assertEq(target.pausedSpendAttempts(), 1, "paused-spend attempt ran");
        assertTrue(target.echidna_pauseBlocksSpends(), "pause blocks spends");

        // The one that matters: escrowed funds stay recoverable under a pause.
        target.pausedCancelHonoured(0);
        assertEq(target.pausedCancelAttempts(), 1, "paused-cancel attempt ran");
        assertEq(target.cancelCount(), 1, "cancel landed while paused");
        assertTrue(target.echidna_pauseCannotTrapFunds(), "pause cannot trap escrowed funds");

        // Sweep is excluded from the pause for the same reason as cancel.
        target.sweep();
        assertTrue(target.echidna_treasuryConservation(), "sweep works while paused");
    }
}
