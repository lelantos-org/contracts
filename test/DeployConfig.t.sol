// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { Fees } from "../src/libs/Fees.sol";

/// Shape checks on the deploy configs in `script/config`.
///
/// `Deploy.s.sol` reads these at broadcast time, where a malformed file costs a
/// failed mainnet deploy. Fees in particular are per asset and per leg with no
/// fallback, so a rate array that is shorter than `ids` is not a missing
/// default — it is a deploy that reverts, or worse, one asset registered at a
/// rate meant for another. Cheap to pin here.
contract DeployConfigTest is Test {
    function _configs() internal pure returns (string[6] memory) {
        return [
            "script/config/mainnet.json",
            "script/config/base.json",
            "script/config/arbitrum.json",
            "script/config/mainnet.example.json",
            "script/config/base.example.json",
            "script/config/arbitrum.example.json"
        ];
    }

    function test_feeArraysAreParallelToIdsAndWithinTheCeiling() public view {
        string[6] memory files = _configs();
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

    /// The scalar is gone. A config still carrying it would parse fine and
    /// deploy at rates nobody chose, since `Deploy.s.sol` no longer reads it.
    function test_noConfigStillCarriesTheRemovedScalar() public view {
        string[6] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            assertFalse(vm.keyExistsJson(j, ".feeBps"), string.concat(files[f], ": stale feeBps key"));
        }
    }

    /// `tokens` and `scales` are parallel to `ids` too; `Deploy.s.sol` requires
    /// it at broadcast, so failing here is strictly cheaper.
    function test_assetArraysAreParallel() public view {
        string[6] memory files = _configs();
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            uint256 n = vm.parseJsonUintArray(j, ".ids").length;
            assertEq(vm.parseJsonAddressArray(j, ".tokens").length, n, string.concat(files[f], ": tokens length"));
            assertEq(vm.parseJsonUintArray(j, ".scales").length, n, string.concat(files[f], ": scales length"));
        }
    }
}
