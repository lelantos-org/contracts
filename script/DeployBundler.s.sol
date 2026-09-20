// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { GenericCallWrapper } from "../src/generic/GenericCallWrapper.sol";
import { Bundler } from "../src/bundler/Bundler.sol";
import { BundlerFactory } from "../src/bundler/BundlerFactory.sol";

import { BaseSwapDeploy } from "./base/BaseSwapDeploy.s.sol";

/// `GenericCallWrapper`, `BundlerFactory` and the relayer's `Bundler`, against
/// an already-deployed MASP, NativeAdapter and SwapWrapper.
///
/// For chains whose swap stack predates the generic wrapper and the factory.
/// Re-running `DeploySwap.s.sol` there would mint a new SwapWrapper, which the
/// live wrapper's escrows do not follow. A fresh chain runs `DeploySwap.s.sol`
/// with `"genericCall": true` instead.
///
/// Env `BUNDLER_OPERATOR` (the relayer's signer) and `BUNDLER_OWNER` are both
/// required: the point of this script is the relayer's Bundler, and the deploy
/// key must not be left controlling its operator set. Any other relayer calls
/// `BundlerFactory.create` itself.
///
/// Config schema (`BUNDLER_CONFIG`, default `script/config/mainnet.bundler.json`):
///   {
///     "masp":          "0x...",     required, must have code
///     "nativeAdapter": "0x...",     optional; zero leaves Bundlers without `withdrawNative`
///     "swapWrapper":   "0x...",     optional; zero leaves Bundlers without swaps
///     "permit2":       "0x...",     canonical 0x000000000022D473030F116dDEE9F6B43aC78BA3
///     "prepareTokens": ["0x...", ...]  optional, armed on the GenericCallWrapper
///   }
///
/// Run: `BUNDLER_CONFIG=script/config/base.bundler.json BUNDLER_OPERATOR=0x... \
///       BUNDLER_OWNER=0x... forge script script/DeployBundler.s.sol --rpc-url $RPC --broadcast`
contract DeployBundler is BaseSwapDeploy {
    string constant DEFAULT_CONFIG = "script/config/mainnet.bundler.json";

    function run() external returns (address genericCallWrapper, address factoryAddr, address bundlerAddr) {
        string memory path = vm.envOr("BUNDLER_CONFIG", DEFAULT_CONFIG);
        string memory j = vm.readFile(path);

        address masp = vm.parseJsonAddress(j, ".masp");
        address nativeAdapter = vm.parseJsonAddress(j, ".nativeAdapter");
        address swapWrapper = vm.parseJsonAddress(j, ".swapWrapper");
        address permit2 = vm.parseJsonAddress(j, ".permit2");

        _requireCode(masp, "MASP has no code");
        _requireCode(permit2, "Permit2 has no code");
        if (nativeAdapter != address(0)) _requireCode(nativeAdapter, "nativeAdapter has no code");
        if (swapWrapper != address(0)) _requireCode(swapWrapper, "swapWrapper has no code");

        address[] memory prepareTokens;
        try vm.parseJsonAddressArray(j, ".prepareTokens") returns (address[] memory arr) {
            prepareTokens = arr;
        } catch {
            prepareTokens = new address[](0);
        }

        // Checked before broadcast; `_createBundlerFromEnv` would otherwise skip
        // the Bundler silently on an unset operator.
        require(vm.envOr("BUNDLER_OPERATOR", address(0)) != address(0), "BUNDLER_OPERATOR unset");
        require(vm.envOr("BUNDLER_OWNER", address(0)) != address(0), "BUNDLER_OWNER unset");

        vm.startBroadcast();
        GenericCallWrapper generic = _deployGenericCall(masp, permit2, prepareTokens);
        BundlerFactory factory = _deployBundlerFactory(masp, nativeAdapter, swapWrapper, address(generic));
        Bundler bundler = _createBundlerFromEnv({ factory: factory, ownerRequired: true });
        vm.stopBroadcast();

        genericCallWrapper = address(generic);
        factoryAddr = address(factory);
        bundlerAddr = address(bundler);
        _logGenericCallKv(generic);
        _logBundlerKv(factory, bundler);
    }
}
