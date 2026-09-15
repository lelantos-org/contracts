// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { UniV3Adapter } from "../src/swap/UniV3Adapter.sol";
import { UniV4Adapter } from "../src/swap/UniV4Adapter.sol";
import { SwapWrapper } from "../src/swap/SwapWrapper.sol";
import { Bundler } from "../src/bundler/Bundler.sol";
import { BundlerFactory } from "../src/bundler/BundlerFactory.sol";

import { BaseSwapDeploy } from "./base/BaseSwapDeploy.s.sol";

/// Mainnet swap-stack deploy: `UniV3Adapter` (+ optional `UniV4Adapter`) and
/// `SwapWrapper` against an already-deployed MASP, then the `BundlerFactory`
/// over MASP, the native adapter and the wrapper. Reads a JSON config
/// (`SWAP_CONFIG`, default `script/config/mainnet.swap.json`), following
/// `Deploy.s.sol`'s `MAINNET_CONFIG` pattern. Env `BUNDLER_OPERATOR`, when set,
/// also creates the broadcaster's `Bundler` and transfers it to env
/// `BUNDLER_OWNER`, which is then required so the deploy key is not left
/// controlling the operator set.
///
/// Config schema:
///   {
///     "masp":          "0x...",     required, must have code
///     "nativeAdapter": "0x...",     optional, Deploy.s.sol's NativeAdapter
///     "permit2":       "0x...",     canonical 0x000000000022D473030F116dDEE9F6B43aC78BA3
///     "router":        "0x...",     UniV3 SwapRouter02 for the chain
///     "univ4Router":   "0x...",     optional, UniversalRouter; omit for a V3-only stack
///     "owner":         "0x...",     wrapper owner
///     "treasury":      "0x...",     slippage-dust recipient
///     "prepareTokens": ["0x...", ...]  optional, pre-prepare Permit2 path
///   }
///
/// Run: `forge script script/DeploySwap.s.sol --rpc-url $RPC --broadcast`
contract DeploySwap is BaseSwapDeploy {
    string constant DEFAULT_CONFIG = "script/config/mainnet.swap.json";

    function run() external returns (address univ3Adapter, address univ4Adapter, address wrapperAddr) {
        string memory path = vm.envOr("SWAP_CONFIG", DEFAULT_CONFIG);
        string memory j = vm.readFile(path);

        address masp = vm.parseJsonAddress(j, ".masp");
        address permit2 = vm.parseJsonAddress(j, ".permit2");
        address router = vm.parseJsonAddress(j, ".router");
        address owner = vm.parseJsonAddress(j, ".owner");
        address treasury = vm.parseJsonAddress(j, ".treasury");

        _requireCode(masp, "MASP has no code");
        _requireCode(permit2, "Permit2 has no code");
        _requireCode(router, "router has no code");
        require(owner != address(0), "owner zero");
        require(treasury != address(0), "treasury zero");

        // Optional venue; an absent key leaves it zero, which deploys V3 only.
        address univ4Router;
        try vm.parseJsonAddress(j, ".univ4Router") returns (address r) {
            univ4Router = r;
        } catch { }
        if (univ4Router != address(0)) _requireCode(univ4Router, "univ4Router has no code");

        // Optional; an absent key leaves Bundlers without `withdrawNative`.
        address nativeAdapter;
        try vm.parseJsonAddress(j, ".nativeAdapter") returns (address a) {
            nativeAdapter = a;
        } catch { }
        if (nativeAdapter != address(0)) _requireCode(nativeAdapter, "nativeAdapter has no code");

        // Optional prepare list; empty when the key is absent.
        address[] memory prepareTokens;
        try vm.parseJsonAddressArray(j, ".prepareTokens") returns (address[] memory arr) {
            prepareTokens = arr;
        } catch {
            prepareTokens = new address[](0);
        }

        vm.startBroadcast();
        (UniV3Adapter v3, UniV4Adapter v4, SwapWrapper wrapper) =
            _deploySwapStack(masp, permit2, router, univ4Router, owner, treasury);
        if (prepareTokens.length != 0) _prepareTokens(wrapper, prepareTokens);
        BundlerFactory factory = _deployBundlerFactory(masp, nativeAdapter, address(wrapper));
        Bundler bundler = _createBundlerFromEnv({ factory: factory, ownerRequired: true });
        vm.stopBroadcast();

        univ3Adapter = address(v3);
        univ4Adapter = address(v4);
        wrapperAddr = address(wrapper);
        _logSwapKv(univ3Adapter, univ4Adapter, wrapperAddr);
        _logBundlerKv(factory, bundler);
    }
}
