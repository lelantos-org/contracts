// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { GovernorSettings } from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";

import { LelantosGovernor } from "../../src/governance/LelantosGovernor.sol";

import { GovTestBase } from "./GovTestBase.sol";

/// Governance control of `quorumVoteCutoff` and its coupling to `votingPeriod`:
/// only a proposal can move either, the cutoff must stay below the period, and a
/// change does not reach proposals already created. The window itself is
/// covered in `Governor.quorumVoteWindow.t.sol`.
contract GovernorCutoffParamsTest is GovTestBase {
    /// Proposes, queues and warps to the eta of a call on the Governor itself,
    /// leaving `execute` to the caller so it can expect a revert.
    function _queueSelfCall(bytes memory data, string memory desc)
        internal
        returns (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h)
    {
        (t, v, c) = _one(address(governor), data);
        h = keccak256(bytes(desc));
        _queueToEta(t, v, c, desc);
    }

    // ============== Governance-set cutoff ====================================

    function test_setQuorumVoteCutoffByNonGovernanceReverts() public {
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorOnlyExecutor.selector, voter1));
        governor.setQuorumVoteCutoff(2 days);
    }

    /// Even the Timelock cannot call it outside a proposal execution: the
    /// Governor only accepts calls it has queued for itself.
    function test_setQuorumVoteCutoffByTimelockOutsideExecutionReverts() public {
        vm.prank(address(timelock));
        vm.expectRevert();
        governor.setQuorumVoteCutoff(2 days);
    }

    function test_setQuorumVoteCutoffByProposal() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _queueSelfCall(abi.encodeCall(LelantosGovernor.setQuorumVoteCutoff, (2 days)), "cutoff 2d");

        vm.expectEmit(address(governor));
        emit LelantosGovernor.QuorumVoteCutoffSet(QUORUM_VOTE_CUTOFF, 2 days);
        governor.execute(t, v, c, h);
        assertEq(governor.quorumVoteCutoff(), 2 days);
    }

    function test_setQuorumVoteCutoffAtVotingPeriodReverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _queueSelfCall(abi.encodeCall(LelantosGovernor.setQuorumVoteCutoff, (VOTING_PERIOD)), "cutoff = period");
        vm.expectRevert(
            abi.encodeWithSelector(LelantosGovernor.InvalidQuorumVoteCutoff.selector, VOTING_PERIOD, VOTING_PERIOD)
        );
        governor.execute(t, v, c, h);
    }

    function test_setQuorumVoteCutoffAboveVotingPeriodReverts() public {
        uint32 cutoff = VOTING_PERIOD + 1;
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _queueSelfCall(abi.encodeCall(LelantosGovernor.setQuorumVoteCutoff, (cutoff)), "cutoff > period");
        vm.expectRevert(
            abi.encodeWithSelector(LelantosGovernor.InvalidQuorumVoteCutoff.selector, cutoff, VOTING_PERIOD)
        );
        governor.execute(t, v, c, h);
    }

    function test_setVotingPeriodAtCutoffReverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _queueSelfCall(abi.encodeCall(GovernorSettings.setVotingPeriod, (QUORUM_VOTE_CUTOFF)), "period = cutoff");
        vm.expectRevert(
            abi.encodeWithSelector(
                LelantosGovernor.InvalidQuorumVoteCutoff.selector, QUORUM_VOTE_CUTOFF, QUORUM_VOTE_CUTOFF
            )
        );
        governor.execute(t, v, c, h);
    }

    function test_setVotingPeriodBelowCutoffReverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) =
            _queueSelfCall(abi.encodeCall(GovernorSettings.setVotingPeriod, (1 hours)), "period < cutoff");
        vm.expectRevert(
            abi.encodeWithSelector(LelantosGovernor.InvalidQuorumVoteCutoff.selector, QUORUM_VOTE_CUTOFF, 1 hours)
        );
        governor.execute(t, v, c, h);
    }

    function test_setVotingPeriodAboveCutoffSucceeds() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, bytes32 h) = _queueSelfCall(
            abi.encodeCall(GovernorSettings.setVotingPeriod, (QUORUM_VOTE_CUTOFF + 1)), "period > cutoff"
        );
        governor.execute(t, v, c, h);
        assertEq(governor.votingPeriod(), QUORUM_VOTE_CUTOFF + 1);
    }

    /// The quorum vote deadline is fixed at propose time: a cutoff change
    /// executed while a proposal is active moves only proposals created
    /// afterwards.
    function test_cutoffChangeDoesNotMoveActiveProposalQuorumVoteDeadline() public {
        uint32 newCutoff = 3 days;
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(governor), abi.encodeCall(LelantosGovernor.setQuorumVoteCutoff, (newCutoff)));
        string memory desc = "cutoff 3d";
        uint256 changeId = _proposeAndSucceed(t, v, c, desc);
        governor.queue(t, v, c, keccak256(bytes(desc)));

        // Created before the change lands; its voting window spans the execute.
        uint256 active = _proposeCancelDelay("already active");
        uint256 before = governor.proposalQuorumVoteDeadline(active);
        assertEq(before, governor.proposalDeadline(active) - QUORUM_VOTE_CUTOFF);

        vm.warp(governor.proposalEta(changeId) + 1);
        governor.execute(t, v, c, keccak256(bytes(desc)));
        assertEq(governor.quorumVoteCutoff(), newCutoff);
        assertEq(uint8(governor.state(active)), uint8(IGovernor.ProposalState.Active), "not active at change");

        assertEq(governor.proposalQuorumVoteDeadline(active), before, "active proposal deadline moved");

        // For is still accepted up to the original deadline, which the new,
        // longer cutoff would already have closed.
        vm.warp(before);
        assertGt(before, governor.proposalDeadline(active) - newCutoff);
        vm.prank(voter2);
        governor.castVote(active, FOR);

        uint256 later = _proposeCancelDelay("after change");
        assertEq(governor.proposalQuorumVoteDeadline(later), governor.proposalDeadline(later) - newCutoff);
    }
}
