// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";

import { GovTestBase } from "./GovTestBase.sol";

/// Quorum is a fraction of total supply, not of delegated supply, because
/// `Votes._transferVotingUnits` checkpoints the total only on mint and burn.
/// Idle and unclaimed tokens are therefore part of the denominator, which can
/// leave governance unable to reach quorum.
contract GovernorQuorumTest is GovTestBase {
    address internal small = makeAddr("small");

    function _fund(address who, uint256 amount) internal {
        _giveVotes(who, amount);
        // Weight only counts from a strictly earlier timepoint.
        vm.warp(T0 + 100);
    }

    function test_quorumIsFractionOfTotalSupply() public view {
        uint256 expected = SUPPLY * QUORUM_NUMERATOR / 100;
        assertEq(governor.quorum(T0), expected);
        assertEq(governor.quorumNumerator(), QUORUM_NUMERATOR);
        assertEq(governor.quorumDenominator(), 100);
    }

    /// Supply held undelegated by the distributor still counts in the
    /// denominator, so a proposal backed by every vote cast can fail.
    function test_undelegatedSupplyCountsInTheDenominatorSoAThinVoteFails() public {
        // 1% of supply: above the 0.25% proposal threshold, below the 3% quorum.
        _fund(small, SUPPLY / 100);

        uint256 id = _proposeAndVote(small, 1, "thin support");

        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, SUPPLY / 100, "all of the voter's weight was cast");
        assertLt(forVotes, governor.quorum(governor.proposalSnapshot(id)), "should be under quorum");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated), "thin vote must not pass");
    }

    function test_exactlyAtQuorumSucceeds() public {
        _fund(small, SUPPLY * QUORUM_NUMERATOR / 100);
        uint256 id = _proposeAndVote(small, 1, "exactly quorum");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_oneWeiBelowQuorumIsDefeated() public {
        _fund(small, SUPPLY * QUORUM_NUMERATOR / 100 - 1);
        uint256 id = _proposeAndVote(small, 1, "one wei short");
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    /// `GovernorCountingSimple`: abstain counts toward quorum but not toward the
    /// For/Against comparison.
    function test_abstainCountsTowardQuorumButNotSupport() public {
        _fund(small, SUPPLY * QUORUM_NUMERATOR / 100);
        uint256 id = _proposeAndVote(small, 2, "abstain only");

        (, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(id);
        assertEq(forVotes, 0);
        assertEq(abstainVotes, SUPPLY * QUORUM_NUMERATOR / 100);
        // Quorum reached, but zero For votes fails the `forVotes > againstVotes`
        // test, so it is defeated rather than succeeded.
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    /// Weight is snapshotted: tokens acquired and delegated after the snapshot
    /// carry no votes. This makes the Governor flash-loan resistant.
    function test_weightAcquiredAfterSnapshotDoesNotCount() public {
        _fund(small, SUPPLY / 100);
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _cancelDelayPayload();
        vm.prank(small);
        uint256 id = governor.propose(t, v, c, "late whale");

        vm.warp(governor.proposalSnapshot(id) + 1);

        // A large holder acquires tokens after the snapshot and self-delegates.
        address whale = makeAddr("whale");
        _giveVotes(whale, SUPPLY / 4);

        vm.prank(whale);
        governor.castVote(id, 1);

        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, 0, "post-snapshot weight must be worthless");
    }

    /// Delegating and proposing inside one transaction cannot meet the threshold:
    /// `propose` reads `getVotes(proposer, clock() - 1)`, and the fresh delegation
    /// checkpoints at `clock()`. Together with snapshotting, this prevents
    /// flash-loan governance.
    function test_delegateAndProposeInSameTimestampCannotMeetThreshold() public {
        address borrower = makeAddr("borrower");
        vm.prank(distributor);
        gov.transfer(borrower, SUPPLY / 4);

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _cancelDelayPayload();

        vm.startPrank(borrower);
        gov.delegate(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorInsufficientProposerVotes.selector, borrower, 0, PROPOSAL_THRESHOLD
            )
        );
        governor.propose(t, v, c, "flash proposal");
        vm.stopPrank();
    }

    /// Burning lowers total supply, so the absolute quorum threshold falls with
    /// it, as intended for a deflationary supply.
    function test_burningLowersTheQuorumBar() public {
        vm.warp(T0 + 100);
        uint256 before = governor.quorum(T0 + 99);

        vm.prank(distributor);
        gov.burn(SUPPLY / 10);

        vm.warp(T0 + 200);
        uint256 afterBurn = governor.quorum(T0 + 199);

        assertLt(afterBurn, before, "quorum did not fall with supply");
        assertEq(afterBurn, (SUPPLY - SUPPLY / 10) * QUORUM_NUMERATOR / 100);
    }

    function test_quorumNumeratorOnlyChangesByProposal() public {
        vm.expectRevert();
        governor.updateQuorumNumerator(10);

        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(governor), abi.encodeCall(governor.updateQuorumNumerator, (10)));
        _passProposal(t, v, c, "raise quorum to 10%");
        assertEq(governor.quorumNumerator(), 10);
    }
}
