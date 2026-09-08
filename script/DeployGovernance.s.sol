// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BaseGovernanceDeploy } from "./base/BaseGovernanceDeploy.s.sol";

/// Governance-stack deploy against an already-deployed MASP and SwapWrapper.
///
/// Deploys `LelantosToken`, `TimelockController`, `LelantosGovernor`,
/// `FeeBurner` and `ProtocolAdmin`, wires the Timelock role table, and renounces
/// the deployer's admin as the final transaction.
///
/// It does **not** hand the pool over. See `HandoverOwnership.s.sol`, and run it
/// only once real delegated weight exists — a Timelock-owned pool with nobody
/// delegated has no working administrator at all.
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
///     "proposalThreshold":     "2500000000000000000000000",     0.25%
///     "quorumNumerator":       3,        percent of TOTAL supply, see below
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
/// Quorum guidance: the denominator is **total supply**, not delegated supply —
/// `Votes` checkpoints the total only on mint and burn. Tokens sitting
/// undelegated in a treasury or an unclaimed airdrop still count, so the bar
/// against the active float is higher than the numerator suggests. Start low (3)
/// and raise by proposal once the distribution is known; too high is a deadlock
/// that only the deadlocked governance could fix.
///
/// Auction guidance: seed prices are set per token *after* deploy, via
/// `FeeBurner.setLot`, and every lot starts disabled. Enable one lot first,
/// observe a few clears, then calibrate the rest from the observed ratio — and
/// seed high, since too high only delays the first sale while too low leaks value
/// once before the ratchet corrects.
contract DeployGovernance is BaseGovernanceDeploy {
    string constant DEFAULT_CONFIG = "script/config/mainnet.gov.json";

    function run() external returns (address token, address timelock, address governor, address burner, address admin) {
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

        vm.startBroadcast();
        // Under broadcast, `msg.sender` is the broadcaster — the address that
        // actually sends the role calls below.
        GovStack memory s = _deployGovernanceStack(p, msg.sender);
        vm.stopBroadcast();

        _logGovKv(s);

        return (address(s.token), address(s.timelock), address(s.governor), address(s.burner), address(s.admin));
    }
}
