// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { DeployYield } from "../script/DeployYield.s.sol";

/// Shape checks on the yield deploy templates.
///
/// `vm.parseJson` decodes a struct by *alphabetical* field name, not by
/// declaration order, so a field reordered in `DeployYield.YieldAsset` silently
/// shuffles the values it decodes — a `scale` landing in `id` would be a
/// permanent mis-registration. This pins the mapping.
///
/// Kept separate from `DeployConfig.t.sol`, which validates the core chain
/// configs against its own explicit file list; those files are untouched by
/// this workstream.
contract DeployYieldConfigTest is Test {
    string[3] internal files = [
        "script/config/mainnet.yield.example.json",
        "script/config/base.yield.example.json",
        "script/config/arbitrum.yield.example.json"
    ];

    /// Per chain: the yield ids the plan assigns, being the next free id above
    /// everything the chain already registers -- both its core config
    /// (mainnet 1-10, base 1-5, arbitrum 1-6) and the Morpho yield ids in
    /// `{chain}.yield.json` (mainnet 11-15, base 6-8, arbitrum 7). BTC carries
    /// no yield id on any chain, so neither 16 nor base 9 is taken.
    function test_decodesWithFieldsInTheRightSlots() public view {
        uint64[2][3] memory expectedIds = [[uint64(17), 18], [uint64(10), 11], [uint64(8), 9]];

        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            DeployYield.YieldAsset[] memory a = abi.decode(vm.parseJson(j, ".assets"), (DeployYield.YieldAsset[]));

            assertEq(a.length, 2, "one yield id per token");
            for (uint256 i; i < a.length; ++i) {
                assertEq(a[i].id, expectedIds[f][i], "id decoded into the id slot");
                assertTrue(a[i].token != address(0), "token filled in");
                assertLe(a[i].perfBps, 2_000, "perfBps within MAX_FEE_BPS");
                assertLe(a[i].bufferBps, 10_000, "bufferBps within 100%");
                assertLe(a[i].depositBps, 2_000, "depositBps within MAX_FEE_BPS");
                assertLe(a[i].withdrawBps, 2_000, "withdrawBps within MAX_FEE_BPS");
            }
            // USDC then WETH, and the differing scales are the whole reason the
            // index keeps `scale` in its denominator.
            assertEq(a[0].scale, 1, "USDC scale");
            assertEq(a[1].scale, 1e10, "WETH scale");
        }
    }

    /// The templates ship with the vault unresolved on purpose: the MetaMorpho
    /// vault per chain is not chosen yet, and the binding is permanent. The
    /// script's `_requireCode` refuses a zero vault, so an unfilled template
    /// cannot be broadcast by accident.
    function test_vaultsAreDeliberatelyUnset() public view {
        for (uint256 f; f < files.length; ++f) {
            string memory j = vm.readFile(files[f]);
            DeployYield.YieldAsset[] memory a = abi.decode(vm.parseJson(j, ".assets"), (DeployYield.YieldAsset[]));
            for (uint256 i; i < a.length; ++i) {
                assertEq(a[i].vault, address(0), "template vault is a placeholder");
            }
        }
    }
}
