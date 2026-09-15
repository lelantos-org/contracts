// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";
import { MockPoolV1, MockPoolV2, SelectorProbe } from "../mocks/MockPool.sol";

/// The exit window, end to end.
///
/// Most of this file drives one scenario: an upgrade that changes withdrawal
/// terms is queued, and a holder exits under the terms in force beforehand.
///
/// Warps use absolute timestamps: under `via_ir` the optimizer may cache
/// `block.timestamp`, which `vm.warp` invalidates.
contract DelayedUpgradeProxyTest is Test {
    uint256 internal constant UPGRADE_DELAY = 30 days;
    uint256 internal constant MAX_PAUSE = 7 days;
    uint16 internal constant WITHDRAW_BPS = 100; // 1%
    uint256 internal constant T0 = 1_000_000;

    DelayedUpgradeProxy internal proxy;
    MockPoolV1 internal v1;
    MockPoolV2 internal v2;

    address internal admin = makeAddr("admin");
    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");

    /// The pool as seen through the proxy.
    MockPoolV1 internal pool;

    function setUp() public {
        vm.warp(T0);
        v1 = new MockPoolV1();
        v2 = new MockPoolV2();
        proxy = new DelayedUpgradeProxy(
            address(v1), abi.encodeCall(MockPoolV1.initialize, (WITHDRAW_BPS)), admin, UPGRADE_DELAY, MAX_PAUSE
        );
        pool = MockPoolV1(address(proxy));

        vm.prank(holder);
        pool.deposit(1_000e18);
    }

    function _queue() internal {
        vm.prank(admin);
        proxy.queueUpgrade(address(v2));
    }

    // ============== The window ===============================================

    function test_initialStateRunsV1() public view {
        assertEq(pool.version(), 1);
        assertEq(proxy.implementation(), address(v1));
        assertEq(pool.balanceOf(holder), 1_000e18);
    }

    /// A queued upgrade changes no behaviour until it activates.
    function test_queuedUpgradeDoesNotTakeEffect() public {
        _queue();
        assertEq(pool.version(), 1, "queueing must not switch implementation");
        assertEq(proxy.implementation(), address(v1));

        (address pending, uint256 activationAt) = proxy.pendingUpgrade();
        assertEq(pending, address(v2));
        assertEq(activationAt, T0 + UPGRADE_DELAY);
    }

    /// A holder exits mid-window under the terms in force at entry. The queued
    /// implementation would take half the withdrawal; the current one takes 1%.
    function test_holderCanExitUnderOldRulesMidWindow() public {
        _queue();
        vm.warp(T0 + UPGRADE_DELAY - 1);

        vm.prank(holder);
        uint256 net = pool.withdraw(1_000e18);

        assertEq(net, 1_000e18 - 10e18, "exit was not priced under the old rules");
        assertEq(pool.version(), 1, "current implementation serves until activation");
        assertEq(pool.balanceOf(holder), 0);
    }

    /// The current implementation serves every call for the duration of the
    /// window, not only withdrawals.
    function test_oldImplementationServesTheWholeWindow() public {
        _queue();
        uint256[5] memory checkpoints =
            [T0 + 1, T0 + 1 days, T0 + 15 days, T0 + UPGRADE_DELAY - 2, T0 + UPGRADE_DELAY - 1];
        for (uint256 i = 0; i < checkpoints.length; ++i) {
            vm.warp(checkpoints[i]);
            assertEq(pool.version(), 1, "implementation switched inside the window");
            vm.prank(stranger);
            pool.deposit(1);
        }
    }

    function test_activateRevertsBeforeTheWindowElapses() public {
        _queue();
        vm.warp(T0 + UPGRADE_DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(DelayedUpgradeProxy.NotYetActivatable.selector, T0 + UPGRADE_DELAY));
        proxy.activateUpgrade();
    }

    /// Permissionless, so activation depends on no keeper.
    function test_anyoneMayActivateOnceTheWindowElapses() public {
        _queue();
        vm.warp(T0 + UPGRADE_DELAY);

        vm.prank(stranger);
        proxy.activateUpgrade();

        assertEq(pool.version(), 2);
        assertEq(proxy.implementation(), address(v2));
        (address pending, uint256 activationAt) = proxy.pendingUpgrade();
        assertEq(pending, address(0), "pending not cleared");
        assertEq(activationAt, 0);
    }

    /// An upgrade preserves the pool's balances, totals and configuration.
    function test_stateSurvivesTheUpgrade() public {
        vm.prank(stranger);
        pool.deposit(500e18);
        uint256 totalBefore = pool.totalDeposited();

        _queue();
        vm.warp(T0 + UPGRADE_DELAY);
        proxy.activateUpgrade();

        assertEq(pool.version(), 2, "upgrade did not land");
        assertEq(pool.totalDeposited(), totalBefore, "total lost across upgrade");
        assertEq(pool.balanceOf(holder), 1_000e18, "holder balance lost");
        assertEq(pool.balanceOf(stranger), 500e18);
        assertEq(pool.withdrawBps(), WITHDRAW_BPS, "config lost");
    }

    /// After activation the new terms apply.
    function test_newRulesApplyAfterActivation() public {
        _queue();
        vm.warp(T0 + UPGRADE_DELAY);
        proxy.activateUpgrade();

        vm.prank(holder);
        uint256 net = pool.withdraw(1_000e18);
        assertEq(net, 500e18, "new withdrawal terms did not take effect");
    }

    // ============== Cancel ===================================================

    function test_cancelClearsThePendingUpgrade() public {
        _queue();
        vm.prank(admin);
        proxy.cancelUpgrade();

        (address pending,) = proxy.pendingUpgrade();
        assertEq(pending, address(0));

        vm.warp(T0 + UPGRADE_DELAY + 1);
        vm.expectRevert(DelayedUpgradeProxy.NoPendingUpgrade.selector);
        proxy.activateUpgrade();
        assertEq(pool.version(), 1);
    }

    /// Replacing a queued implementation in place would swap the payload without
    /// restarting the window.
    function test_cannotQueueOverAPendingUpgrade() public {
        _queue();
        vm.prank(admin);
        vm.expectRevert(DelayedUpgradeProxy.UpgradePending.selector);
        proxy.queueUpgrade(address(v1));
    }

    /// Re-queueing after a cancel restarts the full window.
    function test_requeueRestartsTheFullWindow() public {
        _queue();
        vm.warp(T0 + 20 days);
        vm.prank(admin);
        proxy.cancelUpgrade();
        vm.prank(admin);
        proxy.queueUpgrade(address(v2));

        (, uint256 activationAt) = proxy.pendingUpgrade();
        assertEq(activationAt, T0 + 20 days + UPGRADE_DELAY, "window did not restart");
    }

    // ============== Pause ====================================================

    /// A pause defers activation by exactly its own duration, so the window
    /// measures unpaused time.
    function test_pauseExtendsTheWindowByItsDuration() public {
        _queue();
        vm.warp(T0 + 1 days);

        vm.prank(admin);
        proxy.pauseSpends(5 days);

        (, uint256 activationAt) = proxy.pendingUpgrade();
        assertEq(activationAt, T0 + UPGRADE_DELAY + 5 days, "window not extended by the pause");
        assertEq(proxy.spendsPausedUntil(), T0 + 1 days + 5 days);
    }

    function test_activationStillBlockedAcrossAnExtendedWindow() public {
        _queue();
        vm.warp(T0 + 1 days);
        vm.prank(admin);
        proxy.pauseSpends(5 days);

        // What would have been the original activation moment.
        vm.warp(T0 + UPGRADE_DELAY);
        vm.expectRevert();
        proxy.activateUpgrade();

        vm.warp(T0 + UPGRADE_DELAY + 5 days);
        proxy.activateUpgrade();
        assertEq(pool.version(), 2);
    }

    /// The guardian cannot chain pauses into an indefinite freeze.
    function test_guardianPauseIsOneShot() public {
        vm.prank(admin);
        proxy.pauseSpends(1 days);
        assertTrue(proxy.guardianPauseUsed());

        vm.prank(admin);
        vm.expectRevert(DelayedUpgradeProxy.GuardianPauseAlreadyUsed.selector);
        proxy.pauseSpends(1 days);
    }

    function test_governanceCanReArmThePause() public {
        vm.prank(admin);
        proxy.pauseSpends(1 days);
        vm.prank(admin);
        proxy.resetGuardianPause();
        assertFalse(proxy.guardianPauseUsed());

        vm.prank(admin);
        proxy.pauseSpends(1 days);
    }

    function test_pauseIsBounded() public {
        vm.startPrank(admin);
        vm.expectRevert(DelayedUpgradeProxy.PauseTooLong.selector);
        proxy.pauseSpends(MAX_PAUSE + 1);
        vm.expectRevert(DelayedUpgradeProxy.PauseTooLong.selector);
        proxy.pauseSpends(0);
        vm.stopPrank();
    }

    /// A pause with nothing queued does not set an activation time. What it has
    /// not yet run is charged to the next queue instead, which starts its window
    /// when the pause ends; see `test_queueDuringAPauseStartsTheWindowWhenThePauseEnds`.
    function test_pauseWithNoPendingUpgradeDoesNotSetActivation() public {
        vm.prank(admin);
        proxy.pauseSpends(1 days);
        (address pending, uint256 activationAt) = proxy.pendingUpgrade();
        assertEq(pending, address(0));
        assertEq(activationAt, 0);
    }

    // ============== Queueing while paused ====================================

    /// An upgrade queued while spends are paused starts its window when the pause
    /// ends. `pauseSpends` extends only a window that already exists, so without
    /// this a pause issued ahead of the queue would run inside the new window and
    /// shorten the holders' exit by its remaining duration.
    ///
    /// Queued mid-pause rather than in the pausing block, so the deferral is the
    /// remaining pause and not the pause as issued.
    function test_queueDuringAPauseStartsTheWindowWhenThePauseEnds() public {
        vm.prank(admin);
        proxy.pauseSpends(MAX_PAUSE);
        vm.warp(T0 + 2 days);
        _queue();

        (, uint256 activationAt) = proxy.pendingUpgrade();
        uint256 pausedUntil = proxy.spendsPausedUntil();
        assertEq(pausedUntil, T0 + MAX_PAUSE);
        assertEq(activationAt - pausedUntil, UPGRADE_DELAY, "paused time came out of the exit window");

        // Where the window would have closed had it started at the queue.
        vm.warp(T0 + 2 days + UPGRADE_DELAY);
        vm.expectRevert(abi.encodeWithSelector(DelayedUpgradeProxy.NotYetActivatable.selector, activationAt));
        proxy.activateUpgrade();

        vm.warp(T0 + MAX_PAUSE + UPGRADE_DELAY);
        proxy.activateUpgrade();
        assertEq(pool.version(), 2);
    }

    /// Cancelling and re-queueing inside a pause restarts the window from the end
    /// of the pause, not from the re-queue. The cancel discards the extension the
    /// pause gave the first window, and the pause cannot be issued again to
    /// restore it, so the re-queue must carry it.
    function test_cancelAndRequeueDuringAPauseKeepsTheFullWindow() public {
        _queue();
        vm.warp(T0 + 1 days);
        vm.prank(admin);
        proxy.pauseSpends(MAX_PAUSE);

        vm.warp(T0 + 3 days);
        vm.startPrank(admin);
        proxy.cancelUpgrade();
        proxy.queueUpgrade(address(v2));
        vm.stopPrank();

        (, uint256 activationAt) = proxy.pendingUpgrade();
        uint256 pausedUntil = proxy.spendsPausedUntil();
        assertEq(pausedUntil, T0 + 1 days + MAX_PAUSE);
        assertEq(activationAt - pausedUntil, UPGRADE_DELAY, "re-queue mid-pause shortened the exit window");
    }

    /// A pause that has already run out defers nothing: the window starts at the
    /// queue, as it does with no pause at all.
    function test_queueAfterThePauseExpiredStartsNow() public {
        vm.prank(admin);
        proxy.pauseSpends(1 days);
        vm.warp(T0 + 2 days);
        _queue();

        (, uint256 activationAt) = proxy.pendingUpgrade();
        assertEq(activationAt, T0 + 2 days + UPGRADE_DELAY, "an expired pause deferred the window");
    }

    /// A pause at least as long as the window is refused at construction. Paused
    /// time does not consume the window, but a single pause that long would still
    /// hold spends shut for as long as the window itself. Equal and longer are
    /// both refused; one second shorter is accepted.
    function test_revert_PauseNotShorterThanDelay() public {
        bytes memory init = abi.encodeCall(MockPoolV1.initialize, (WITHDRAW_BPS));

        vm.expectRevert(DelayedUpgradeProxy.PauseNotShorterThanDelay.selector);
        new DelayedUpgradeProxy(address(v1), init, admin, UPGRADE_DELAY, UPGRADE_DELAY);

        // The configuration `Deploy.s.sol` once admitted: a 30-day pause over a
        // 7-day window.
        vm.expectRevert(DelayedUpgradeProxy.PauseNotShorterThanDelay.selector);
        new DelayedUpgradeProxy(address(v1), init, admin, 7 days, 30 days);

        DelayedUpgradeProxy tight = new DelayedUpgradeProxy(address(v1), init, admin, UPGRADE_DELAY, UPGRADE_DELAY - 1);
        assertEq(tight.MAX_PAUSE(), UPGRADE_DELAY - 1);
    }

    // ============== Access control ===========================================

    function test_onlyAdminMayQueueCancelOrPause() public {
        vm.startPrank(stranger);
        vm.expectRevert(DelayedUpgradeProxy.NotProxyAdmin.selector);
        proxy.queueUpgrade(address(v2));
        vm.expectRevert(DelayedUpgradeProxy.NotProxyAdmin.selector);
        proxy.cancelUpgrade();
        vm.expectRevert(DelayedUpgradeProxy.NotProxyAdmin.selector);
        proxy.pauseSpends(1 days);
        vm.expectRevert(DelayedUpgradeProxy.NotProxyAdmin.selector);
        proxy.resetGuardianPause();
        vm.stopPrank();
    }

    function test_queueRejectsAnImplementationWithNoCode() public {
        vm.prank(admin);
        vm.expectRevert(DelayedUpgradeProxy.ImplementationHasNoCode.selector);
        proxy.queueUpgrade(makeAddr("notAContract"));
    }

    /// `ProtocolAdmin` holds the pool as an immutable and cannot precede the
    /// proxy, so administration is handed over after deployment.
    function test_adminCanHandOverAdministration() public {
        address governance = makeAddr("governance");

        vm.prank(admin);
        proxy.changeProxyAdmin(governance);
        assertEq(proxy.proxyAdmin(), governance);

        // The previous admin is rejected.
        vm.prank(admin);
        vm.expectRevert(DelayedUpgradeProxy.NotProxyAdmin.selector);
        proxy.queueUpgrade(address(v2));

        // The new admin is accepted.
        vm.prank(governance);
        proxy.queueUpgrade(address(v2));
        (address pending,) = proxy.pendingUpgrade();
        assertEq(pending, address(v2));
    }

    function test_onlyAdminMayHandOverAdministration() public {
        vm.prank(stranger);
        vm.expectRevert(DelayedUpgradeProxy.NotProxyAdmin.selector);
        proxy.changeProxyAdmin(stranger);
    }

    /// Zero would strand the pool on its current implementation.
    function test_adminHandoverRejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(DelayedUpgradeProxy.ZeroAdmin.selector);
        proxy.changeProxyAdmin(address(0));
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(DelayedUpgradeProxy.ZeroAdmin.selector);
        new DelayedUpgradeProxy(
            address(v1), abi.encodeCall(MockPoolV1.initialize, (WITHDRAW_BPS)), address(0), UPGRADE_DELAY, MAX_PAUSE
        );
    }

    /// The window may not outlast the pool's exit-term notice, or a raise queued
    /// alongside an upgrade could land before the upgrade activates.
    function test_revert_DelayExceedsExitTermsNotice() public {
        bytes memory init = abi.encodeCall(MockPoolV1.initialize, (WITHDRAW_BPS));

        vm.expectRevert(DelayedUpgradeProxy.DelayExceedsExitTermsNotice.selector);
        new DelayedUpgradeProxy(address(v1), init, admin, ExitTerms.DELAY + 1, MAX_PAUSE);

        DelayedUpgradeProxy atNotice = new DelayedUpgradeProxy(address(v1), init, admin, ExitTerms.DELAY, MAX_PAUSE);
        assertEq(atNotice.UPGRADE_DELAY(), ExitTerms.DELAY);
    }

    function test_constructorRejectsZeroDelay() public {
        vm.expectRevert(DelayedUpgradeProxy.ZeroDelay.selector);
        new DelayedUpgradeProxy(address(v1), abi.encodeCall(MockPoolV1.initialize, (WITHDRAW_BPS)), admin, 0, MAX_PAUSE);
    }

    // ============== The guarantee itself =====================================

    /// No reachable function changes `UPGRADE_DELAY`. Asserted by calling
    /// plausible setter signatures through the proxy rather than by inspection.
    function test_noCodePathCanShortenTheUpgradeDelay() public {
        assertEq(proxy.UPGRADE_DELAY(), UPGRADE_DELAY);

        string[6] memory sigs = [
            "setUpgradeDelay(uint256)",
            "setDelay(uint256)",
            "updateDelay(uint256)",
            "setUPGRADE_DELAY(uint256)",
            "changeUpgradeDelay(uint256)",
            "setMaxPause(uint256)"
        ];
        for (uint256 i = 0; i < sigs.length; ++i) {
            vm.prank(admin);
            (bool ok,) = address(proxy).call(abi.encodeWithSignature(sigs[i], uint256(1)));
            // No such function on the proxy; it falls through to the mock pool,
            // which has no such function either.
            assertFalse(ok, string.concat("unexpected setter reachable: ", sigs[i]));
        }
        assertEq(proxy.UPGRADE_DELAY(), UPGRADE_DELAY, "delay changed");
    }

    /// Reserved selectors never reach the implementation, so a collision would
    /// make a pool function permanently unreachable.
    function test_reservedSelectorsDoNotCollideWithTheImplementation() public pure {
        bytes4[10] memory reserved = [
            DelayedUpgradeProxy.changeProxyAdmin.selector,
            DelayedUpgradeProxy.queueUpgrade.selector,
            DelayedUpgradeProxy.cancelUpgrade.selector,
            DelayedUpgradeProxy.activateUpgrade.selector,
            DelayedUpgradeProxy.pauseSpends.selector,
            DelayedUpgradeProxy.resetGuardianPause.selector,
            DelayedUpgradeProxy.implementation.selector,
            DelayedUpgradeProxy.proxyAdmin.selector,
            DelayedUpgradeProxy.pendingUpgrade.selector,
            DelayedUpgradeProxy.spendsPausedUntil.selector
        ];
        bytes4[6] memory implSelectors = [
            MockPoolV1.initialize.selector,
            MockPoolV1.version.selector,
            MockPoolV1.deposit.selector,
            MockPoolV1.withdraw.selector,
            // Public getters have no `.selector`; derive them.
            bytes4(keccak256("balanceOf(address)")),
            bytes4(keccak256("totalDeposited()"))
        ];
        for (uint256 i = 0; i < reserved.length; ++i) {
            for (uint256 j = 0; j < implSelectors.length; ++j) {
                assertTrue(reserved[i] != implSelectors[j], "reserved selector shadows an implementation function");
            }
        }
    }

    /// Confirms the collision check detects an actual collision.
    function test_collisionCheckWouldCatchARealCollision() public pure {
        assertEq(
            SelectorProbe.activateUpgrade.selector,
            DelayedUpgradeProxy.activateUpgrade.selector,
            "probe should collide by construction"
        );
    }
}
