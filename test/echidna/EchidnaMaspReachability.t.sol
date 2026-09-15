// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { EchidnaMasp } from "./EchidnaMasp.sol";

/// Reachability gate for the Echidna handlers, run by `forge test`.
///
/// Echidna reports a property as passing whether it held across real state
/// transitions or across calls that all reverted on entry. A handler whose call
/// always reverts (for example, a flush with a malformed batch header) leaves
/// the properties holding vacuously. `MaspFlowInvariantTest.test_handlerReachesEveryPath`
/// guards the Foundry suite against the same failure.
///
/// The Echidna handlers are built around hevm's cheatcode set, and `cancelOne`
/// leaves the `cancelDelay` guard live, so an unreachable cancel path is
/// externally indistinguishable from a correctly guarded one. This test drives
/// each handler directly and asserts it changed state.
///
/// It proves the paths are reachable, not that the properties hold across
/// sequences; it does not replace the Echidna run.
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
        // The flush must insert both the principal and the relayer note leaf.
        assertEq(target.masp().committedCount(), 2, "flush inserted both leaves");
        assertGt(target.masp().accruedFee(IERC20(address(target.token()))), 0, "flush accrued the fee");

        // --- cancel ---
        // The remaining deposit is inside its cancel window, so the guard must
        // reject it. Asserting the revert shows `cancelOne` is gated by timing
        // rather than by an early return.
        vm.expectRevert();
        target.cancelOne(0);
        assertEq(target.cancelCount(), 0, "cancel rejected inside the window");

        vm.roll(block.number + target.masp().cancelDelay());
        target.cancelOne(0);
        assertEq(target.cancelCount(), 1, "cancel path");

        // --- withdraw ---
        // The flush above left shielded principal, which bounds `withdrawOne`.
        // Without it the handler returns early and the withdraw properties
        // hold vacuously.
        target.withdrawOne(50, 0x2000);
        assertEq(target.withdrawCount(), 1, "withdraw path");
        assertGt(target.token().balanceOf(address(0xbe11e)), 0, "recipient credited");
        assertTrue(target.echidna_recipientCredited(), "recipient credit matches ghost");
        assertTrue(target.echidna_withdrawFeeSplitExact(), "fee split exact");
        assertTrue(target.echidna_spentNullifiersStaySpent(), "nullifiers stay spent");

        // Both negative withdraw handlers must reach the pool and be rejected.
        // An attempt counter at zero means the guard was never exercised.
        target.withdrawReplay(0, 50, 0x3000);
        assertEq(target.nullifierReuseAttempts(), 1, "replay reached the pool");
        assertTrue(target.echidna_noNullifierReuse(), "double spend rejected");

        target.withdrawUnknownRoot(50, 0x4000, 12345);
        assertEq(target.unknownRootAttempts(), 1, "unknown-root attempt reached the pool");
        assertTrue(target.echidna_unknownRootRejected(), "unknown root rejected");

        // --- root ring size ---
        // `EchidnaMasp.ROOT_HISTORY` mirrors an `internal constant` that
        // cannot be read across the contract boundary. The last in-range slot
        // must read and one past it must not, so a ring-size change fails here
        // instead of leaving the eviction properties on the wrong slot.
        // `masp` is hoisted because `vm.expectRevert` applies to the next call,
        // and `target.masp()` is itself a call that does not revert.
        MASP pool = target.masp();
        pool.roots(63);
        vm.expectRevert();
        pool.roots(64);

        // --- sweep ---
        target.sweep();
        assertEq(target.masp().accruedFee(IERC20(address(target.token()))), 0, "sweep path");

        // Every property must hold after a full lap of the state machine.
        assertTrue(target.echidna_solvency(), "solvency");
        assertTrue(target.echidna_feeAccrualAccounted(), "fee accrual accounted");
        assertTrue(target.echidna_rootCoherence(), "root coherence");
        assertTrue(target.echidna_lifecycleExclusivity(), "lifecycle exclusivity");
        assertTrue(target.echidna_escrowMatchesLifecycle(), "escrow matches lifecycle");
        assertTrue(target.echidna_treasuryConservation(), "treasury conservation");
    }

    /// The shielded-transfer path: a transfer consumes notes and advances the
    /// tree while moving no tokens.
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

    /// Multi-deposit batches: the honest one and the one naming the same
    /// deposit twice. Covers the `flushBatch` loop at n > 1, which `flushOne`
    /// does not reach.
    function test_batchFlushPathsReach() public {
        target.submit(100, 7);
        target.submit(200, 9);
        target.submit(300, 11);

        // Runs before `flushMany` so the duplicate is rejected while its
        // deposit is still pending, not because it was already flushed.
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

    /// Root-ring eviction. Transfers advance the root because they need no
    /// funds and no pending deposit, so wrapping the ring takes one call per
    /// root.
    function test_rootRingEvictionReaches() public {
        target.submit(100, 7);
        target.flushOne(0);

        // ROOT_HISTORY + 1 advances, so the buffer wraps and displaces the
        // oldest entries.
        for (uint256 i = 0; i < 65; i++) {
            target.transferShielded(0xa000 + i);
        }

        assertTrue(target.echidna_rootRingConsistent(), "ring and known-root map agree");
        assertTrue(target.echidna_evictedRootsUnknown(), "evicted roots are forgotten");

        target.withdrawEvictedRoot(1, 0xb000, 0);
        assertEq(target.evictedRootAttempts(), 1, "evicted-root attempt reached the pool");
        assertTrue(target.echidna_evictedRootRejected(), "evicted root rejected");
    }

    /// The guardian pause: spends and deposits stop, refunds do not.
    function test_pausePathsReach() public {
        target.submit(100, 7);
        target.submit(200, 9);
        target.submit(300, 11);
        target.flushOne(0);

        // Two deposits remain pending, as `pauseSpends` requires; the roll puts
        // them past their cancel delay.
        vm.roll(block.number + target.masp().cancelDelay());

        target.pauseSpends(600);
        assertGt(target.pausedUntil(), block.timestamp, "pause is live");

        target.pausedDepositRejected(150);
        assertEq(target.pausedDepositAttempts(), 1, "paused-deposit attempt ran");
        assertTrue(target.echidna_pauseBlocksDeposits(), "pause blocks deposits");

        target.pausedSpendRejected(0xc000);
        assertEq(target.pausedSpendAttempts(), 1, "paused-spend attempt ran");
        assertTrue(target.echidna_pauseBlocksSpends(), "pause blocks spends");

        // Escrowed funds stay recoverable under a pause.
        target.pausedCancelHonoured(0);
        assertEq(target.pausedCancelAttempts(), 1, "paused-cancel attempt ran");
        assertEq(target.cancelCount(), 1, "cancel landed while paused");
        assertTrue(target.echidna_pauseCannotTrapFunds(), "pause cannot trap escrowed funds");

        // Sweep is excluded from the pause for the same reason as cancel.
        target.sweep();
        assertTrue(target.echidna_treasuryConservation(), "sweep works while paused");
    }
}
