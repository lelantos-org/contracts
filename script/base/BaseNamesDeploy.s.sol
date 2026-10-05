// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LelantosNameRegistrar } from "../../src/names/LelantosNameRegistrar.sol";
import { LelantosNameResolver } from "../../src/names/LelantosNameResolver.sol";

import { Ens } from "./Ens.sol";

/// `LelantosNameRegistrar` and `LelantosNameResolver` deploys and their
/// KEY=value log, for the names scripts.
///
/// The registrar is deployed once per chain. A resolver is deployed per ENS
/// parent name and reads the registrar, so adding a parent deploys a resolver
/// and nothing else.
abstract contract BaseNamesDeploy is Script {
    struct RegistrarParams {
        address owner;
        /// Zero when `feeAmount` is zero.
        address feeToken;
        uint96 feeAmount;
        address treasury;
        /// Registered to `reservedController` with an empty value. Fixed here:
        /// nothing can reclaim a handle once the registrar is live.
        string[] reservedLabels;
        address reservedController;
    }

    function _deployRegistrar(RegistrarParams memory p) internal returns (LelantosNameRegistrar) {
        return new LelantosNameRegistrar(
            p.owner, IERC20(p.feeToken), p.feeAmount, p.treasury, p.reservedLabels, p.reservedController
        );
    }

    /// A resolver serving `registrar`'s handles under `parent`, a dotted name
    /// such as `lelantos.xyz`.
    function _deployResolver(
        LelantosNameRegistrar registrar,
        string memory parent,
        string memory textKey,
        address fallbackResolver
    ) internal returns (LelantosNameResolver) {
        return new LelantosNameResolver(registrar, Ens.dnsEncode(parent), textKey, fallbackResolver);
    }

    function _logRegistrarKv(LelantosNameRegistrar registrar) internal view {
        console2.log(string.concat("NAME_REGISTRAR=", vm.toString(address(registrar))));
        console2.log(string.concat("NAME_REGISTRAR_OWNER=", vm.toString(registrar.owner())));
    }

    function _logResolverKv(LelantosNameResolver resolver) internal pure {
        console2.log(string.concat("NAME_RESOLVER=", vm.toString(address(resolver))));
    }
}
