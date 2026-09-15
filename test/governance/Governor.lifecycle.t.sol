// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { FeeConfig } from "../../src/FeeConfig.sol";
import { MASP } from "../../src/MASP.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { ProtocolAdmin } from "../../src/governance/ProtocolAdmin.sol";

import { GovTestBase } from "./GovTestBase.sol";

/// End-to-end governance control of the pool: a proposal travels the full
/// Governor → Timelock → ProtocolAdmin → MASP path and changes real pool state.
contract GovernorLifecycleTest is GovTestBase {
    function test_handoverPutsThePoolUnderGovernance() public view {
        assertEq(masp.owner(), address(protocolAdmin), "pool owner");
        assertEq(wrapper.owner(), address(protocolAdmin), "wrapper owner");
        assertEq(masp.treasury(), address(burner), "pool treasury");
        assertEq(wrapper.treasury(), address(burner), "wrapper treasury");
        assertTrue(protocolAdmin.hasRole(protocolAdmin.DEFAULT_ADMIN_ROLE(), address(timelock)));
    }

    /// After handover the previous owner has no administrative access.
    function test_formerOwnerCanNoLongerAdminister() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        masp.setAssetFee(ASSET_ID, 50, 60);
    }

    function test_proposalChangesAssetFeeOnTheRealPool() public {
        _passAdminCall(
            address(masp), abi.encodeCall(AssetRegistry.setAssetFee, (ASSET_ID, 50, 60)), "set asset fee to 50/60"
        );

        // The deposit rate lands with the proposal; the raised withdraw rate is
        // queued behind the exit-term notice and lands at the commit.
        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, 50);
        assertLt(wit, 60, "withdraw raise applied without notice");

        vm.warp(vm.getBlockTimestamp() + ExitTerms.DELAY);
        masp.commitExitTerms(ASSET_ID);
        (, wit) = masp.assetFees(ASSET_ID);
        assertEq(wit, 60);
    }

    /// Lengthening the cancel delay is a raise: the proposal queues it and the
    /// permissionless commit lands it after the notice.
    function test_proposalChangesCancelDelay() public {
        _passAdminCall(address(masp), abi.encodeCall(MASP.setCancelDelay, (10_000)), "set cancel delay");
        assertEq(masp.cancelDelay(), 7_200, "raise applied without notice");

        vm.warp(vm.getBlockTimestamp() + ExitTerms.DELAY);
        masp.commitExitTerms(ASSET_ID);
        assertEq(masp.cancelDelay(), 10_000);
    }

    function test_proposalRepointsTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        _passAdminCall(address(masp), abi.encodeCall(FeeConfig.setTreasury, (newTreasury)), "repoint treasury");
        assertEq(masp.treasury(), newTreasury);
    }

    function test_proposalAllowlistsSwapAdapter() public {
        address adapter = makeAddr("adapter");
        _passAdminCall(
            address(wrapper), abi.encodeCall(SwapWrapper.setAdapterAllowed, (adapter, true)), "allow adapter"
        );
        assertTrue(wrapper.adapterAllowed(adapter));
    }

    /// Walks every state transition: `state()` is overridden across `Governor`
    /// and `GovernorTimelockControl`, and an incorrect override desyncs the
    /// pipeline. The payload shortens the delay, which applies on execution.
    function test_proposalStateProgression() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(protocolAdmin),
            abi.encodeCall(ProtocolAdmin.execute, (address(masp), abi.encodeCall(MASP.setCancelDelay, (4_000))))
        );
        string memory desc = "state progression";
        bytes32 h = keccak256(bytes(desc));

        vm.prank(voter1);
        uint256 id = governor.propose(t, v, c, desc);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Pending));

        vm.warp(governor.proposalSnapshot(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Active));

        vm.prank(voter1);
        governor.castVote(id, 1);
        vm.prank(voter2);
        governor.castVote(id, 1);

        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Succeeded));

        governor.queue(t, v, c, h);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Queued));

        vm.warp(governor.proposalEta(id) + 1);
        governor.execute(t, v, c, h);
        assertEq(uint8(governor.state(id)), uint8(IGovernor.ProposalState.Executed));
        assertEq(masp.cancelDelay(), 4_000);
    }

    // ============== Negatives ================================================

    function test_proposeBelowThresholdReverts() public {
        address nobody = makeAddr("nobody");
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(address(masp), "");
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, nobody, 0, PROPOSAL_THRESHOLD)
        );
        governor.propose(t, v, c, "no weight");
    }

    function test_executeBeforeTimelockDelayReverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(protocolAdmin),
            abi.encodeCall(ProtocolAdmin.execute, (address(masp), abi.encodeCall(MASP.setCancelDelay, (9_000))))
        );
        string memory desc = "too early";
        bytes32 h = keccak256(bytes(desc));

        uint256 id = _proposeAndSucceed(t, v, c, desc);
        governor.queue(t, v, c, h);
        // One second short of the eta.
        vm.warp(governor.proposalEta(id) - 1);
        vm.expectRevert();
        governor.execute(t, v, c, h);
    }

    function test_doubleExecuteReverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(protocolAdmin),
            abi.encodeCall(ProtocolAdmin.execute, (address(masp), abi.encodeCall(MASP.setCancelDelay, (9_500))))
        );
        string memory desc = "once only";
        bytes32 h = keccak256(bytes(desc));

        uint256 id = _proposeAndSucceed(t, v, c, desc);
        governor.queue(t, v, c, h);
        vm.warp(governor.proposalEta(id) + 1);
        governor.execute(t, v, c, h);

        vm.expectRevert();
        governor.execute(t, v, c, h);
    }

    // ============== Ownership-destroying calls ===============================

    /// `renounceOwnership` leaves the pool without an owner, so it is unreachable
    /// even by a proposal that passes.
    function test_proposalCannotRenounceOwnership() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(protocolAdmin),
            abi.encodeCall(ProtocolAdmin.execute, (address(masp), abi.encodeCall(Ownable.renounceOwnership, ())))
        );
        string memory desc = "renounce";
        _proposeAndSucceed(t, v, c, desc);
        governor.queue(t, v, c, keccak256(bytes(desc)));
        vm.warp(governor.proposalEta(_id(t, v, c, desc)) + 1);

        vm.expectRevert();
        governor.execute(t, v, c, keccak256(bytes(desc)));
        assertEq(masp.owner(), address(protocolAdmin), "owner survived");
    }

    /// `transferOwnership` is blocked as well as `renounceOwnership`: it refuses
    /// only `address(0)`, and a transfer to a burn address has the same effect.
    function test_proposalCannotTransferOwnershipToBurnAddress() public {
        address dead = address(0xdEaD);
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(
            address(protocolAdmin),
            abi.encodeCall(ProtocolAdmin.execute, (address(masp), abi.encodeCall(Ownable.transferOwnership, (dead))))
        );
        string memory desc = "transfer to dead";
        _proposeAndSucceed(t, v, c, desc);
        governor.queue(t, v, c, keccak256(bytes(desc)));
        vm.warp(governor.proposalEta(_id(t, v, c, desc)) + 1);

        vm.expectRevert();
        governor.execute(t, v, c, keccak256(bytes(desc)));
        assertEq(masp.owner(), address(protocolAdmin), "owner survived");
    }

    function _id(address[] memory t, uint256[] memory v, bytes[] memory c, string memory d)
        private
        view
        returns (uint256)
    {
        return governor.hashProposal(t, v, c, keccak256(bytes(d)));
    }
}
