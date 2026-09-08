// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { ProtocolAdmin } from "../../src/governance/ProtocolAdmin.sol";

import { GovTestBase } from "./GovTestBase.sol";

/// `migrateAdmin` is the only way ownership can leave `ProtocolAdmin`, and it is
/// the single most dangerous call in the system — so both that it *works* and
/// that each guard bites are pinned here.
///
/// The guards stop accidents, not a hostile proposal: a malicious successor can
/// return whatever these getters like. What bounds that is the timelock delay and
/// the guardian's veto, which is asserted in `Timelock.roles.t.sol`.
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
        _proposeAndSucceed(t, v, c, desc);
        governor.queue(t, v, c, keccak256(bytes(desc)));
        vm.warp(governor.proposalEta(governor.hashProposal(t, v, c, keccak256(bytes(desc)))) + 1);
        vm.expectRevert();
        governor.execute(t, v, c, keccak256(bytes(desc)));
    }

    // ============== The happy path ===========================================

    /// Both contracts move in one call, so they can never end up under different
    /// owners.
    function test_migratesBothPoolAndWrapperAtomically() public {
        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(timelock));
        _migrate(address(next), "migrate to next admin");

        assertEq(masp.owner(), address(next), "pool did not move");
        assertEq(wrapper.owner(), address(next), "wrapper did not move");
    }

    function test_oldAdminIsPowerlessAfterMigration() public {
        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(timelock));
        _migrate(address(next), "migrate");

        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(protocolAdmin)));
        protocolAdmin.execute(address(masp), abi.encodeCall(AssetRegistry.setAssetFee, (ASSET_ID, 77, 77)));
    }

    function test_newAdminWorksEndToEnd() public {
        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(timelock));
        _migrate(address(next), "migrate");

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(next),
            abi.encodeCall(
                ProtocolAdmin.execute, (address(masp), abi.encodeCall(AssetRegistry.setAssetFee, (ASSET_ID, 77, 88)))
            )
        );
        _passProposal(t, v, c, "fee via the new admin");

        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, 77);
        assertEq(wit, 88);

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

    /// The check that matters most: ownership must not land on a contract this
    /// governance does not administer.
    function test_rejectsAdminNotGovernedByThisTimelock() public {
        ProtocolAdmin bad = _newAdmin(address(masp), address(wrapper), makeAddr("someoneElse"));
        _migrateExpectingRevert(address(bad), "migrate to ungoverned admin");
        assertEq(masp.owner(), address(protocolAdmin));
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

    /// The documented cost of the `AdminNotGoverned` check: moving to a *new*
    /// Timelock needs the current one to hold `DEFAULT_ADMIN_ROLE` on the
    /// successor at the moment of the call. Grant, migrate, revoke.
    function test_newTimelockMigrationViaGrantMigrateRevoke() public {
        address[] memory empty = new address[](0);
        address[] memory openExec = new address[](1);
        TimelockController newTimelock = new TimelockController(TIMELOCK_DELAY, empty, openExec, address(this));

        // Successor admin, deployed admin-then-renounce exactly as the script
        // does, and governed by BOTH timelocks: the old one so `migrateAdmin`'s
        // `AdminNotGoverned` check passes, the new one so it inherits control.
        ProtocolAdmin next = _newAdmin(address(masp), address(wrapper), address(this));
        bytes32 adminRole = next.DEFAULT_ADMIN_ROLE();
        next.grantRole(adminRole, address(timelock));
        next.grantRole(adminRole, address(newTimelock));
        next.renounceRole(adminRole, address(this));

        _migrate(address(next), "migrate to a new timelock");
        assertEq(masp.owner(), address(next));

        // Old timelock's foothold is then revoked by the new authority.
        vm.prank(address(newTimelock));
        next.revokeRole(adminRole, address(timelock));
        assertFalse(next.hasRole(adminRole, address(timelock)));
        assertTrue(next.hasRole(adminRole, address(newTimelock)));
    }
}
