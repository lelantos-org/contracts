// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { MASP } from "../../src/MASP.sol";

import { GovTestBase } from "./GovTestBase.sol";

/// The post-deploy role table and the guardian's veto.
///
/// The deploy script's last transaction is the deployer renouncing
/// `DEFAULT_ADMIN_ROLE`. Steps before it are recoverable and the resulting role
/// table is not, so the table is pinned exactly.
contract TimelockRolesTest is GovTestBase {
    /// Mirrors `GovernorTimelockControl._timelockSalt`, which is private.
    function _salt(bytes32 descriptionHash) internal view returns (bytes32) {
        return bytes20(address(governor)) ^ descriptionHash;
    }

    // ============== Role table ===============================================

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

    /// Open execution: after the delay the payload is fixed, public, and has been
    /// vetoable for the full delay, so execution carries liveness only.
    function test_executionIsOpenToAnyone() public view {
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
    }

    /// The timelock administers itself, so governance can rotate the guardian
    /// without an external admin.
    function test_timelockSelfAdministers() public view {
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
    }

    function test_guardianHoldsOnlyCanceller() public view {
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), guardian));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), guardian));
    }

    // ============== Veto =====================================================

    /// The guardian can cancel a queued proposal within the delay window. With
    /// the Timelock owning the pool directly this is the only backstop against a
    /// proposal that passes a vote and destroys ownership, moves the proxy admin
    /// or sets a malicious parameter.
    function test_guardianCanVetoAQueuedProposal() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _adminCall(address(masp), abi.encodeCall(MASP.setCancelDelay, (4_000)));
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

    /// Governance can revoke the guardian's veto by proposal.
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
            _adminCall(address(masp), abi.encodeCall(MASP.setCancelDelay, (5_555)));
        string memory desc = "executed directly on the timelock";
        bytes32 h = keccak256(bytes(desc));

        uint256 id = _queueToEta(t, v, c, desc);

        // Any account may execute, including directly on the timelock.
        address randomer = makeAddr("randomer");
        vm.prank(randomer);
        timelock.executeBatch(t, v, c, 0, _salt(h));

        assertEq(masp.cancelDelay(), 5_555);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));
    }
}
