// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { ExitTerms } from "../../src/libs/ExitTerms.sol";
import { Fees } from "../../src/libs/Fees.sol";

/// Shape checks on the deploy configs in `script/config`.
///
/// `Deploy.s.sol` reads these at broadcast time, where a malformed file costs a
/// failed mainnet deploy. Fees are per asset and per leg with no fallback, so
/// a rate array shorter than `ids` either reverts the deploy or registers an
/// asset at a rate meant for another.
contract DeployConfigTest is Test {
    function _configs() internal pure returns (string[8] memory) {
        return [
            "script/config/mainnet.json",
            "script/config/base.json",
            "script/config/arbitrum.json",
            "script/config/bsc.json",
            "script/config/mainnet.example.json",
            "script/config/base.example.json",
            "script/config/arbitrum.example.json",
            "script/config/bsc.example.json"
        ];
    }

    function test_feeArraysAreParallelToIdsAndWithinTheCeiling() public view {
        string[8] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            uint256 n = vm.parseJsonUintArray(j, ".ids").length;
            assertGt(n, 0, string.concat(files[f], ": no ids"));

            uint256[] memory dep = vm.parseJsonUintArray(j, ".depositBps");
            uint256[] memory wit = vm.parseJsonUintArray(j, ".withdrawBps");
            assertEq(dep.length, n, string.concat(files[f], ": depositBps length"));
            assertEq(wit.length, n, string.concat(files[f], ": withdrawBps length"));

            for (uint256 i; i < n; ++i) {
                assertLe(dep[i], Fees.MAX_FEE_BPS, string.concat(files[f], ": depositBps over ceiling"));
                assertLe(wit[i], Fees.MAX_FEE_BPS, string.concat(files[f], ": withdrawBps over ceiling"));
            }
        }
    }

    /// `Deploy.s.sol` reads only the per-asset fee arrays. A config carrying a
    /// scalar `feeBps` would parse, but the value would be ignored and the pool
    /// deployed at rates other than the one it states.
    function test_noConfigStillCarriesTheRemovedScalar() public view {
        string[8] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            assertFalse(vm.keyExistsJson(j, ".feeBps"), string.concat(files[f], ": stale feeBps key"));
        }
    }

    /// The exit window is immutable on the proxy and cannot be changed after
    /// deploy, so a zero or very short value ships a pool whose upgrades are
    /// effectively instant.
    function test_upgradeWindowIsMeaningfulAndProxyAdminIsSet() public view {
        string[8] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            uint256 upgradeDelay = vm.parseJsonUint(j, ".upgradeDelay");
            assertGe(upgradeDelay, 7 days, string.concat(files[f], ": upgradeDelay too short to exit through"));
            // An exit-term raise must not be able to land inside the window.
            assertLe(
                upgradeDelay, ExitTerms.DELAY, string.concat(files[f], ": upgradeDelay longer than the raise notice")
            );
            uint256 maxPause = vm.parseJsonUint(j, ".maxPause");
            assertGt(maxPause, 0, string.concat(files[f], ": zero maxPause"));
            assertLe(maxPause, 30 days, string.concat(files[f], ": maxPause over ceiling"));
            assertTrue(vm.keyExistsJson(j, ".proxyAdmin"), string.concat(files[f], ": proxyAdmin missing"));
        }
    }

    /// The pause ceiling is shorter than the exit window. The proxy constructor
    /// and `Deploy.s.sol` both refuse a config that is not; checking here fails
    /// before a broadcast is attempted.
    function test_maxPauseIsShorterThanUpgradeDelay() public view {
        string[8] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            assertLt(
                vm.parseJsonUint(j, ".maxPause"),
                vm.parseJsonUint(j, ".upgradeDelay"),
                string.concat(files[f], ": maxPause not shorter than upgradeDelay")
            );
        }
    }

    /// `tokens` and `scales` are parallel to `ids`. `Deploy.s.sol` requires
    /// this at broadcast; checking here fails before a broadcast is attempted.
    function test_assetArraysAreParallel() public view {
        string[8] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            uint256 n = vm.parseJsonUintArray(j, ".ids").length;
            assertEq(vm.parseJsonAddressArray(j, ".tokens").length, n, string.concat(files[f], ": tokens length"));
            assertEq(vm.parseJsonUintArray(j, ".scales").length, n, string.concat(files[f], ": scales length"));
        }
    }
}
