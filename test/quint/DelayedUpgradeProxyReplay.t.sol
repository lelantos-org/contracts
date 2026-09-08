// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { MockPoolV1, MockPoolV2 } from "../mocks/MockPool.sol";

import { DelayedUpgradeProxySpec } from "./generated/DelayedUpgradeProxySpec.sol";
import { DelayedUpgradeProxySpecReplay } from "./generated/DelayedUpgradeProxySpecReplay.sol";

/// Driver for [spec/delayed_upgrade_proxy.qnt](../../spec/delayed_upgrade_proxy.qnt).
///
/// The cheapest rig of any spec here: two mock implementations and a proxy, no
/// tokens, no permit2, no verifiers. It is the same shape as
/// [test/upgrade/DelayedUpgradeProxy.t.sol](../upgrade/DelayedUpgradeProxy.t.sol)'s
/// `setUp`, which is scenario-driven where this replays a checked model.
///
/// `abstract` so Foundry does not collect it as a test contract; the generated
/// `DelayedUpgradeProxyTraces` inherits it and holds one test per trace.
abstract contract DelayedUpgradeProxyReplay is DelayedUpgradeProxySpecReplay {
    /// Must match the spec's constants; `setUp` asserts the proxy agrees.
    uint256 internal constant UPGRADE_DELAY = 30 days;
    uint256 internal constant MAX_PAUSE = 7 days;
    uint16 internal constant WITHDRAW_BPS = 100;

    /// Absolute base for every warp. The model counts seconds from zero and the
    /// driver adds them to this.
    uint256 internal constant T0 = 1_000_000;

    DelayedUpgradeProxy internal proxy;
    MockPoolV1 internal v1;
    MockPoolV2 internal v2;

    /// Index-addressed so `changeProxyAdmin` is a model pick rather than an
    /// address the model has to carry.
    address[3] internal admins;

    function setUp() public virtual {
        vm.warp(T0);

        v1 = new MockPoolV1();
        v2 = new MockPoolV2();
        admins = [makeAddr("adminA"), makeAddr("adminB"), makeAddr("adminC")];

        proxy = new DelayedUpgradeProxy(
            address(v1), abi.encodeCall(MockPoolV1.initialize, (WITHDRAW_BPS)), admins[0], UPGRADE_DELAY, MAX_PAUSE
        );

        // Two copies of each constant exist - the spec's and this file's. The
        // pool's is the third, and the only one nothing else would catch.
        assertEq(proxy.UPGRADE_DELAY(), UPGRADE_DELAY, "spec and proxy disagree on UPGRADE_DELAY");
        assertEq(proxy.MAX_PAUSE(), MAX_PAUSE, "spec and proxy disagree on MAX_PAUSE");
        assertEq(block.timestamp, T0, "spec `init` fixes nowTs = 0");
    }

    // --- the switch -------------------------------------------------------

    function apply_(DelayedUpgradeProxySpec.Action action, DelayedUpgradeProxySpec.Picks memory picks)
        external
        override
    {
        require(msg.sender == address(this), "self-call only");
        address admin = admins[_adminIndex()];

        if (action == DelayedUpgradeProxySpec.Action.QueueUpgrade) {
            vm.prank(admin);
            proxy.queueUpgrade(_implOf(picks.impl));
        } else if (action == DelayedUpgradeProxySpec.Action.CancelUpgrade) {
            vm.prank(admin);
            proxy.cancelUpgrade();
        } else if (action == DelayedUpgradeProxySpec.Action.ActivateUpgrade) {
            // Permissionless on purpose: driven from an address that is not the
            // admin, so a guard added here would surface immediately.
            vm.prank(makeAddr("anyone"));
            proxy.activateUpgrade();
        } else if (action == DelayedUpgradeProxySpec.Action.ActivateTooEarly) {
            // The revert carries the deadline, and asserting the argument is
            // what makes a contract reporting the wrong one diverge.
            (, uint256 activationAt) = proxy.pendingUpgrade();
            vm.expectRevert(abi.encodeWithSelector(DelayedUpgradeProxy.NotYetActivatable.selector, activationAt));
            proxy.activateUpgrade();
        } else if (action == DelayedUpgradeProxySpec.Action.PauseSpends) {
            vm.prank(admin);
            proxy.pauseSpends(picks.dt);
        } else if (action == DelayedUpgradeProxySpec.Action.ResetGuardianPause) {
            vm.prank(admin);
            proxy.resetGuardianPause();
        } else if (action == DelayedUpgradeProxySpec.Action.ChangeProxyAdmin) {
            vm.prank(admin);
            proxy.changeProxyAdmin(admins[picks.who]);
        } else if (action == DelayedUpgradeProxySpec.Action.AdvanceTime) {
            // Absolute, from an accumulator, rather than
            // `vm.warp(block.timestamp + dt)`.
            //
            // A relative warp does in fact work *here*: `apply_` is reached
            // through an external self-call, so its `block.timestamp` is read
            // fresh in that frame and the via_ir caching that
            // test/upgrade/DelayedUpgradeProxy.t.sol warns about does not
            // apply. Tested: switching this line to the relative form leaves
            // all eight traces green.
            //
            // It stays absolute anyway, because the accumulator makes the
            // driver's clock a function of the model's own `dt` picks rather
            // than of wherever the chain happened to be. A warp that was
            // skipped, applied twice, or reordered then shows up as `nowTs`
            // rather than silently agreeing.
            //
            // The caching hazard is real, but it lands on the *read* side - see
            // `_project`, which is inlined into the replay loop.
            elapsed += picks.dt;
            vm.warp(T0 + elapsed);
        } else {
            revert("unhandled action");
        }
    }

    /// Model seconds since T0, maintained so every warp can be absolute.
    uint256 internal elapsed;

    /// See `_project`: an uncacheable read of the clock.
    function quintNow() external view returns (uint256) {
        return block.timestamp;
    }

    // --- projection -------------------------------------------------------

    function _project() internal view override returns (DelayedUpgradeProxySpec.State memory s) {
        // Through an external call, deliberately. `_project` is inlined into
        // the replay loop, and under `via_ir` the optimizer caches
        // `block.timestamp` across it - it cannot know a cheatcode moved the
        // clock mid-frame. So a plain `block.timestamp` here reads T0 on every
        // step however many times `advanceTime` warped, and every trace
        // diverges on `nowTs` at the first jump. A staticcall cannot be cached.
        //
        // test/upgrade/DelayedUpgradeProxy.t.sol records this hazard for warps;
        // in a replay driver the warp is safe (it happens inside an external
        // call frame) and the *read* is what bites.
        s.nowTs = this.quintNow() - T0;

        (address pending, uint256 activationAt) = proxy.pendingUpgrade();
        s.pendingImpl = _implIndex(pending);
        s.activationAt = activationAt == 0 ? 0 : activationAt - T0;

        uint256 until = proxy.spendsPausedUntil();
        s.pausedUntil = until == 0 ? 0 : until - T0;
        s.guardianPauseUsed = proxy.guardianPauseUsed();

        // A live delegatecall through the proxy. This is the field that makes
        // an activation which cleared the queue without actually upgrading
        // visible; everything else would still agree.
        s.implVersion = MockPoolV1(address(proxy)).version();

        s.admin = _adminIndex();
    }

    // --- reverse maps -----------------------------------------------------
    //
    // The model addresses implementations and admins by index. Each reverse map
    // is driver-local bookkeeping, so each fails by name rather than letting an
    // unmapped address arrive at the comparison dressed as a divergence.

    function _implOf(uint256 v) private view returns (address) {
        if (v == 1) return address(v1);
        if (v == 2) return address(v2);
        revert("driver: implementation index outside the spec's domain");
    }

    function _implIndex(address a) private view returns (uint256) {
        if (a == address(0)) return 0;
        if (a == address(v1)) return 1;
        if (a == address(v2)) return 2;
        revert("driver: proxy holds an implementation the spec never chose");
    }

    function _adminIndex() private view returns (uint256) {
        address a = proxy.proxyAdmin();
        for (uint256 i = 0; i < admins.length; i++) {
            if (admins[i] == a) return i;
        }
        revert("driver: proxy admin is outside the spec's address set");
    }
}
