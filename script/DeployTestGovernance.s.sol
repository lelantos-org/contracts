// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BaseGovernanceDeploy } from "./base/BaseGovernanceDeploy.s.sol";

/// Test/anvil governance stack: the same `BaseGovernanceDeploy` path as
/// `DeployGovernance.s.sol`, with short timings so a proposal can go from
/// `propose` to `execute` in minutes against a local chain. Run after
/// `DeployTest.s.sol` and `DeployTestSwap.s.sol`, whose KEY=value output
/// supplies the env vars below.
///
/// Required env:
///   MASP                — MASP address (must have code)
///   SWAP_WRAPPER        — SwapWrapper address (must have code)
///   GOV_TOKEN_RECIPIENT — receives the entire LNT supply; use a funded dev
///                         account so it can delegate and propose
///
/// Optional (defaults in seconds, timestamp clock):
///   GOV_VOTING_DELAY       — 1
///   GOV_VOTING_PERIOD      — 300
///   GOV_QUORUM_VOTE_CUTOFF — 60; For/Abstain close this long before the
///                            deadline, Against stays open to it
///   GOV_TIMELOCK_DELAY     — 60
///   GOV_PROPOSAL_THRESHOLD — 1e18 (1 LNT)
///   GOV_QUORUM_NUMERATOR   — 1 (percent of total supply)
///
/// Fixed: token "Lelantos"/"LNT" with 1e27 supply, and `FeeBurner` parameters
/// mirroring `mainnet.gov.example.json` (burn everything, 1 h half-life, 12
/// halvings, 2x restart), since auction timing is not what a dev stack
/// exercises.
///
/// No guardian (`address(0)`): the Timelock gets no extra canceller and
/// `ProtocolAdmin` no guardian role, so every administrative action on the dev
/// stack goes through a proposal, as the no-guardian mainnet variant does.
///
/// Like `DeployGovernance.s.sol` this transfers no ownership:
/// `HandoverOwnership.s.sol` is not run, so MASP and SwapWrapper stay with
/// their dev owners and the rest of the local stack keeps working unchanged.
contract DeployTestGovernance is BaseGovernanceDeploy {
    function run() external returns (address token, address timelock, address governor, address burner, address admin) {
        GovParams memory p;
        p.tokenName = "Lelantos";
        p.tokenSymbol = "LNT";
        p.totalSupply = 1_000_000_000e18;
        p.tokenRecipient = vm.envAddress("GOV_TOKEN_RECIPIENT");
        p.masp = vm.envAddress("MASP");
        p.swapWrapper = vm.envAddress("SWAP_WRAPPER");

        uint256 votingDelay = vm.envOr("GOV_VOTING_DELAY", uint256(1));
        uint256 votingPeriod = vm.envOr("GOV_VOTING_PERIOD", uint256(300));
        uint256 quorumVoteCutoff = vm.envOr("GOV_QUORUM_VOTE_CUTOFF", uint256(60));
        require(votingDelay <= type(uint48).max, "GOV_VOTING_DELAY overflows uint48");
        require(votingPeriod <= type(uint32).max, "GOV_VOTING_PERIOD overflows uint32");
        require(quorumVoteCutoff < votingPeriod, "GOV_QUORUM_VOTE_CUTOFF not below GOV_VOTING_PERIOD");
        p.votingDelay = uint48(votingDelay);
        p.votingPeriod = uint32(votingPeriod);
        p.quorumVoteCutoff = uint32(quorumVoteCutoff);

        p.timelockMinDelay = vm.envOr("GOV_TIMELOCK_DELAY", uint256(60));
        p.proposalThreshold = vm.envOr("GOV_PROPOSAL_THRESHOLD", uint256(1e18));
        p.quorumNumerator = vm.envOr("GOV_QUORUM_NUMERATOR", uint256(1));
        require(p.quorumNumerator > 0 && p.quorumNumerator <= 100, "GOV_QUORUM_NUMERATOR out of range");
        require(p.proposalThreshold < p.totalSupply, "GOV_PROPOSAL_THRESHOLD exceeds supply");

        p.guardian = address(0);
        p.burnBps = 10_000;
        p.secondaryTreasury = address(0);
        p.auctionHalfLife = 1 hours;
        p.auctionMaxHalvings = 12;
        p.auctionRestartMultBps = 20_000;

        vm.startBroadcast();
        // Under broadcast, `msg.sender` is the broadcaster, which sends the role
        // calls.
        GovStack memory s = _deployGovernanceStack(p, msg.sender);
        vm.stopBroadcast();

        _logGovKv(s);

        return (address(s.token), address(s.timelock), address(s.governor), address(s.burner), address(s.admin));
    }
}
