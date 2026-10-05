// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { LelantosNameRegistrar } from "../src/names/LelantosNameRegistrar.sol";
import { LelantosNameResolver } from "../src/names/LelantosNameResolver.sol";

import { BaseNamesDeploy } from "./base/BaseNamesDeploy.s.sol";

/// One `LelantosNameResolver`: the registrar's handles as subnames of one ENS
/// parent. Run once per parent name.
///
/// The deploy changes nothing by itself. The parent serves handles once its
/// owner sets this contract as its resolver in the ENS registry
/// (`HandoverName.s.sol` for a `.eth` name; the claim transaction for a DNS
/// name).
///
/// Config schema (`RESOLVER_CONFIG`, default `script/config/mainnet.names.resolver.json`):
///   {
///     "registrar":        "0x...",                 must have code
///     "parent":           "lelantos.xyz",          lowercase, dotted
///     "textKey":          "xyz.lelantos.address",  the same under every parent
///     "fallbackResolver": "0x..."                  the parent's current resolver, or zero
///   }
///
/// Run: `RESOLVER_CONFIG=... forge script script/DeployNameResolver.s.sol --rpc-url $RPC --broadcast`
contract DeployNameResolver is BaseNamesDeploy {
    string constant DEFAULT_CONFIG = "script/config/mainnet.names.resolver.json";

    function run() external returns (address resolver) {
        string memory j = vm.readFile(vm.envOr("RESOLVER_CONFIG", DEFAULT_CONFIG));
        address registrar = vm.parseJsonAddress(j, ".registrar");
        string memory parent = vm.parseJsonString(j, ".parent");
        string memory textKey = vm.parseJsonString(j, ".textKey");
        address fallbackResolver = vm.parseJsonAddress(j, ".fallbackResolver");

        require(registrar.code.length != 0, "registrar has no code");
        require(bytes(textKey).length != 0, "textKey unset");
        if (fallbackResolver != address(0)) require(fallbackResolver.code.length != 0, "fallbackResolver has no code");

        vm.startBroadcast();
        LelantosNameResolver deployed =
            _deployResolver(LelantosNameRegistrar(registrar), parent, textKey, fallbackResolver);
        vm.stopBroadcast();

        resolver = address(deployed);
        _logResolverKv(deployed);
    }
}
