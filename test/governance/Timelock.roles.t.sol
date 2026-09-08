// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { MASP } from "../../src/MASP.sol";
import { ProtocolAdmin } from "../../src/governance/ProtocolAdmin.sol";

import { GovTestBase } from "./GovTestBase.sol";

/// The post-deploy role table, and the guardian's veto.
///
/// The deploy script's last transaction is the deployer renouncing
/// `DEFAULT_ADMIN_ROLE`. Everything before it is recoverable and everything after
/// it is not, so the resulting table is worth pinning exactly.
contract TimelockRolesTest is GovTestBase {
    /// Mirrors `GovernorTimelockControl._timelockSalt`, which is private.
    function _salt(bytes32 descriptionHash) internal view returns (bytes32) {
        return bytes20(address(governor)) ^ descriptionHash;
    }

    function _adminCall(bytes memory data) internal view returns (address[] memory, uint256[] memory, bytes[] memory) {
        return _one(address(protocolAdmin), abi.encodeCall(ProtocolAdmin.execute, (address(masp), data)));
    }

    // ============== The table ================================================

    function test_deployerHoldsNothing() public view {
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)), "deployer kept admin");
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(this)));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), address(this)));
    }

    function test_governorIsTheOnlyProposer() public view {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), guardian), "guardian must not propose");
    }

    /// Open execution: after the delay the payload is fixed, public, and was
    /// vetoable for three days, so execution carries liveness only.
    function test_executionIsOpenToAnyone() public view {
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
    }

    /// The timelock administers itself, which is what lets governance rotate the
    /// guardian without an external admin existing.
    function test_timelockSelfAdministers() public view {
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
    }

    function test_guardianHoldsOnlyCanceller() public view {
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), guardian));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), guardian));
    }

    // ============== The veto =================================================

    /// The guardian's real job: kill a queued proposal inside the delay window.
    /// This is the backstop against a hostile `migrateAdmin` or a malicious
    /// parameter change surviving a vote.
    function test_guardianCanVetoAQueuedProposal() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _adminCall(abi.encodeCall(MASP.setCancelDelay, (9_000)));
        string memory desc = "vetoed proposal";
        bytes32 h = keccak256(bytes(desc));

        uint256 id = _proposeAndSucceed(t, v, c, desc);
        governor.queue(t, v, c, h);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));

        bytes32 opId = timelock.hashOperationBatch(t, v, c, 0, _salt(h));
        vm.prank(guardian);
        timelock.cancel(opId);

        vm.warp(governor.proposalEta(id) + 1);
        vm.expectRevert();
        governor.execute(t, v, c, h);
        assertEq(masp.cancelDelay(), 7_200, "vetoed proposal still landed");
    }

    function test_guardianCannotSchedule() public {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, proposerRole)
        );
        timelock.schedule(address(masp), 0, "", bytes32(0), bytes32(0), TIMELOCK_DELAY);
    }

    /// The guardian is revocable, so granting the veto is not a permanent
    /// concession.
    function test_governanceCanRevokeTheGuardiansVeto() public {
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(timelock), abi.encodeCall(IAccessControl.revokeRole, (cancellerRole, guardian)));
        _passProposal(t, v, c, "revoke guardian veto");

        assertFalse(timelock.hasRole(cancellerRole, guardian));
    }

    function test_minDelayOnlyChangesThroughTheTimelockItself() public {
        vm.expectRevert();
        timelock.updateDelay(1 days);

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(timelock), abi.encodeCall(TimelockController.updateDelay, (5 days)));
        _passProposal(t, v, c, "raise min delay");
        assertEq(timelock.getMinDelay(), 5 days);
    }

    /// `GovernorTimelockControl.state()` resolves a directly-executed operation
    /// through `isOperationDone`, so bypassing `governor.execute` does not desync
    /// the Governor's bookkeeping.
    function test_directTimelockExecutionStillReportsExecuted() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _adminCall(abi.encodeCall(MASP.setCancelDelay, (8_888)));
        string memory desc = "executed directly on the timelock";
        bytes32 h = keccak256(bytes(desc));

        uint256 id = _proposeAndSucceed(t, v, c, desc);
        governor.queue(t, v, c, h);
        vm.warp(governor.proposalEta(id) + 1);

        // Anyone may execute, and they may do it on the timelock directly.
        address randomer = makeAddr("randomer");
        vm.prank(randomer);
        timelock.executeBatch(t, v, c, 0, _salt(h));

        assertEq(masp.cancelDelay(), 8_888);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));
    }
}
