// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";

import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";
import { MockPoolV1, MockPoolV2 } from "../mocks/MockPool.sol";

/// Symbolic proofs for the exit window.
///
/// A queued implementation cannot take effect for `UPGRADE_DELAY`, giving holders
/// time to exit under the rules they entered under. `DelayedUpgradeProxy` states
/// four properties this rests on; each is proved below over every timestamp,
/// duration and caller:
///
/// 1. The window cannot be shortened: `UPGRADE_DELAY` is immutable, and no call
///    activates before it elapses.
/// 2. Paused time does not consume the window: a pause defers a pending
///    activation by its own duration, an upgrade queued during a pause defers
///    its activation by the pause still to run, and the pause ceiling is shorter
///    than the window.
/// 3. Activation is permissionless, so closing the window needs no keeper.
/// 4. `cancelUpgrade` only withdraws; it never promotes.
///
/// An early activation would control every deposit in the pool. The logic is
/// comparisons over timestamps only, which the solver handles without difficulty.
/// Timestamps are `uint40` in storage, so symbolic timestamps are bounded to that
/// width.
///
/// `MockPoolV1` stands in as the implementation: the proxy's behaviour does not
/// depend on its delegate, and the real pool would add the spend path to every
/// explored path.
///
/// `svm.createCalldata` is not used against this contract: undeclared selectors
/// are forwarded to the implementation by `delegatecall`, so quantifying over
/// calldata would also quantify over the implementation's ABI. The admin surface
/// is enumerated instead.
contract DelayedUpgradeProxySymbolicTest is GuardAsserts {
    uint256 internal constant UPGRADE_DELAY = 30 days;
    uint256 internal constant MAX_PAUSE = 7 days;
    uint256 internal constant T0 = 1_000_000;

    DelayedUpgradeProxy internal proxy;
    MockPoolV1 internal v1;
    MockPoolV2 internal v2;

    address internal constant ADMIN = address(0xad814);

    function setUp() public {
        vm.warp(T0);
        v1 = new MockPoolV1();
        v2 = new MockPoolV2();
        proxy = new DelayedUpgradeProxy(
            address(v1), abi.encodeCall(MockPoolV1.initialize, (100)), ADMIN, UPGRADE_DELAY, MAX_PAUSE
        );
    }

    function _queue() internal {
        vm.prank(ADMIN);
        proxy.queueUpgrade(address(v2));
    }

    // --- (1) the window cannot be shortened --------------------------------

    /// Activation succeeds exactly when the window has elapsed, at every point
    /// in time.
    ///
    /// Both directions are proved: early activation is rejected (safety), and
    /// activation after the window succeeds (liveness), so a proxy that never
    /// activates cannot satisfy the proof.
    function check_activationHappensExactlyAfterTheWindow(uint40 t) public {
        _queue();
        (, uint256 activationAt) = proxy.pendingUpgrade();

        vm.assume(t >= T0);
        vm.warp(t);

        (bool ok,) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.activateUpgrade, ()));

        assertEq(ok, uint256(t) >= activationAt, "activation gated on the window alone");
        assertEq(proxy.implementation(), ok ? address(v2) : address(v1));
    }

    /// The served implementation does not change while an upgrade is queued, so
    /// holders exiting during the window transact against the code they entered
    /// under.
    function check_queuedUpgradeDoesNotChangeTheServedImplementation(uint40 t) public {
        _queue();
        (, uint256 activationAt) = proxy.pendingUpgrade();
        vm.assume(t >= T0 && uint256(t) < activationAt);

        vm.warp(t);

        assertEq(proxy.implementation(), address(v1));
    }

    /// One upgrade may be queued at a time: a second queue reverts without
    /// replacing the payload, so the window cannot be restarted with different
    /// code.
    function check_queuedPayloadCannotBeSwapped() public {
        _queue();
        (address pendingBefore, uint256 activationBefore) = proxy.pendingUpgrade();

        vm.prank(ADMIN);
        (bool ok, bytes memory ret) =
            address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.queueUpgrade, (address(v1))));

        _assertRejected(ok, ret, DelayedUpgradeProxy.UpgradePending.selector);

        (address pendingAfter, uint256 activationAfter) = proxy.pendingUpgrade();
        assertEq(pendingAfter, pendingBefore);
        assertEq(activationAfter, activationBefore);
    }

    /// An implementation with no code is refused, so activation cannot brick the
    /// proxy by pointing it at an empty address.
    function check_queueUpgrade_rejectsCodelessImplementation(address impl) public {
        vm.assume(impl.code.length == 0);

        vm.prank(ADMIN);
        (bool ok, bytes memory ret) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.queueUpgrade, (impl)));

        _assertRejected(ok, ret, DelayedUpgradeProxy.ImplementationHasNoCode.selector);
    }

    // --- (2) paused time does not consume the window ------------------------

    /// Pausing pushes activation back by exactly the pause duration, for every
    /// permitted duration.
    ///
    /// The window therefore measures unpaused time; otherwise an admin could pause
    /// spends and let the window expire while holders are unable to exit.
    function check_pauseDefersActivationByItsOwnDuration(uint40 duration) public {
        vm.assume(duration > 0 && uint256(duration) <= MAX_PAUSE);

        _queue();
        (, uint256 activationBefore) = proxy.pendingUpgrade();

        vm.prank(ADMIN);
        proxy.pauseSpends(duration);

        (, uint256 activationAfter) = proxy.pendingUpgrade();
        assertEq(activationAfter, activationBefore + uint256(duration), "window deferred by the pause");
        assertEq(proxy.spendsPausedUntil(), block.timestamp + uint256(duration));
    }

    /// The other ordering: an upgrade queued after a pause starts its window when
    /// the pause ends, for every permitted duration and every queue time.
    ///
    /// `pauseSpends` extends only a window that already exists, so a pause issued
    /// ahead of the queue is deferred here instead: activation moves back by the
    /// pause still to run at queue time, and by nothing once it has expired.
    /// Either way the window closes no earlier than `UPGRADE_DELAY` after spends
    /// reopen.
    function check_queueDuringPauseDefersActivationByTheRemainingPause(uint40 duration, uint40 t) public {
        vm.assume(duration > 0 && uint256(duration) <= MAX_PAUSE);
        // Keeps `activationAt` inside the `uint40` it is stored in.
        vm.assume(t >= T0 && uint256(t) + UPGRADE_DELAY <= type(uint40).max);

        vm.prank(ADMIN);
        proxy.pauseSpends(duration);
        uint256 pausedUntil = T0 + uint256(duration);
        assertEq(proxy.spendsPausedUntil(), pausedUntil);

        vm.warp(t);
        _queue();

        (, uint256 activationAt) = proxy.pendingUpgrade();
        uint256 remaining = uint256(t) < pausedUntil ? pausedUntil - uint256(t) : 0;
        assertEq(activationAt, uint256(t) + remaining + UPGRADE_DELAY, "window deferred by the remaining pause");
        assertGe(activationAt, pausedUntil + UPGRADE_DELAY, "window overlaps the pause");
    }

    /// The constructor accepts exactly the configurations whose pause ceiling is
    /// shorter than the window, for every non-zero delay and every ceiling.
    ///
    /// A pause as long as the window would hold spends shut for all of it, which
    /// property (2) cannot repair: it keeps paused time out of the window but
    /// still lets one pause stall exits for the window's length.
    function check_constructor_acceptsExactlyPauseShorterThanDelay(uint256 upgradeDelay, uint256 maxPause) public {
        // `ZeroDelay` and `DelayExceedsExitTermsNotice` are checked first; the
        // unit suite covers them.
        vm.assume(upgradeDelay > 0 && upgradeDelay <= ExitTerms.DELAY);

        (bool ok, bytes memory ret) = address(this).call(abi.encodeCall(this.deployProxy, (upgradeDelay, maxPause)));

        assertEq(ok, maxPause < upgradeDelay, "accepted exactly the pauses shorter than the window");
        if (ok) {
            DelayedUpgradeProxy p = DelayedUpgradeProxy(payable(abi.decode(ret, (address))));
            assertEq(p.UPGRADE_DELAY(), upgradeDelay);
            assertEq(p.MAX_PAUSE(), maxPause);
        } else {
            _assertRejected(ok, ret, DelayedUpgradeProxy.PauseNotShorterThanDelay.selector);
        }
    }

    /// Deploys a proxy with the given window and ceiling. External so a proof can
    /// observe a constructor revert through a low-level call.
    function deployProxy(uint256 upgradeDelay, uint256 maxPause) external returns (address) {
        return address(
            new DelayedUpgradeProxy(
                address(v1), abi.encodeCall(MockPoolV1.initialize, (100)), ADMIN, upgradeDelay, maxPause
            )
        );
    }

    /// A pause is accepted for exactly the permitted durations: non-zero and
    /// within the immutable ceiling, which bounds how long the guardian can hold
    /// spends closed.
    function check_pauseSpends_acceptsExactlyPermittedDurations(uint256 duration) public {
        vm.prank(ADMIN);
        (bool ok,) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.pauseSpends, (duration)));

        assertEq(ok, duration > 0 && duration <= MAX_PAUSE);
    }

    /// The guardian's pause is one-shot: a second pause is refused until
    /// governance clears the flag, so pauses cannot be chained into an
    /// indefinite halt.
    function check_guardianPauseIsOneShotUntilReset(uint40 first, uint40 second) public {
        vm.assume(first > 0 && uint256(first) <= MAX_PAUSE);
        vm.assume(second > 0 && uint256(second) <= MAX_PAUSE);

        vm.startPrank(ADMIN);
        proxy.pauseSpends(first);

        (bool again, bytes memory ret) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.pauseSpends, (second)));
        _assertRejected(again, ret, DelayedUpgradeProxy.GuardianPauseAlreadyUsed.selector, "second pause refused");

        // Clearing the flag re-arms the guardian pause.
        proxy.resetGuardianPause();
        (bool afterReset,) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.pauseSpends, (second)));
        vm.stopPrank();

        assertTrue(afterReset, "reset re-arms the guardian");
    }

    // --- (3) activation is permissionless -----------------------------------

    /// Anyone may activate once the window has elapsed, so no privileged keeper is
    /// required. This affects liveness only: the payload is fixed at queue time and
    /// public throughout the window.
    function check_activationIsPermissionless(address caller) public {
        _queue();
        (, uint256 activationAt) = proxy.pendingUpgrade();
        vm.warp(activationAt);

        vm.prank(caller);
        (bool ok,) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.activateUpgrade, ()));

        assertTrue(ok, "any caller may activate");
        assertEq(proxy.implementation(), address(v2));
    }

    // --- (4) cancel only withdraws ------------------------------------------

    /// Cancelling clears the queue without changing the served implementation.
    /// Afterwards activation reverts at every later time, so a cancelled upgrade
    /// cannot take effect by waiting.
    function check_cancelWithdrawsAndNeverPromotes(uint40 t) public {
        _queue();

        vm.prank(ADMIN);
        proxy.cancelUpgrade();

        (address pending, uint256 activationAt) = proxy.pendingUpgrade();
        assertEq(pending, address(0));
        assertEq(activationAt, 0);
        assertEq(proxy.implementation(), address(v1));

        vm.assume(t >= T0);
        vm.warp(t);
        (bool ok, bytes memory ret) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.activateUpgrade, ()));

        _assertRejected(ok, ret, DelayedUpgradeProxy.NoPendingUpgrade.selector, "nothing to activate at any later time");
        assertEq(proxy.implementation(), address(v1));
    }

    // --- administration ------------------------------------------------------

    /// Every privileged entry point rejects every non-admin caller, and none of
    /// them moves the implementation or the queue.
    ///
    /// Enumerated rather than quantified over calldata: undeclared selectors are
    /// forwarded to the implementation, so `svm.createCalldata` would exercise
    /// `MockPoolV1` rather than the proxy.
    function check_privilegedEntryPointsRejectNonAdmins(address caller, uint256 duration) public {
        vm.assume(caller != ADMIN);

        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeCall(DelayedUpgradeProxy.queueUpgrade, (address(v2)));
        calls[1] = abi.encodeCall(DelayedUpgradeProxy.cancelUpgrade, ());
        calls[2] = abi.encodeCall(DelayedUpgradeProxy.pauseSpends, (duration));
        calls[3] = abi.encodeCall(DelayedUpgradeProxy.resetGuardianPause, ());
        calls[4] = abi.encodeCall(DelayedUpgradeProxy.changeProxyAdmin, (caller));

        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(proxy).call(calls[i]);
            _assertRejected(ok, ret, DelayedUpgradeProxy.NotProxyAdmin.selector, "non-admin rejected");
        }

        assertEq(proxy.implementation(), address(v1));
        assertEq(proxy.proxyAdmin(), ADMIN);
        (address pending,) = proxy.pendingUpgrade();
        assertEq(pending, address(0));
    }

    /// Administration transfers to any non-zero address; zero is refused because
    /// it would leave the proxy permanently without an admin.
    function check_changeProxyAdmin_acceptsExactlyNonZero(address newAdmin) public {
        vm.prank(ADMIN);
        (bool ok,) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.changeProxyAdmin, (newAdmin)));

        assertEq(ok, newAdmin != address(0));
        assertEq(proxy.proxyAdmin(), newAdmin == address(0) ? ADMIN : newAdmin);
    }
}
