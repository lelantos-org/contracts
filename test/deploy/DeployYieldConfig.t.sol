// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { DeployYield } from "../../script/DeployYield.s.sol";

/// Shape checks on the yield deploy templates.
///
/// `vm.parseJson` decodes a struct by alphabetical field name, not by
/// declaration order, so reordering a field in `DeployYield.YieldAsset`
/// shuffles the decoded values without an error; a `scale` landing in `id`
/// would be a permanent mis-registration. This test pins the mapping.
///
/// Kept separate from `DeployConfig.t.sol`, which validates the core chain
/// configs against its own explicit file list.
contract DeployYieldConfigTest is Test {
    string[4] internal files = [
        "script/config/mainnet.yield.example.json",
        "script/config/base.yield.example.json",
        "script/config/arbitrum.yield.example.json",
        "script/config/bsc.yield.example.json"
    ];

    /// Per chain: the yield ids the templates assign, above every id the chain
    /// already registers in its core config (mainnet 1-10, base 1-5, arbitrum
    /// 1-6, bsc 1-5) and in the Morpho entries of `{chain}.yield.json` (mainnet
    /// 11-15, base 6-8, arbitrum 7; bsc has none). BTC carries no yield id on
    /// any chain; mainnet 16 and base 9 are left unassigned.
    function test_decodesWithFieldsInTheRightSlots() public view {
        uint64[2][4] memory expectedIds = [[uint64(17), 18], [uint64(10), 11], [uint64(8), 9], [uint64(6), 7]];
        // BSC's USDC has 18 decimals, so its scale keeps 6-decimal precision
        // rather than the 1 used for 6-decimal USDC elsewhere.
        uint256[2][4] memory expectedScales =
            [[uint256(1), 1e10], [uint256(1), 1e10], [uint256(1), 1e10], [uint256(1e12), 1e10]];

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
            // USDC then the wrapped native token; the differing scales are why
            // the index keeps `scale` in its denominator.
            assertEq(a[0].scale, expectedScales[f][0], "USDC scale");
            assertEq(a[1].scale, expectedScales[f][1], "wrapped native scale");
        }
    }

    /// The templates leave the vault unset: the MetaMorpho vault per chain is
    /// not yet chosen, and the binding is permanent. The script's
    /// `_requireCode` refuses a zero vault, so an unfilled template cannot be
    /// broadcast.
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
