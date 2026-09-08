// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import { LelantosToken } from "../../src/governance/LelantosToken.sol";
import { LelantosGovernor } from "../../src/governance/LelantosGovernor.sol";
import { ProtocolAdmin } from "../../src/governance/ProtocolAdmin.sol";
import { FeeBurner } from "../../src/burn/FeeBurner.sol";

/// Shared governance-stack deploy and KV logging, mirroring `BaseDeploy` and
/// `BaseSwapDeploy`.
///
/// This script transfers no ownership. Handover is a separate step
/// (`HandoverOwnership.s.sol`), since a Timelock-owned pool has no working
/// administrator until enough voting weight is delegated to pass a proposal.
abstract contract BaseGovernanceDeploy is Script {
    struct GovParams {
        string tokenName;
        string tokenSymbol;
        uint256 totalSupply;
        address tokenRecipient;
        uint256 timelockMinDelay;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumNumerator;
        /// Optional. Zero deploys the no-guardian variant.
        address guardian;
        address masp;
        address swapWrapper;
        uint16 burnBps;
        address secondaryTreasury;
        uint32 auctionHalfLife;
        uint8 auctionMaxHalvings;
        uint16 auctionRestartMultBps;
    }

    struct GovStack {
        LelantosToken token;
        TimelockController timelock;
        LelantosGovernor governor;
        FeeBurner burner;
        ProtocolAdmin admin;
    }

    function _requireCode(address a, string memory label) internal view {
        require(a.code.length != 0, label);
    }

    /// Deploys the stack and leaves the role table in its final shape.
    ///
    /// The deployer takes `DEFAULT_ADMIN_ROLE` on the Timelock and renounces it
    /// last. Predicting the Governor's address instead, as `BaseSwapDeploy` does
    /// for the wrapper, is unsafe here: a broadcast is a sequence of independent
    /// transactions, so a later `require` cannot roll back an earlier one, and a
    /// Timelock with a mispredicted proposer and no admin is unrecoverable. Every
    /// step before the renounce is recoverable.
    /// `deployer` temporarily holds the Timelock's `DEFAULT_ADMIN_ROLE` and then
    /// renounces it. It must be the address that sends the `grantRole` and
    /// `renounceRole` calls: `msg.sender` under `vm.startBroadcast`, or its own
    /// address for an in-process harness.
    function _deployGovernanceStack(GovParams memory p, address deployer) internal returns (GovStack memory s) {
        _requireCode(p.masp, "masp has no code");
        _requireCode(p.swapWrapper, "swapWrapper has no code");

        s.token = new LelantosToken(p.tokenName, p.tokenSymbol, p.totalSupply, p.tokenRecipient);

        address[] memory noProposers = new address[](0);
        address[] memory openExecutor = new address[](1); // address(0) = anyone may execute
        s.timelock = new TimelockController(p.timelockMinDelay, noProposers, openExecutor, deployer);

        s.governor = new LelantosGovernor(
            IVotes(address(s.token)), s.timelock, p.votingDelay, p.votingPeriod, p.proposalThreshold, p.quorumNumerator
        );

        s.timelock.grantRole(s.timelock.PROPOSER_ROLE(), address(s.governor));
        s.timelock.grantRole(s.timelock.CANCELLER_ROLE(), address(s.governor));
        // A guardian holding only CANCELLER may veto a queued proposal within
        // the delay window; it cannot propose or execute.
        if (p.guardian != address(0)) {
            s.timelock.grantRole(s.timelock.CANCELLER_ROLE(), p.guardian);
        }

        s.burner = new FeeBurner(
            s.token,
            address(s.timelock),
            p.auctionHalfLife,
            p.auctionMaxHalvings,
            p.auctionRestartMultBps,
            p.burnBps,
            p.secondaryTreasury
        );

        s.admin = new ProtocolAdmin(p.masp, p.swapWrapper, address(s.timelock), p.guardian);

        _assertRoles(s, p, deployer);

        // Last: every step above is recoverable, this one is not.
        s.timelock.renounceRole(s.timelock.DEFAULT_ADMIN_ROLE(), deployer);

        require(!s.timelock.hasRole(s.timelock.DEFAULT_ADMIN_ROLE(), deployer), "deployer still admin");
    }

    function _assertRoles(GovStack memory s, GovParams memory p, address deployer) private view {
        require(s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), address(s.governor)), "governor not proposer");
        require(s.timelock.hasRole(s.timelock.CANCELLER_ROLE(), address(s.governor)), "governor not canceller");
        require(s.timelock.hasRole(s.timelock.EXECUTOR_ROLE(), address(0)), "execution not open");
        require(s.timelock.hasRole(s.timelock.DEFAULT_ADMIN_ROLE(), address(s.timelock)), "timelock not self-admin");
        require(!s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), deployer), "deployer can propose");
        require(s.burner.owner() == address(s.timelock), "burner not owned by timelock");
        require(s.admin.hasRole(s.admin.DEFAULT_ADMIN_ROLE(), address(s.timelock)), "admin not governed");
        require(address(s.governor.token()) == address(s.token), "governor token mismatch");
        if (p.guardian != address(0)) {
            require(s.admin.hasRole(s.admin.GUARDIAN_ROLE(), p.guardian), "guardian not set");
            require(!s.admin.hasRole(s.admin.DEFAULT_ADMIN_ROLE(), p.guardian), "guardian over-privileged");
        }
    }

    /// KEY=value block, in the style `e2e/src/stack.ts` and
    /// `backend/stack/scripts/deploy-contracts.sh` scrape. New keys are additive.
    function _logGovKv(GovStack memory s) internal pure {
        console2.log(string.concat("GOV_TOKEN=", vm.toString(address(s.token))));
        console2.log(string.concat("TIMELOCK=", vm.toString(address(s.timelock))));
        console2.log(string.concat("GOVERNOR=", vm.toString(address(s.governor))));
        console2.log(string.concat("FEE_BURNER=", vm.toString(address(s.burner))));
        console2.log(string.concat("PROTOCOL_ADMIN=", vm.toString(address(s.admin))));
    }
}
