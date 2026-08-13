// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { UniV3Adapter } from "../src/swap/UniV3Adapter.sol";
import { SwapWrapper } from "../src/swap/SwapWrapper.sol";

import { BaseSwapDeploy } from "./base/BaseSwapDeploy.s.sol";

/// Mainnet swap-stack deploy: `UniV3Adapter` + `SwapWrapper` against an
/// already-deployed MASP. Config JSON (`SWAP_CONFIG`, default
/// `script/config/mainnet.swap.json`). Symmetric with `Deploy.s.sol`'s
/// `MAINNET_CONFIG` pattern.
///
/// Config schema:
///   {
///     "masp":          "0x...",     required, must have code
///     "permit2":       "0x...",     canonical 0x000000000022D473030F116dDEE9F6B43aC78BA3
///     "router":        "0x...",     UniV3 SwapRouter02 for the chain
///     "owner":         "0x...",     wrapper owner
///     "treasury":      "0x...",     slippage-dust recipient
///     "prepareTokens": ["0x...", ...]  optional, pre-prepare Permit2 path
///   }
///
/// Run: `forge script script/DeploySwap.s.sol --rpc-url $RPC --broadcast`
contract DeploySwap is BaseSwapDeploy {
    string constant DEFAULT_CONFIG = "script/config/mainnet.swap.json";

    function run() external returns (address adapterAddr, address wrapperAddr) {
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

        // Optional prepare list — empty array if key absent.
        address[] memory prepareTokens;
        try vm.parseJsonAddressArray(j, ".prepareTokens") returns (address[] memory arr) {
            prepareTokens = arr;
        } catch {
            prepareTokens = new address[](0);
        }

        vm.startBroadcast();
        (UniV3Adapter adapter, SwapWrapper wrapper) = _deploySwapStack(masp, permit2, router, owner, treasury);
        if (prepareTokens.length != 0) _prepareTokens(wrapper, prepareTokens);
        vm.stopBroadcast();

        adapterAddr = address(adapter);
        wrapperAddr = address(wrapper);
        _logSwapKv(adapterAddr, wrapperAddr);
    }
}
