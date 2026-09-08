// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { LelantosToken } from "../../src/governance/LelantosToken.sol";
import { LelantosGovernor } from "../../src/governance/LelantosGovernor.sol";
import { ProtocolAdmin } from "../../src/governance/ProtocolAdmin.sol";
import { FeeBurner } from "../../src/burn/FeeBurner.sol";

import { MASPTestBase } from "../utils/MASPTestBase.sol";

/// Stands the whole governance stack up over a **real** `MASP` and a real
/// `SwapWrapper`, with ownership already handed over, so every lifecycle test
/// exercises the actual `onlyOwner` boundary rather than a mock of it.
///
/// Time handling: every warp in this suite targets an **absolute** timestamp read
/// back from the Governor (`proposalSnapshot`, `proposalDeadline`, `proposalEta`).
/// Under `via_ir` the optimizer may cache `block.timestamp` within a call — legal,
/// since it cannot change mid-transaction — which `vm.warp` then invalidates, so
/// `vm.warp(block.timestamp + n)` silently misbehaves in a test body.
abstract contract GovTestBase is MASPTestBase {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint48 internal constant VOTING_DELAY = 2 days;
    uint32 internal constant VOTING_PERIOD = 7 days;
    uint256 internal constant PROPOSAL_THRESHOLD = 2_500_000e18;
    uint256 internal constant QUORUM_NUMERATOR = 3;
    uint256 internal constant TIMELOCK_DELAY = 3 days;

    uint32 internal constant HALF_LIFE = 1 hours;
    uint8 internal constant MAX_HALVINGS = 12;
    uint16 internal constant RESTART_MULT_BPS = 20_000;
    uint16 internal constant BURN_BPS = 10_000;

    /// Deploy-time genesis time, so warps have somewhere to start.
    uint256 internal constant T0 = 1_000_000;

    LelantosToken internal gov;
    TimelockController internal timelock;
    LelantosGovernor internal governor;
    ProtocolAdmin internal protocolAdmin;
    FeeBurner internal burner;
    SwapWrapper internal wrapper;

    address internal distributor = makeAddr("distributor");
    address internal guardian = makeAddr("guardian");
    address internal voter1 = makeAddr("voter1");
    address internal voter2 = makeAddr("voter2");
    address internal voter3 = makeAddr("voter3");

    function setUp() public virtual override {
        super.setUp();
        vm.warp(T0);

        gov = new LelantosToken("Lelantos", "LNT", SUPPLY, distributor);

        // Deployed with the test contract as admin, exactly as the script does, so
        // the roles can be wired and then the admin renounced as the last step.
        timelock = new TimelockController(TIMELOCK_DELAY, new address[](0), _openExecutor(), address(this));

        governor = new LelantosGovernor(
            IVotes(address(gov)), timelock, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_NUMERATOR
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), guardian);

        burner = new FeeBurner(gov, address(timelock), HALF_LIFE, MAX_HALVINGS, RESTART_MULT_BPS, BURN_BPS, address(0));

        wrapper = new SwapWrapper(
            IMASPPool(address(masp)), IAllowanceTransfer(address(permit2)), address(this), address(burner)
        );

        protocolAdmin = new ProtocolAdmin(address(masp), address(wrapper), address(timelock), guardian);

        // Handover, in the order the real runbook uses: treasuries first, so the
        // first fee routing needs no proposal, then ownership.
        vm.startPrank(OWNER);
        masp.setTreasury(address(burner));
        masp.transferOwnership(address(protocolAdmin));
        vm.stopPrank();
        wrapper.transferOwnership(address(protocolAdmin));

        // Last: the deployer gives up its foothold.
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        _distributeAndDelegate();
    }

    /// `EXECUTOR_ROLE` held by `address(0)` = anyone may execute a matured
    /// operation. Execution carries no discretion, only liveness.
    function _openExecutor() private pure returns (address[] memory e) {
        e = new address[](1);
        e[0] = address(0);
    }

    /// 20% of supply to each of three voters, all self-delegated. Well clear of
    /// both the proposal threshold and a 3% quorum.
    function _distributeAndDelegate() private {
        vm.startPrank(distributor);
        gov.transfer(voter1, SUPPLY / 5);
        gov.transfer(voter2, SUPPLY / 5);
        gov.transfer(voter3, SUPPLY / 5);
        vm.stopPrank();

        vm.prank(voter1);
        gov.delegate(voter1);
        vm.prank(voter2);
        gov.delegate(voter2);
        vm.prank(voter3);
        gov.delegate(voter3);

        // Delegation must be strictly in the past before it counts anywhere.
        vm.warp(T0 + 1);
    }

    // ============== Proposal helpers =========================================

    function _one(address target, bytes memory data)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        calldatas[0] = data;
    }

    /// Calls `ProtocolAdmin.execute(target, data)` through the full pipeline.
    function _passAdminCall(address target, bytes memory data, string memory description) internal returns (uint256) {
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(address(protocolAdmin), abi.encodeCall(ProtocolAdmin.execute, (target, data)));
        return _passProposal(t, v, c, description);
    }

    /// Propose → vote → queue → execute, warping to each absolute deadline.
    function _passProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 id) {
        id = _proposeAndSucceed(targets, values, calldatas, description);
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.warp(governor.proposalEta(id) + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    /// Propose and carry it to `Succeeded`, stopping before `queue`.
    function _proposeAndSucceed(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 id) {
        vm.prank(voter1);
        id = governor.propose(targets, values, calldatas, description);
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(voter1);
        governor.castVote(id, 1);
        vm.prank(voter2);
        governor.castVote(id, 1);
        vm.warp(governor.proposalDeadline(id) + 1);
    }
}
