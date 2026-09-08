// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";

import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { MockPoolV1, MockPoolV2 } from "../mocks/MockPool.sol";

/// Symbolic proofs for the exit window.
///
/// The proxy's promise is that a queued implementation cannot take effect for
/// `UPGRADE_DELAY`, giving holders time to leave under the rules they entered
/// under. `DelayedUpgradeProxy` states the four properties that guarantee rests
/// on; each is proved below over every timestamp, duration and caller rather
/// than at the sampled points a scenario test visits:
///
/// 1. The window cannot be shortened — `UPGRADE_DELAY` is immutable, and no
///    call activates before it elapses.
/// 2. A pause defers activation by its own duration, so paused time does not
///    consume the window.
/// 3. Activation is permissionless, so the window closing needs no keeper.
/// 4. `cancelUpgrade` only withdraws; it never promotes.
///
/// This is the surface where a bug is worth the most to an attacker — an
/// implementation that activates early owns every deposit in the pool — and it
/// is all comparisons and timestamps, with no arithmetic a solver struggles
/// with. Timestamps are `uint40` in storage; the proofs bound the symbolic ones
/// to that width, since a wider value cannot be written in the first place.
///
/// A lightweight implementation (`MockPoolV1`) sits behind the proxy on
/// purpose: the proxy's behaviour does not depend on what it delegates to, and
/// the real pool would drag the whole spend path into every path explored here.
///
/// Note that `svm.createCalldata` is unusable against this contract: any
/// selector the proxy does not declare is forwarded to the implementation by
/// `delegatecall`, so quantifying over calldata quantifies over the
/// implementation's ABI too. The admin surface is enumerated instead.
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
    /// Both directions are proved. Rejecting early activation is the security
    /// half; succeeding once the window has passed is the liveness half, and
    /// without it a proxy that never activated anything would satisfy the
    /// security half trivially.
    function check_activationHappensExactlyAfterTheWindow(uint40 t) public {
        _queue();
        (, uint256 activationAt) = proxy.pendingUpgrade();

        vm.assume(t >= T0);
        vm.warp(t);

        (bool ok,) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.activateUpgrade, ()));

        assertEq(ok, uint256(t) >= activationAt, "activation gated on the window alone");
        assertEq(proxy.implementation(), ok ? address(v2) : address(v1));
    }

    /// The implementation the proxy serves does not change while an upgrade is
    /// merely queued, however long it sits there. Holders exiting during the
    /// window transact against the code they entered under.
    function check_queuedUpgradeDoesNotChangeTheServedImplementation(uint40 t) public {
        _queue();
        (, uint256 activationAt) = proxy.pendingUpgrade();
        vm.assume(t >= T0 && uint256(t) < activationAt);

        vm.warp(t);

        assertEq(proxy.implementation(), address(v1));
    }

    /// One upgrade may be queued at a time: a second queue reverts rather than
    /// replacing the payload, so the window cannot be restarted with different
    /// code while the first is still counting down.
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

    /// An implementation with no code is refused, so a queue cannot brick the
    /// proxy by activating into an empty address.
    function check_queueUpgrade_rejectsCodelessImplementation(address impl) public {
        vm.assume(impl.code.length == 0);

        vm.prank(ADMIN);
        (bool ok, bytes memory ret) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.queueUpgrade, (impl)));

        _assertRejected(ok, ret, DelayedUpgradeProxy.ImplementationHasNoCode.selector);
    }

    // --- (2) a pause defers activation by its own duration ------------------

    /// Pausing pushes activation back by exactly the pause duration, for every
    /// permitted duration.
    ///
    /// This is what makes the window measure *unpaused* time. Without it, an
    /// admin could pause spends for the length of the window and let it expire
    /// while holders were unable to leave — the exit window would be nominal.
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

    /// A pause is accepted for exactly the permitted durations: non-zero and
    /// within the immutable ceiling. The ceiling is what bounds how long the
    /// guardian can hold spends closed.
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

        // Governance clearing the flag re-arms it, and nothing else does.
        proxy.resetGuardianPause();
        (bool afterReset,) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.pauseSpends, (second)));
        vm.stopPrank();

        assertTrue(afterReset, "reset re-arms the guardian");
    }

    // --- (3) activation is permissionless -----------------------------------

    /// Anyone may activate once the window has elapsed, so closing it depends on
    /// no privileged keeper. Liveness only: the payload was fixed at queue time
    /// and public throughout.
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

    /// Cancelling clears the queue and leaves the served implementation alone —
    /// it can never promote. Afterwards there is nothing to activate, so a
    /// cancelled upgrade cannot be resurrected by waiting.
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
    /// Enumerated rather than quantified over calldata: an undeclared selector
    /// is forwarded to the implementation, so `svm.createCalldata` here would be
    /// a proof about `MockPoolV1`, not about the proxy.
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

    /// Administration transfers to any non-zero address and refuses zero, which
    /// would leave the proxy permanently unadministered.
    function check_changeProxyAdmin_acceptsExactlyNonZero(address newAdmin) public {
        vm.prank(ADMIN);
        (bool ok,) = address(proxy).call(abi.encodeCall(DelayedUpgradeProxy.changeProxyAdmin, (newAdmin)));

        assertEq(ok, newAdmin != address(0));
        assertEq(proxy.proxyAdmin(), newAdmin == address(0) ? ADMIN : newAdmin);
    }
}
