// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { MASP } from "../../src/MASP.sol";
import { ProtocolAdmin } from "../../src/governance/ProtocolAdmin.sol";
import { TEST_PROXY_ADMIN } from "../utils/PoolDeployer.sol";

import { GovTestBase } from "./GovTestBase.sol";

/// `migrateAdmin` is the only path for ownership, and the pool's proxy admin, to
/// leave `ProtocolAdmin`. These tests cover a successful migration and each guard
/// individually.
///
/// The guards prevent mistakes, not a hostile proposal: a malicious successor can
/// return arbitrary values from these getters. That case is bounded by the
/// timelock delay and the guardian's veto, asserted in `Timelock.roles.t.sol`.
contract ProtocolAdminMigrateTest is GovTestBase {
    function _newAdmin(address pool_, address wrapper_, address admin_) internal returns (ProtocolAdmin) {
        return new ProtocolAdmin(pool_, wrapper_, admin_, guardian);
    }

    function _migrate(address target, string memory desc) internal {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(protocolAdmin), abi.encodeCall(ProtocolAdmin.migrateAdmin, (target)));
        _passProposal(t, v, c, desc);
    }

    function _migrateExpectingRevert(address target, string memory desc) internal {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(protocolAdmin), abi.encodeCall(ProtocolAdmin.migrateAdmin, (target)));
        _queueToEta(t, v, c, desc);
        vm.expectRevert();
        governor.execute(t, v, c, keccak256(bytes(desc)));
    }

    // ============== Successful migration =====================================

    /// Both contracts move in one call, so they cannot end up under different
    /// owners.
    function test_migratesBothPoolAndWrapperAtomically() public {
        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(timelock));
        _migrate(address(next), "migrate to next admin");

        assertEq(masp.owner(), address(next), "pool did not move");
        assertEq(wrapper.owner(), address(next), "wrapper did not move");
    }

    /// The retired admin holds neither ownership nor the proxy admin: its
    /// governance can no longer call an `onlyOwner` function or re-arm the pause,
    /// and its guardian can no longer pause spends.
    function test_oldAdminIsPowerlessAfterMigration() public {
        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(timelock));
        _migrate(address(next), "migrate");

        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(protocolAdmin)));
        protocolAdmin.execute(address(masp), abi.encodeCall(AssetRegistry.setAssetFee, (ASSET_ID, 77, 77)));

        vm.prank(address(timelock));
        vm.expectRevert(DelayedUpgradeProxy.NotProxyAdmin.selector);
        protocolAdmin.execute(address(masp), abi.encodeCall(DelayedUpgradeProxy.resetGuardianPause, ()));

        vm.prank(guardian);
        vm.expectRevert(DelayedUpgradeProxy.NotProxyAdmin.selector);
        protocolAdmin.pauseSpends(1 days);
        assertFalse(_poolProxy().guardianPauseUsed(), "retired guardian paused spends");
    }

    /// Upgrade authority moves in the same call as ownership, so a retired
    /// governance cannot keep the right to queue an implementation over a pool
    /// its successor owns.
    function test_migrateMovesProxyAdminWithOwnership() public {
        assertEq(_poolProxy().proxyAdmin(), address(protocolAdmin), "fixture did not hand over the proxy admin");
        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(timelock));
        _migrate(address(next), "migrate");

        assertEq(_poolProxy().proxyAdmin(), address(next), "proxy admin stayed behind");
        assertEq(masp.owner(), address(next));
        assertEq(wrapper.owner(), address(next));
    }

    /// An upgrade queued by the retired admin remains cancellable: the successor
    /// inherits the proxy admin, and with it `cancelUpgrade`.
    function test_newAdminCanCancelUpgradeQueuedBeforeMigration() public {
        address impl = address(new MASP());
        _passAdminCall(address(masp), abi.encodeCall(DelayedUpgradeProxy.queueUpgrade, (impl)), "queue upgrade");
        (address pending,) = _poolProxy().pendingUpgrade();
        assertEq(pending, impl, "upgrade not queued");

        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(timelock));
        _migrate(address(next), "migrate");

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(next),
            abi.encodeCall(
                ProtocolAdmin.execute, (address(masp), abi.encodeCall(DelayedUpgradeProxy.cancelUpgrade, ()))
            )
        );
        _passProposal(t, v, c, "cancel via the new admin");

        (pending,) = _poolProxy().pendingUpgrade();
        assertEq(pending, address(0), "successor could not cancel");
    }

    /// After migration the retired admin cannot queue an implementation, which
    /// is the power an admin left holding the proxy seat would retain.
    function test_oldAdminCannotQueueAfterMigration() public {
        address impl = address(new MASP());
        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(timelock));
        _migrate(address(next), "migrate");

        vm.prank(address(timelock));
        vm.expectRevert(DelayedUpgradeProxy.NotProxyAdmin.selector);
        protocolAdmin.execute(address(masp), abi.encodeCall(DelayedUpgradeProxy.queueUpgrade, (impl)));

        (address pending,) = _poolProxy().pendingUpgrade();
        assertEq(pending, address(0));
    }

    function test_newAdminWorksEndToEnd() public {
        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(timelock));
        _migrate(address(next), "migrate");

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(next),
            abi.encodeCall(
                ProtocolAdmin.execute, (address(masp), abi.encodeCall(AssetRegistry.setAssetFee, (ASSET_ID, 7, 8)))
            )
        );
        _passProposal(t, v, c, "fee via the new admin");

        // Both rates fall, so both apply on execution.
        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, 7);
        assertEq(wit, 8);

        // The guardian carries over because it was granted on the new contract.
        vm.prank(guardian);
        next.disableAsset(ASSET_ID);
        assertTrue(masp.asset(ASSET_ID).disabled);
    }

    // ============== Each guard, individually =================================

    function test_rejectsEOA() public {
        _migrateExpectingRevert(makeAddr("eoa"), "migrate to eoa");
        assertEq(masp.owner(), address(protocolAdmin), "ownership escaped to an EOA");
    }

    function test_rejectsWrongPool() public {
        ProtocolAdmin bad = _newAdmin(makeAddr("otherPool"), address(wrapper), address(timelock));
        _migrateExpectingRevert(address(bad), "migrate to wrong pool");
        assertEq(masp.owner(), address(protocolAdmin));
    }

    function test_rejectsWrongWrapper() public {
        ProtocolAdmin bad = _newAdmin(address(masp), makeAddr("otherWrapper"), address(timelock));
        _migrateExpectingRevert(address(bad), "migrate to wrong wrapper");
        assertEq(masp.owner(), address(protocolAdmin));
    }

    /// Ownership cannot move to an admin contract this timelock does not
    /// administer.
    function test_rejectsAdminNotGovernedByThisTimelock() public {
        ProtocolAdmin bad = _newAdmin(address(masp), address(wrapper), makeAddr("someoneElse"));
        _migrateExpectingRevert(address(bad), "migrate to ungoverned admin");
        assertEq(masp.owner(), address(protocolAdmin));
    }

    /// Ownership does not move unless this contract also holds the proxy admin,
    /// so the two seats cannot be split by migrating from a deployment whose
    /// handover skipped the proxy. `execute` cannot move the proxy admin, so
    /// the state is built by having this contract hand it back directly.
    function test_revert_ProxyAdminNotHeld() public {
        vm.prank(address(protocolAdmin));
        _poolProxy().changeProxyAdmin(TEST_PROXY_ADMIN);

        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(timelock));
        vm.prank(address(timelock));
        vm.expectRevert(ProtocolAdmin.ProxyAdminNotHeld.selector);
        protocolAdmin.migrateAdmin(address(next));

        assertEq(masp.owner(), address(protocolAdmin), "ownership left without the proxy admin");
        assertEq(wrapper.owner(), address(protocolAdmin));
        assertEq(_poolProxy().proxyAdmin(), TEST_PROXY_ADMIN);
    }

    function test_onlyTimelockMayMigrate() public {
        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(timelock));
        address attacker = makeAddr("attacker");
        bytes32 adminRole = protocolAdmin.DEFAULT_ADMIN_ROLE();

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, adminRole)
        );
        protocolAdmin.migrateAdmin(address(next));
    }

    // ============== Migrating governance itself ==============================

    /// Under the `AdminNotGoverned` check, moving to a new Timelock requires the
    /// current one to hold `DEFAULT_ADMIN_ROLE` on the successor at the time of
    /// the call: grant, migrate, revoke.
    function test_newTimelockMigrationViaGrantMigrateRevoke() public {
        address[] memory empty = new address[](0);
        address[] memory openExec = new address[](1);
        TimelockController newTimelock = new TimelockController(TIMELOCK_DELAY, empty, openExec, address(this));

        // Successor admin, deployed admin-then-renounce as the script does, and
        // governed by both timelocks: the old one so `migrateAdmin`'s
        // `AdminNotGoverned` check passes, the new one so it inherits control.
        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(this));
        bytes32 adminRole = next.DEFAULT_ADMIN_ROLE();
        next.grantRole(adminRole, address(timelock));
        next.grantRole(adminRole, address(newTimelock));
        next.renounceRole(adminRole, address(this));

        _migrate(address(next), "migrate to a new timelock");
        assertEq(masp.owner(), address(next));

        // The new timelock then revokes the old timelock's admin role.
        vm.prank(address(newTimelock));
        next.revokeRole(adminRole, address(timelock));
        assertFalse(next.hasRole(adminRole, address(timelock)));
        assertTrue(next.hasRole(adminRole, address(newTimelock)));
    }
}
