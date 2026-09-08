// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

/// Shape checks on `script/config/*.gov.json`, in the style of
/// `DeployConfig.t.sol`.
///
/// `DeployGovernance.s.sol` reads these at broadcast time, where a malformed file
/// costs a failed mainnet deploy — and several of these values cannot be fixed
/// afterwards without the very governance they configure.
contract GovConfigTest is Test {
    function _configs() internal pure returns (string[2] memory) {
        return ["script/config/mainnet.gov.json", "script/config/mainnet.gov.example.json"];
    }

    function test_quorumNumeratorIsAUsablePercentage() public view {
        string[2] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            uint256 q = vm.parseJsonUint(j, ".quorumNumerator");
            assertGt(q, 0, string.concat(files[f], ": zero quorum makes every proposal trivially passable"));
            assertLe(q, 100, string.concat(files[f], ": quorum over 100% can never be met"));
        }
    }

    /// A threshold at or above supply makes proposing impossible, which is an
    /// unrecoverable deadlock.
    function test_proposalThresholdIsBelowSupply() public view {
        string[2] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            assertLt(
                vm.parseJsonUint(j, ".proposalThreshold"),
                vm.parseJsonUint(j, ".totalSupply"),
                string.concat(files[f], ": threshold exceeds supply")
            );
        }
    }

    function test_supplyIsNonZero() public view {
        string[2] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            assertGt(vm.parseJsonUint(j, ".totalSupply"), 0, string.concat(files[f], ": zero supply"));
        }
    }

    function test_auctionParamsAreWithinContractBounds() public view {
        string[2] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            assertGt(
                vm.parseJsonUint(j, ".auctionHalfLife"), 0, string.concat(files[f], ": halfLife 0 divides by zero")
            );

            uint256 halvings = vm.parseJsonUint(j, ".auctionMaxHalvings");
            assertGt(halvings, 0, string.concat(files[f], ": maxHalvings 0"));
            assertLe(halvings, 32, string.concat(files[f], ": maxHalvings over 32"));

            uint256 mult = vm.parseJsonUint(j, ".auctionRestartMultBps");
            assertGe(mult, 10_000, string.concat(files[f], ": a ratchet must never lower the price"));
            assertLe(mult, 50_000, string.concat(files[f], ": ratchet over the contract ceiling"));
        }
    }

    function test_burnBpsWithinRangeAndTreasurySetWhenPartial() public view {
        string[2] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            uint256 burnBps = vm.parseJsonUint(j, ".burnBps");
            assertLe(burnBps, 10_000, string.concat(files[f], ": burnBps over 100%"));
            if (burnBps < 10_000) {
                assertTrue(
                    vm.parseJsonAddress(j, ".secondaryTreasury") != address(0),
                    string.concat(files[f], ": partial burn with nowhere to send the remainder")
                );
            }
        }
    }

    function test_timelockDelayIsNonZero() public view {
        string[2] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            assertGt(
                vm.parseJsonUint(j, ".timelockMinDelay"),
                0,
                string.concat(files[f], ": a zero delay removes the veto window entirely")
            );
        }
    }

    /// The live config must name the real deployment; the example stays zeroed.
    function test_liveConfigNamesDeployedContracts() public view {
        string memory j = vm.readFile("script/config/mainnet.gov.json");
        assertTrue(vm.parseJsonAddress(j, ".masp") != address(0), "masp unset");
        assertTrue(vm.parseJsonAddress(j, ".swapWrapper") != address(0), "swapWrapper unset");
    }

    /// Voting parameters are in **seconds**, because the token uses a timestamp
    /// clock. A value that looks like a block count is a misconfiguration.
    function test_votingParamsLookLikeSecondsNotBlocks() public view {
        string memory j = vm.readFile("script/config/mainnet.gov.json");
        assertGe(vm.parseJsonUint(j, ".votingDelay"), 1 hours, "votingDelay implausibly short for seconds");
        assertGe(vm.parseJsonUint(j, ".votingPeriod"), 1 days, "votingPeriod implausibly short for seconds");
    }
}
