// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { MASP } from "../../src/MASP.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { LelantosToken } from "../../src/governance/LelantosToken.sol";
import { LelantosGovernor } from "../../src/governance/LelantosGovernor.sol";
import { FeeBurner } from "../../src/burn/FeeBurner.sol";

import { GovConstants } from "../utils/GovConstants.sol";
import { MASPTestBase } from "../utils/MASPTestBase.sol";
import { TEST_PROXY_ADMIN } from "../utils/PoolDeployer.sol";

/// Deploys the governance stack over a real `MASP` and `SwapWrapper` with
/// ownership and the pool's proxy admin handed to the Timelock, so lifecycle
/// tests exercise the production `onlyOwner` and `onlyAdmin` boundaries.
///
/// Deliberately not built on `BaseGovernanceDeploy._deployGovernanceStack`: that
/// path requires the `SwapWrapper` to exist before the burner, so the wrapper
/// could not take the burner as its treasury, and it can only run inside a
/// separate `Script` harness, which would become the deployer instead of this
/// contract. `test/deploy/DeployGovernance.t.sol` covers the script itself.
///
/// Every warp targets an absolute timestamp read back from the Governor
/// (`proposalSnapshot`, `proposalDeadline`, `proposalEta`). Under `via_ir` the
/// optimizer may cache `block.timestamp` within a call, which `vm.warp`
/// invalidates, so `vm.warp(block.timestamp + n)` is unreliable in a test body.
abstract contract GovTestBase is MASPTestBase {
    uint256 internal constant SUPPLY = GovConstants.SUPPLY;
    uint48 internal constant VOTING_DELAY = 2 days;
    uint32 internal constant VOTING_PERIOD = 7 days;
    uint32 internal constant QUORUM_VOTE_CUTOFF = 1 days;
    uint256 internal constant PROPOSAL_THRESHOLD = 2_500_000e18;
    uint256 internal constant QUORUM_NUMERATOR = 3;
    uint256 internal constant TIMELOCK_DELAY = 3 days;

    uint32 internal constant HALF_LIFE = GovConstants.HALF_LIFE;
    uint8 internal constant MAX_HALVINGS = GovConstants.MAX_HALVINGS;
    uint16 internal constant RESTART_MULT_BPS = GovConstants.RESTART_MULT_BPS;
    uint16 internal constant BURN_BPS = GovConstants.BURN_BPS;

    /// `GovernorCountingSimple` vote types.
    uint8 internal constant AGAINST = 0;
    uint8 internal constant FOR = 1;
    uint8 internal constant ABSTAIN = 2;

    /// Genesis timestamp at deploy; the base for absolute warps.
    uint256 internal constant T0 = 1_000_000;

    LelantosToken internal gov;
    TimelockController internal timelock;
    LelantosGovernor internal governor;
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

        // Deployed with the test contract as admin, as the deploy script does, so
        // the roles can be wired and the admin renounced as the last step.
        timelock = new TimelockController(TIMELOCK_DELAY, new address[](0), _openExecutor(), address(this));

        governor = new LelantosGovernor(
            IVotes(address(gov)),
            timelock,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_NUMERATOR,
            QUORUM_VOTE_CUTOFF
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        // The guardian holds `CANCELLER_ROLE` only: it may veto a queued
        // proposal within the delay, and has no power over the pool.
        timelock.grantRole(timelock.CANCELLER_ROLE(), guardian);

        burner = new FeeBurner(gov, address(timelock), HALF_LIFE, MAX_HALVINGS, RESTART_MULT_BPS, BURN_BPS, address(0));

        wrapper = new SwapWrapper(
            IMASPPool(address(masp)), IAllowanceTransfer(address(permit2)), address(this), address(burner)
        );

        // Handover in the runbook order: treasuries first, so the first fee
        // routing needs no proposal, then ownership.
        vm.startPrank(OWNER);
        masp.setTreasury(address(burner));
        masp.transferOwnership(address(timelock));
        vm.stopPrank();
        wrapper.transferOwnership(address(timelock));
        // Then the proxy admin, as `HandoverOwnership.s.sol` does last.
        vm.prank(TEST_PROXY_ADMIN);
        _poolProxy().changeProxyAdmin(address(timelock));

        // Last step: the deployer renounces its admin role.
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        _distributeAndDelegate();
    }

    /// `EXECUTOR_ROLE` held by `address(0)` lets anyone execute a matured
    /// operation. Execution carries no discretion, only liveness.
    function _openExecutor() private pure returns (address[] memory e) {
        e = new address[](1);
        e[0] = address(0);
    }

    /// Transfers 20% of supply to each of three self-delegated voters, above
    /// both the proposal threshold and the 3% quorum.
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

        // Delegated weight counts only from a strictly earlier timepoint.
        vm.warp(T0 + 1);
    }

    /// The pool's proxy surface, which answers its reserved selectors itself.
    function _poolProxy() internal view returns (DelayedUpgradeProxy) {
        return DelayedUpgradeProxy(payable(address(masp)));
    }

    // ============== Voting weight ===========================================

    /// Transfers `amount` from the distributor to `who`, who self-delegates. The
    /// weight counts only from a strictly later timepoint, so callers warp before
    /// a snapshot that must include it.
    function _giveVotes(address who, uint256 amount) internal {
        vm.prank(distributor);
        gov.transfer(who, amount);
        vm.prank(who);
        gov.delegate(who);
    }

    // ============== Proposal payloads ========================================

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

    /// A single owner-gated call on `target`, the shape of every proposal that
    /// reaches an owned contract. The Timelock is the owner, so the call is
    /// direct: there is no interposed admin to route through.
    function _adminCall(address target, bytes memory data)
        internal
        pure
        returns (address[] memory, uint256[] memory, bytes[] memory)
    {
        return _one(target, data);
    }

    /// A proposal whose content is irrelevant, for tests about voting and timing
    /// rather than the payload.
    function _cancelDelayPayload() internal view returns (address[] memory, uint256[] memory, bytes[] memory) {
        return _adminCall(address(masp), abi.encodeCall(MASP.setCancelDelay, (9_000)));
    }

    // ============== Proposal pipeline ========================================

    /// Calls `target` as the owner through the full proposal pipeline.
    function _passAdminCall(address target, bytes memory data, string memory description) internal returns (uint256) {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _adminCall(target, data);
        return _passProposal(t, v, c, description);
    }

    /// Propose → vote → queue → execute, warping to each absolute deadline.
    function _passProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 id) {
        id = _queueToEta(targets, values, calldatas, description);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    /// Proposes, votes, queues and warps one second past the eta, leaving
    /// `execute` to the caller so it can expect a revert or execute by another
    /// path.
    function _queueToEta(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 id) {
        id = _proposeAndSucceed(targets, values, calldatas, description);
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.warp(governor.proposalEta(id) + 1);
    }

    /// Proposes and votes through to `Succeeded`, stopping before `queue`.
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

    /// `voter1` proposes `_cancelDelayPayload`, leaving the proposal `Pending`.
    function _proposeCancelDelay(string memory description) internal returns (uint256 id) {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _cancelDelayPayload();
        vm.prank(voter1);
        id = governor.propose(t, v, c, description);
    }

    /// `voter` proposes `_cancelDelayPayload` and alone casts `support` on it,
    /// then the voting period ends, so the outcome rests on that one vote.
    function _proposeAndVote(address voter, uint8 support, string memory description) internal returns (uint256 id) {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _cancelDelayPayload();
        vm.prank(voter);
        id = governor.propose(t, v, c, description);
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(voter);
        governor.castVote(id, support);
        vm.warp(governor.proposalDeadline(id) + 1);
    }
}
