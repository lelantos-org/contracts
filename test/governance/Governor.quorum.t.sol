// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";

import { MASP } from "../../src/MASP.sol";
import { ProtocolAdmin } from "../../src/governance/ProtocolAdmin.sol";

import { GovTestBase } from "./GovTestBase.sol";

/// Quorum is a fraction of **total supply**, not of delegated supply, because
/// `Votes._transferVotingUnits` checkpoints the total only on mint and burn. That
/// makes idle and unclaimed tokens part of the denominator, which is the single
/// most common way a launch ends up unable to pass anything.
contract GovernorQuorumTest is GovTestBase {
    address internal small = makeAddr("small");

    function _fund(address who, uint256 amount) internal {
        vm.prank(distributor);
        gov.transfer(who, amount);
        vm.prank(who);
        gov.delegate(who);
        // Weight only counts from a strictly earlier timepoint.
        vm.warp(T0 + 100);
    }

    function _proposeAndVote(address voter, uint8 support, string memory desc) internal returns (uint256 id) {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(protocolAdmin),
            abi.encodeCall(ProtocolAdmin.execute, (address(masp), abi.encodeCall(MASP.setCancelDelay, (9_000))))
        );
        vm.prank(voter);
        id = governor.propose(t, v, c, desc);
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(voter);
        governor.castVote(id, support);
        vm.warp(governor.proposalDeadline(id) + 1);
    }

    function test_quorumIsFractionOfTotalSupply() public view {
        uint256 expected = SUPPLY * QUORUM_NUMERATOR / 100;
        assertEq(governor.quorum(T0), expected);
        assertEq(governor.quorumNumerator(), QUORUM_NUMERATOR);
        assertEq(governor.quorumDenominator(), 100);
    }

    /// The trap, made explicit: 40% of supply sits undelegated with the
    /// distributor and still counts in the denominator. A proposal backed by every
    /// vote *cast* can still fail.
    function test_undelegatedSupplyCountsInTheDenominatorSoAThinVoteFails() public {
        // 1% of supply — comfortably over the 0.25% proposal threshold, but under
        // the 3% quorum.
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

    /// Weight is snapshotted. Acquiring and delegating a fortune after the
    /// snapshot buys nothing — this is the property that makes the Governor
    /// flash-loan resistant, so it is asserted rather than assumed.
    function test_weightAcquiredAfterSnapshotDoesNotCount() public {
        _fund(small, SUPPLY / 100);
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(protocolAdmin),
            abi.encodeCall(ProtocolAdmin.execute, (address(masp), abi.encodeCall(MASP.setCancelDelay, (9_000))))
        );
        vm.prank(small);
        uint256 id = governor.propose(t, v, c, "late whale");

        vm.warp(governor.proposalSnapshot(id) + 1);

        // A whale arrives after the snapshot and delegates to itself.
        address whale = makeAddr("whale");
        vm.prank(distributor);
        gov.transfer(whale, SUPPLY / 4);
        vm.prank(whale);
        gov.delegate(whale);

        vm.prank(whale);
        governor.castVote(id, 1);

        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, 0, "post-snapshot weight must be worthless");
    }

    /// Delegating and proposing inside one transaction cannot meet the threshold:
    /// `propose` reads `getVotes(proposer, clock() - 1)`, and the fresh delegation
    /// checkpoints at `clock()`. This is the second half of the flash-loan story.
    function test_delegateAndProposeInSameTimestampCannotMeetThreshold() public {
        address borrower = makeAddr("borrower");
        vm.prank(distributor);
        gov.transfer(borrower, SUPPLY / 4);

        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(protocolAdmin),
            abi.encodeCall(ProtocolAdmin.execute, (address(masp), abi.encodeCall(MASP.setCancelDelay, (9_000))))
        );

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

    /// Burning lowers total supply, so the absolute quorum bar falls with it —
    /// the intended behaviour for a deflationary supply, and the direct link
    /// between the burner and governance.
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
