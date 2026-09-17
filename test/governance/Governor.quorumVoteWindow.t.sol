// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Vm } from "forge-std/Vm.sol";

import { LelantosGovernor } from "../../src/governance/LelantosGovernor.sol";

import { GovTestBase } from "./GovTestBase.sol";

/// The asymmetric voting window: quorum votes (For and Abstain, the vote types
/// counted toward quorum) close `quorumVoteCutoff` seconds before
/// `proposalDeadline`, Against stays open to it. Without this, a last block For
/// or Abstain vote could tip a proposal past the For/Against comparison or past
/// quorum with no time left to answer it.
contract GovernorQuorumVoteWindowTest is GovTestBase {
    function _quorumVotingClosed(uint256 id) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            LelantosGovernor.QuorumVotingClosed.selector, id, governor.proposalQuorumVoteDeadline(id)
        );
    }

    /// A delegated signer holding 10% of supply, for the `castVoteBySig` tests.
    function _fundSigner() internal returns (address signer, uint256 key) {
        (signer, key) = makeAddrAndKey("signer");
        _giveVotes(signer, SUPPLY / 10);
    }

    function _ballotDigest(uint256 id, uint8 support, address voter) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(governor.name())),
                keccak256(bytes(governor.version())),
                block.chainid,
                address(governor)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(governor.BALLOT_TYPEHASH(), id, support, voter, governor.nonces(voter)));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _signBallot(uint256 key, uint256 id, uint8 support, address voter) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _ballotDigest(id, support, voter));
        return abi.encodePacked(r, s, v);
    }

    // ============== Configuration ============================================

    function test_constructorSetsQuorumVoteCutoff() public view {
        assertEq(governor.quorumVoteCutoff(), QUORUM_VOTE_CUTOFF);
    }

    function test_quorumVoteDeadlineIsDeadlineMinusCutoff() public {
        uint256 id = _proposeCancelDelay("deadline");
        assertEq(governor.proposalQuorumVoteDeadline(id), governor.proposalDeadline(id) - QUORUM_VOTE_CUTOFF);
        assertGt(governor.proposalQuorumVoteDeadline(id), governor.proposalSnapshot(id), "no quorum vote window");
    }

    function test_unknownProposalHasNoQuorumVoteDeadline() public view {
        assertEq(governor.proposalQuorumVoteDeadline(12_345), 0);
    }

    /// An unknown proposal has no stored deadline, so the parent's error wins
    /// over `QuorumVotingClosed`.
    function test_forOnUnknownProposalRevertsAsNonexistent() public {
        vm.prank(voter2);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, 12_345));
        governor.castVote(12_345, FOR);
    }

    function test_constructorRejectsCutoffAtVotingPeriod() public {
        vm.expectRevert(
            abi.encodeWithSelector(LelantosGovernor.InvalidQuorumVoteCutoff.selector, VOTING_PERIOD, VOTING_PERIOD)
        );
        new LelantosGovernor(
            IVotes(address(gov)),
            timelock,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_NUMERATOR,
            VOTING_PERIOD
        );
    }

    // ============== Events ===================================================

    /// `ProposalQuorumVoteDeadline` follows `ProposalCreated` directly, in the
    /// same transaction, so an indexer can attach it to the proposal.
    function test_proposalQuorumVoteDeadlineEmittedRightAfterProposalCreated() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _cancelDelayPayload();
        string memory desc = "events";
        uint256 id = governor.hashProposal(t, v, c, keccak256(bytes(desc)));
        uint256 expected = T0 + 1 + VOTING_DELAY + VOTING_PERIOD - QUORUM_VOTE_CUTOFF;

        vm.expectEmit(address(governor));
        emit LelantosGovernor.ProposalQuorumVoteDeadline(id, expected);
        vm.recordLogs();
        vm.prank(voter1);
        governor.propose(t, v, c, desc);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 created = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IGovernor.ProposalCreated.selector) created = i;
        }
        assertTrue(created != type(uint256).max, "ProposalCreated missing");
        assertLt(created + 1, logs.length, "nothing after ProposalCreated");
        assertEq(logs[created + 1].topics[0], LelantosGovernor.ProposalQuorumVoteDeadline.selector, "not adjacent");
        assertEq(logs[created + 1].emitter, address(governor));
        (uint256 loggedId, uint256 loggedDeadline) = abi.decode(logs[created + 1].data, (uint256, uint256));
        assertEq(loggedId, id);
        assertEq(loggedDeadline, expected);
    }

    // ============== Vote timing ==============================================

    function test_forAcceptedExactlyAtQuorumVoteDeadline() public {
        uint256 id = _proposeCancelDelay("for at deadline");
        vm.warp(governor.proposalQuorumVoteDeadline(id));
        vm.prank(voter2);
        governor.castVote(id, FOR);
        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, SUPPLY / 5);
    }

    function test_abstainAcceptedExactlyAtQuorumVoteDeadline() public {
        uint256 id = _proposeCancelDelay("abstain at deadline");
        vm.warp(governor.proposalQuorumVoteDeadline(id));
        vm.prank(voter2);
        governor.castVote(id, ABSTAIN);
        (,, uint256 abstainVotes) = governor.proposalVotes(id);
        assertEq(abstainVotes, SUPPLY / 5);
    }

    function test_forRejectedOneSecondAfterQuorumVoteDeadline() public {
        uint256 id = _proposeCancelDelay("for late");
        vm.warp(governor.proposalQuorumVoteDeadline(id) + 1);
        bytes memory closed = _quorumVotingClosed(id);
        vm.prank(voter2);
        vm.expectRevert(closed);
        governor.castVote(id, FOR);
    }

    function test_abstainRejectedOneSecondAfterQuorumVoteDeadline() public {
        uint256 id = _proposeCancelDelay("abstain late");
        vm.warp(governor.proposalQuorumVoteDeadline(id) + 1);
        bytes memory closed = _quorumVotingClosed(id);
        vm.prank(voter2);
        vm.expectRevert(closed);
        governor.castVoteWithReason(id, ABSTAIN, "late");
    }

    function test_forWithParamsRejectedAfterQuorumVoteDeadline() public {
        uint256 id = _proposeCancelDelay("params late");
        vm.warp(governor.proposalQuorumVoteDeadline(id) + 1);
        bytes memory closed = _quorumVotingClosed(id);
        vm.prank(voter2);
        vm.expectRevert(closed);
        governor.castVoteWithReasonAndParams(id, FOR, "late", "");
    }

    function test_againstAcceptedAfterQuorumVoteDeadlineUntilProposalDeadline() public {
        uint256 id = _proposeCancelDelay("against late");
        vm.warp(governor.proposalQuorumVoteDeadline(id) + 1);
        vm.prank(voter2);
        governor.castVote(id, AGAINST);

        vm.warp(governor.proposalDeadline(id));
        vm.prank(voter3);
        governor.castVote(id, AGAINST);

        (uint256 againstVotes,,) = governor.proposalVotes(id);
        assertEq(againstVotes, 2 * (SUPPLY / 5));
    }

    function test_againstRejectedAfterProposalDeadline() public {
        uint256 id = _proposeCancelDelay("against too late");
        vm.warp(governor.proposalDeadline(id) + 1);
        vm.prank(voter2);
        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.castVote(id, AGAINST);
    }

    /// A late Against can still defeat a proposal whose For votes were all in
    /// before the cutoff, which is the point of the window.
    function test_lateAgainstDefeatsEarlierFor() public {
        uint256 id = _proposeCancelDelay("late answer");
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(voter1);
        governor.castVote(id, FOR);

        vm.warp(governor.proposalDeadline(id));
        vm.prank(voter2);
        governor.castVote(id, AGAINST);
        vm.prank(voter3);
        governor.castVote(id, AGAINST);

        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    // ============== Signatures ===============================================

    /// `castVoteBySig` reaches the same `_castVote` overload as `castVote`.
    function test_castVoteBySigObeysQuorumVoteWindow() public {
        (address signer, uint256 key) = _fundSigner();
        uint256 id = _proposeCancelDelay("by sig");

        vm.warp(governor.proposalQuorumVoteDeadline(id) + 1);
        bytes memory forSig = _signBallot(key, id, FOR, signer);
        vm.expectRevert(_quorumVotingClosed(id));
        governor.castVoteBySig(id, FOR, signer, forSig);

        bytes memory abstainSig = _signBallot(key, id, ABSTAIN, signer);
        vm.expectRevert(_quorumVotingClosed(id));
        governor.castVoteBySig(id, ABSTAIN, signer, abstainSig);

        vm.warp(governor.proposalDeadline(id));
        governor.castVoteBySig(id, AGAINST, signer, _signBallot(key, id, AGAINST, signer));
        assertTrue(governor.hasVoted(id, signer));
    }

    function test_castVoteBySigForAcceptedAtQuorumVoteDeadline() public {
        (address signer, uint256 key) = _fundSigner();
        uint256 id = _proposeCancelDelay("by sig on time");

        vm.warp(governor.proposalQuorumVoteDeadline(id));
        governor.castVoteBySig(id, FOR, signer, _signBallot(key, id, FOR, signer));
        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, SUPPLY / 10);
    }

    // ============== Fuzz =====================================================

    /// For and Abstain are accepted iff `clock <= deadline - cutoff`; Against iff
    /// `clock <= deadline`; nothing before the snapshot has passed.
    function testFuzz_quorumVoteWindow(uint32 period, uint32 cutoff, uint256 voteAt, uint8 support) public {
        period = uint32(bound(period, 1, 30 days));
        cutoff = uint32(bound(cutoff, 0, period - 1));
        support = uint8(bound(support, 0, 2));

        LelantosGovernor g = new LelantosGovernor(
            IVotes(address(gov)), timelock, 1 days, period, PROPOSAL_THRESHOLD, QUORUM_NUMERATOR, cutoff
        );
        assertEq(g.quorumVoteCutoff(), cutoff);

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _cancelDelayPayload();
        vm.prank(voter1);
        uint256 id = g.propose(t, v, c, "fuzz");

        uint256 snapshot = g.proposalSnapshot(id);
        uint256 deadline = g.proposalDeadline(id);
        uint256 quorumVoteDeadline = g.proposalQuorumVoteDeadline(id);
        assertEq(quorumVoteDeadline, deadline - cutoff);
        assertGt(quorumVoteDeadline, snapshot, "empty quorum vote window");

        voteAt = bound(voteAt, snapshot + 1, deadline + 2);
        vm.warp(voteAt);

        vm.prank(voter2);
        // `quorumVoteDeadline <= deadline`, so a late For or Abstain reports the
        // quorum vote deadline even past the proposal deadline.
        if (support != AGAINST && voteAt > quorumVoteDeadline) {
            vm.expectRevert(
                abi.encodeWithSelector(LelantosGovernor.QuorumVotingClosed.selector, id, quorumVoteDeadline)
            );
            g.castVote(id, support);
        } else if (voteAt > deadline) {
            vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
            g.castVote(id, support);
        } else {
            g.castVote(id, support);
            assertTrue(g.hasVoted(id, voter2));
        }
    }
}
