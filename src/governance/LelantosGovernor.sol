// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Governor } from "@openzeppelin/contracts/governance/Governor.sol";
import { GovernorCountingSimple } from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import { GovernorSettings } from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import { GovernorTimelockControl } from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import { GovernorVotes } from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// On-chain governance. Executes through a `TimelockController`, which owns
/// `MASP` and `SwapWrapper` directly and is the pool's proxy admin.
///
/// Vote weight is a delegated-balance snapshot taken at `proposalSnapshot`, and
/// the proposal threshold is read at `clock() - 1`. Both are past timepoints, so
/// tokens borrowed and delegated within a single transaction carry no weight.
///
/// `clock()` and `CLOCK_MODE()` are not overridden here: `GovernorVotes` reads
/// them from the token, so the timestamp mode propagates automatically.
///
/// Quorum is a fraction of total supply rather than delegated supply, because
/// `Votes` checkpoints the total only on mint and burn. Undelegated and
/// unclaimed tokens therefore count toward the denominator, and burns reduce it.
///
/// The voting window is asymmetric. For and Abstain, the two vote types that
/// count toward quorum, close `quorumVoteCutoff` seconds before
/// `proposalDeadline`; Against stays open until the deadline. With a symmetric
/// window, a large For or Abstain vote cast in the last block could carry a
/// proposal past the For/Against comparison or past quorum with no time left
/// for opponents to respond. Closing quorum votes early leaves opponents the
/// final `quorumVoteCutoff` seconds, which only Against votes can use, so a late
/// swing can be answered but not made.
///
/// The cutoff is governance-settable and captured per proposal at propose
/// time: changing it never moves the quorum vote deadline of a proposal already
/// created, so voters see a fixed schedule from `ProposalCreated` onward.
contract LelantosGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /// Seconds before `proposalDeadline` at which quorum votes (For, Abstain)
    /// close, for proposals created from now on.
    uint32 private _quorumVoteCutoff;

    /// Last timepoint at which a quorum vote may be cast, per proposal. Fixed at
    /// propose time so a later cutoff change cannot reschedule a live vote.
    mapping(uint256 proposalId => uint48) private _quorumVoteDeadlines;

    event QuorumVoteCutoffSet(uint256 oldQuorumVoteCutoff, uint256 newQuorumVoteCutoff);

    /// Emitted right after `ProposalCreated`, in the same transaction, so an
    /// indexer can show the quorum vote deadline without replaying the cutoff
    /// history.
    event ProposalQuorumVoteDeadline(uint256 proposalId, uint256 quorumVoteDeadline);

    /// A For or Abstain vote cast after the proposal's quorum vote deadline.
    error QuorumVotingClosed(uint256 proposalId, uint256 quorumVoteDeadline);

    /// The cutoff must leave some quorum vote window: at or above the voting
    /// period, For could never be cast and no proposal could pass.
    error InvalidQuorumVoteCutoff(uint256 quorumVoteCutoff, uint256 votingPeriod);

    constructor(
        IVotes token_,
        TimelockController timelock_,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_,
        uint256 quorumNumerator_,
        uint32 quorumVoteCutoff_
    )
        Governor("Lelantos Governor")
        GovernorSettings(votingDelay_, votingPeriod_, proposalThreshold_)
        GovernorVotes(token_)
        GovernorVotesQuorumFraction(quorumNumerator_)
        GovernorTimelockControl(timelock_)
    {
        // `GovernorSettings` has already run `_setVotingPeriod` with the cutoff
        // still zero, so the period was accepted unchecked against it; this
        // call re-checks the pair.
        _setQuorumVoteCutoff(quorumVoteCutoff_);
    }

    // ============== Quorum vote window =======================================

    function quorumVoteCutoff() external view returns (uint256) {
        return _quorumVoteCutoff;
    }

    /// Zero for an unknown proposal.
    function proposalQuorumVoteDeadline(uint256 proposalId) external view returns (uint256) {
        return _quorumVoteDeadlines[proposalId];
    }

    function setQuorumVoteCutoff(uint32 newQuorumVoteCutoff) external onlyGovernance {
        _setQuorumVoteCutoff(newQuorumVoteCutoff);
    }

    function _setQuorumVoteCutoff(uint32 newQuorumVoteCutoff) internal {
        uint256 period = votingPeriod();
        if (newQuorumVoteCutoff >= period) revert InvalidQuorumVoteCutoff(newQuorumVoteCutoff, period);
        emit QuorumVoteCutoffSet(_quorumVoteCutoff, newQuorumVoteCutoff);
        _quorumVoteCutoff = newQuorumVoteCutoff;
    }

    /// A period at or below the cutoff would put the quorum vote deadline at or
    /// before the snapshot, so the pair is re-checked whenever either moves.
    function _setVotingPeriod(uint32 newVotingPeriod) internal override {
        super._setVotingPeriod(newVotingPeriod);
        if (newVotingPeriod <= _quorumVoteCutoff) revert InvalidQuorumVoteCutoff(_quorumVoteCutoff, newVotingPeriod);
    }

    function _propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address proposer
    ) internal override returns (uint256 proposalId) {
        proposalId = super._propose(targets, values, calldatas, description, proposer);
        // `quorumVoteCutoff < votingPeriod` holds, so the deadline lands strictly
        // after the snapshot and inside the voting window.
        uint48 quorumVoteDeadline = SafeCast.toUint48(proposalDeadline(proposalId) - _quorumVoteCutoff);
        _quorumVoteDeadlines[proposalId] = quorumVoteDeadline;
        // The only external call in `super._propose` is the view read of the
        // token's clock, a staticcall that cannot reenter.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ProposalQuorumVoteDeadline(proposalId, quorumVoteDeadline);
    }

    /// Every public vote entry point (`castVote*`, `castVoteBySig`,
    /// `castVoteWithReasonAndParamsBySig`) funnels through this overload.
    /// Proposal state is still validated by the parent, so this only narrows
    /// when For and Abstain are accepted. An unknown proposal has no stored
    /// deadline and falls through to the parent's nonexistent-proposal error.
    function _castVote(uint256 proposalId, address account, uint8 support, string memory reason, bytes memory params)
        internal
        override
        returns (uint256)
    {
        if (support != uint8(VoteType.Against)) {
            uint256 quorumVoteDeadline = _quorumVoteDeadlines[proposalId];
            if (quorumVoteDeadline != 0 && clock() > quorumVoteDeadline) {
                revert QuorumVotingClosed(proposalId, quorumVoteDeadline);
            }
        }
        return super._castVote(proposalId, account, support, reason, params);
    }

    // ============== Required overrides =======================================

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
