// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BaseGovernanceDeploy } from "./base/BaseGovernanceDeploy.s.sol";

/// Governance-stack deploy against an already-deployed MASP and SwapWrapper.
/// Ethereum mainnet only (chain id 1); reverts on any other chain.
///
/// Deploys `LelantosToken`, `TimelockController`, `LelantosGovernor`,
/// `FeeBurner` and `ProtocolAdmin`, wires the Timelock role table, and renounces
/// the deployer's admin as the final transaction.
///
/// It does not hand the pool over; that is `HandoverOwnership.s.sol`, to be run
/// only once delegated voting weight exists. A Timelock-owned pool with no
/// delegated weight has no working administrator.
///
/// Config schema (`GOV_CONFIG`, default `script/config/mainnet.gov.json`):
///   {
///     "tokenName":             "Lelantos",
///     "tokenSymbol":           "LNT",
///     "totalSupply":           "1000000000000000000000000000",  1e27
///     "tokenRecipient":        "0x...",  receives the entire supply
///     "timelockMinDelay":      259200,   3 days
///     "votingDelay":           172800,   2 days, in seconds (timestamp clock)
///     "votingPeriod":          604800,   7 days
///     "quorumVoteCutoff":      86400,    1 day; For/Abstain close this long before the deadline
///     "proposalThreshold":     "2500000000000000000000000",     0.25%
///     "quorumNumerator":       3,        percent of total supply, see below
///     "guardian":              "0x...",  optional; address(0) = no guardian
///     "masp":                  "0x...",  must have code
///     "swapWrapper":           "0x...",  must have code
///     "burnBps":               10000,    10000 = burn every GOV taken in
///     "secondaryTreasury":     "0x...",  required only when burnBps < 10000
///     "auctionHalfLife":       3600,
///     "auctionMaxHalvings":    12,
///     "auctionRestartMultBps": 20000     2x on a full fill, scaled by fill size
///   }
///
/// Quorum guidance: the denominator is total supply, not delegated supply;
/// `Votes` checkpoints the total only on mint and burn. Undelegated tokens in a
/// treasury or an unclaimed airdrop still count, so the effective threshold
/// against the active float is higher than the numerator suggests. Start low
/// (3) and raise by proposal once the distribution is known; a quorum set too
/// high cannot be lowered, because lowering it requires passing a proposal.
///
/// Auction guidance: seed prices are set per token after deploy via
/// `FeeBurner.setLot`, and every lot starts disabled. Enable one lot first,
/// observe a few clears, then calibrate the rest from the observed ratio. Seed
/// high: too high only delays the first sale, while too low sells below value
/// once before the ratchet corrects.
contract DeployGovernance is BaseGovernanceDeploy {
    string constant DEFAULT_CONFIG = "script/config/mainnet.gov.json";

    function run() external returns (address token, address timelock, address governor, address burner, address admin) {
        // Governance lives on Ethereum mainnet only; the other chains' pools are
        // not governed by it. A mainnet fork keeps chain id 1, so rehearsals pass.
        require(block.chainid == 1, "governance is Ethereum mainnet only");
        string memory path = vm.envOr("GOV_CONFIG", DEFAULT_CONFIG);
        string memory j = vm.readFile(path);

        GovParams memory p;
        p.tokenName = vm.parseJsonString(j, ".tokenName");
        p.tokenSymbol = vm.parseJsonString(j, ".tokenSymbol");
        p.totalSupply = vm.parseJsonUint(j, ".totalSupply");
        p.tokenRecipient = vm.parseJsonAddress(j, ".tokenRecipient");
        p.timelockMinDelay = vm.parseJsonUint(j, ".timelockMinDelay");
        p.votingDelay = uint48(vm.parseJsonUint(j, ".votingDelay"));
        p.votingPeriod = uint32(vm.parseJsonUint(j, ".votingPeriod"));
        p.quorumVoteCutoff = uint32(vm.parseJsonUint(j, ".quorumVoteCutoff"));
        p.proposalThreshold = vm.parseJsonUint(j, ".proposalThreshold");
        p.quorumNumerator = vm.parseJsonUint(j, ".quorumNumerator");
        p.guardian = vm.parseJsonAddress(j, ".guardian");
        p.masp = vm.parseJsonAddress(j, ".masp");
        p.swapWrapper = vm.parseJsonAddress(j, ".swapWrapper");
        p.burnBps = uint16(vm.parseJsonUint(j, ".burnBps"));
        p.secondaryTreasury = vm.parseJsonAddress(j, ".secondaryTreasury");
        p.auctionHalfLife = uint32(vm.parseJsonUint(j, ".auctionHalfLife"));
        p.auctionMaxHalvings = uint8(vm.parseJsonUint(j, ".auctionMaxHalvings"));
        p.auctionRestartMultBps = uint16(vm.parseJsonUint(j, ".auctionRestartMultBps"));

        require(p.quorumNumerator > 0 && p.quorumNumerator <= 100, "quorumNumerator out of range");
        require(p.proposalThreshold < p.totalSupply, "threshold exceeds supply");
        require(p.quorumVoteCutoff < p.votingPeriod, "quorumVoteCutoff not below votingPeriod");

        vm.startBroadcast();
        // Under broadcast, `msg.sender` is the broadcaster, which sends the role
        // calls below.
        GovStack memory s = _deployGovernanceStack(p, msg.sender);
        vm.stopBroadcast();

        _logGovKv(s);

        return (address(s.token), address(s.timelock), address(s.governor), address(s.burner), address(s.admin));
    }
}
