// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { VerifierStorage } from "../../src/VerifierStorage.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { MockTreeUpdateVerifier } from "../mocks/MockTreeUpdateVerifier.sol";
import { MockPoolV1 } from "../mocks/MockPool.sol";

/// Replacing a verifier, end to end.
///
/// A verifier decides what the pool accepts as a valid proof, so a swap carries
/// the same authority as an implementation upgrade and is held to the same
/// window. These tests pin that equivalence: the delay, the pause deferral, the
/// permissionless commit, and the fact that nothing lands early.
///
/// Warps use absolute timestamps: under `via_ir` the optimizer may cache
/// `block.timestamp`, which `vm.warp` invalidates.
contract VerifierUpdateTest is Test {
    uint256 internal constant UPGRADE_DELAY = 30 days;
    uint256 internal constant MAX_PAUSE = 7 days;
    uint256 internal constant T0 = 1_000_000;

    DelayedUpgradeProxy internal proxy;
    MockPoolV1 internal v1;

    MockTreeUpdateVerifier internal tubOld;
    MockBatchVerifier internal spendOld;
    MockTreeUpdateVerifier internal tubNew;
    MockBatchVerifier internal spendNew;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(T0);
        v1 = new MockPoolV1();
        tubOld = new MockTreeUpdateVerifier(true);
        spendOld = new MockBatchVerifier();
        tubNew = new MockTreeUpdateVerifier(true);
        spendNew = new MockBatchVerifier();

        proxy = new DelayedUpgradeProxy(
            address(v1), abi.encodeCall(MockPoolV1.initialize, (100)), admin, UPGRADE_DELAY, MAX_PAUSE
        );

        _seedLivePair(address(tubOld), address(spendOld));
    }

    /// The pool's `initialize` seeds the live pair in production; this proxy is
    /// over a mock pool, so the namespace is written directly. `$()` would
    /// resolve against the test contract's own storage, so the slots are
    /// addressed on the proxy.
    function _seedLivePair(address tub, address spend) internal {
        vm.store(address(proxy), VerifierStorage.SLOT, bytes32(uint256(uint160(tub))));
        vm.store(address(proxy), bytes32(uint256(VerifierStorage.SLOT) + 1), bytes32(uint256(uint160(spend))));
    }

    function _queue() internal {
        vm.prank(admin);
        proxy.queueVerifierUpdate(address(tubNew), address(spendNew));
    }

    function _live() internal view returns (address, address) {
        return proxy.verifiers();
    }

    // ============== The window ===============================================

    function test_queuedPairDoesNotVerifyUntilItsWindowElapses() public {
        _queue();

        (address tub, address spend) = _live();
        assertEq(tub, address(tubOld), "tree-update verifier swapped at queue");
        assertEq(spend, address(spendOld), "spend verifier swapped at queue");

        vm.warp(T0 + UPGRADE_DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(DelayedUpgradeProxy.VerifierUpdateNotDue.selector, T0 + UPGRADE_DELAY));
        proxy.commitVerifierUpdate();

        vm.warp(T0 + UPGRADE_DELAY);
        proxy.commitVerifierUpdate();

        (tub, spend) = _live();
        assertEq(tub, address(tubNew), "tree-update verifier not promoted");
        assertEq(spend, address(spendNew), "spend verifier not promoted");
    }

    /// The window is the proxy's own `UPGRADE_DELAY`, the same one an
    /// implementation upgrade gets. A verifier swap is the same power, so it
    /// must not be the faster route.
    function test_windowIsExactlyTheUpgradeWindow() public {
        _queue();
        (,, uint256 notBefore) = proxy.pendingVerifierUpdate();
        assertEq(notBefore, block.timestamp + proxy.UPGRADE_DELAY(), "verifier window differs from the upgrade window");
    }

    /// Commit is permissionless once the window has run, like `activateUpgrade`:
    /// the pair is fixed, public and has been cancellable throughout.
    function test_anyoneMayCommitOnceDue() public {
        _queue();
        vm.warp(T0 + UPGRADE_DELAY);

        vm.prank(stranger);
        proxy.commitVerifierUpdate();

        (address tub,) = _live();
        assertEq(tub, address(tubNew));
    }

    // ============== Pauses do not consume the window =========================

    /// A pause defers the commit by its own duration, exactly as it defers a
    /// pending activation. Paused time is not notice: a holder who cannot exit
    /// has not been given the chance to.
    function test_pauseDefersTheCommitByItsDuration() public {
        _queue();

        vm.warp(T0 + 1 days);
        vm.prank(admin);
        proxy.pauseSpends(5 days);

        (,, uint256 notBefore) = proxy.pendingVerifierUpdate();
        assertEq(notBefore, T0 + UPGRADE_DELAY + 5 days, "pause did not defer the commit");

        vm.warp(T0 + UPGRADE_DELAY);
        vm.expectRevert();
        proxy.commitVerifierUpdate();

        vm.warp(T0 + UPGRADE_DELAY + 5 days);
        proxy.commitVerifierUpdate();
        (address tub,) = _live();
        assertEq(tub, address(tubNew));
    }

    /// A pause already running when the pair is queued defers it by the
    /// remainder, matching `queueUpgrade`. An expired pause defers nothing.
    function test_queueUnderARunningPauseStartsWhenSpendsReopen() public {
        vm.prank(admin);
        proxy.pauseSpends(5 days);

        vm.warp(T0 + 1 days);
        _queue();

        (,, uint256 notBefore) = proxy.pendingVerifierUpdate();
        assertEq(notBefore, T0 + 5 days + UPGRADE_DELAY, "window did not start when spends reopen");
    }

    function test_expiredPauseDefersNothing() public {
        vm.prank(admin);
        proxy.pauseSpends(5 days);

        vm.warp(T0 + 6 days);
        _queue();

        (,, uint256 notBefore) = proxy.pendingVerifierUpdate();
        assertEq(notBefore, T0 + 6 days + UPGRADE_DELAY, "an expired pause deferred the window");
    }

    // ============== Queue discipline =========================================

    /// One queued pair at a time, as for upgrades. Replacing it takes
    /// cancel-then-queue, which restarts the window, so a pair cannot inherit
    /// the elapsed part of another's notice.
    function test_onlyOnePairMayBeQueued() public {
        _queue();
        vm.prank(admin);
        vm.expectRevert(DelayedUpgradeProxy.VerifierUpdatePending.selector);
        proxy.queueVerifierUpdate(address(tubOld), address(spendOld));
    }

    function test_cancelRestartsTheNoticeForTheNextPair() public {
        _queue();
        vm.warp(T0 + 20 days);

        vm.prank(admin);
        proxy.cancelVerifierUpdate();
        (,, uint256 cleared) = proxy.pendingVerifierUpdate();
        assertEq(cleared, 0, "cancel left a pending pair");

        vm.prank(admin);
        proxy.queueVerifierUpdate(address(tubNew), address(spendNew));
        (,, uint256 notBefore) = proxy.pendingVerifierUpdate();
        assertEq(notBefore, T0 + 20 days + UPGRADE_DELAY, "the new pair inherited the old notice");
    }

    function test_cancelWithNothingQueuedReverts() public {
        vm.prank(admin);
        vm.expectRevert(DelayedUpgradeProxy.NoPendingVerifierUpdate.selector);
        proxy.cancelVerifierUpdate();
    }

    function test_commitWithNothingQueuedReverts() public {
        vm.expectRevert(DelayedUpgradeProxy.NoPendingVerifierUpdate.selector);
        proxy.commitVerifierUpdate();
    }

    /// A committed pair is consumed, so the commit cannot be replayed to
    /// reinstall it over a later one.
    function test_commitIsNotReplayable() public {
        _queue();
        vm.warp(T0 + UPGRADE_DELAY);
        proxy.commitVerifierUpdate();

        vm.expectRevert(DelayedUpgradeProxy.NoPendingVerifierUpdate.selector);
        proxy.commitVerifierUpdate();
    }

    // ============== Validation ===============================================

    function test_queueRejectsAnAddressWithNoCode() public {
        vm.startPrank(admin);
        vm.expectRevert(VerifierStorage.ZeroVerifier.selector);
        proxy.queueVerifierUpdate(makeAddr("notAContract"), address(spendNew));

        vm.expectRevert(VerifierStorage.ZeroVerifier.selector);
        proxy.queueVerifierUpdate(address(tubNew), address(0));
        vm.stopPrank();
    }

    /// The spend verifier is probed at queue rather than at commit: the address
    /// is fixed for the window, so a wrong one fails the proposal that queued it
    /// instead of the permissionless call that lands it.
    function test_queueRejectsASpendVerifierThatDoesNotAnswerVerifyBatch() public {
        vm.prank(admin);
        vm.expectRevert(VerifierStorage.BadSpendVerifier.selector);
        // A contract with code that has no `verifyBatch`.
        proxy.queueVerifierUpdate(address(tubNew), address(tubNew));
    }

    // ============== Access control ===========================================

    function test_onlyAdminMayQueueOrCancel() public {
        vm.startPrank(stranger);
        vm.expectRevert(DelayedUpgradeProxy.NotProxyAdmin.selector);
        proxy.queueVerifierUpdate(address(tubNew), address(spendNew));
        vm.expectRevert(DelayedUpgradeProxy.NotProxyAdmin.selector);
        proxy.cancelVerifierUpdate();
        vm.stopPrank();
    }
}
