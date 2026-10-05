// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { LelantosNameRegistrar } from "../src/names/LelantosNameRegistrar.sol";

import { BaseNamesDeploy } from "./base/BaseNamesDeploy.s.sol";

/// `LelantosNameRegistrar`: the handles of one chain.
///
/// Touches nothing in ENS. A parent name starts serving these handles once a
/// resolver from `DeployNameResolver.s.sol` is set as its resolver.
///
/// Config schema (`NAMES_CONFIG`, default `script/config/mainnet.names.json`):
///   {
///     "owner":              "0x...",   sets the fee; the Timelock in production
///     "feeToken":           "0x...",   a token the pool lists; zero when feeAmount is 0
///     "feeAmount":          "5000000", base units of feeToken, as a string
///     "treasury":           "0x...",   receives the fee
///     "reservedLabels":     ["admin", ...],
///     "reservedController": "0x..."    an EOA: only its signature can publish under a reserved label
///   }
///
/// Run: `NAMES_CONFIG=... forge script script/DeployNames.s.sol --rpc-url $RPC --broadcast`
contract DeployNames is BaseNamesDeploy {
    string constant DEFAULT_CONFIG = "script/config/mainnet.names.json";

    function run() external returns (address registrar) {
        string memory j = vm.readFile(vm.envOr("NAMES_CONFIG", DEFAULT_CONFIG));

        RegistrarParams memory p;
        p.owner = vm.parseJsonAddress(j, ".owner");
        p.feeToken = vm.parseJsonAddress(j, ".feeToken");
        uint256 feeAmount = vm.parseJsonUint(j, ".feeAmount");
        require(feeAmount <= type(uint96).max, "feeAmount overflows uint96");
        p.feeAmount = uint96(feeAmount);
        p.treasury = vm.parseJsonAddress(j, ".treasury");
        p.reservedLabels = vm.parseJsonStringArray(j, ".reservedLabels");
        p.reservedController = vm.parseJsonAddress(j, ".reservedController");

        require(p.owner != address(0), "owner unset");
        if (p.feeAmount != 0) require(p.feeToken.code.length != 0, "feeToken has no code");
        // A contract cannot sign the EIP-712 message that publishes a value.
        require(p.reservedController.code.length == 0, "reservedController is a contract");

        vm.startBroadcast();
        LelantosNameRegistrar deployed = _deployRegistrar(p);
        vm.stopBroadcast();

        registrar = address(deployed);
        _logRegistrarKv(deployed);
    }
}
