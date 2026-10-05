// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { LelantosNameRegistrar } from "../src/names/LelantosNameRegistrar.sol";
import { LelantosNameResolver } from "../src/names/LelantosNameResolver.sol";

import { BaseNamesDeploy } from "./base/BaseNamesDeploy.s.sol";

/// Test/anvil names stack: a registrar charging a small fee in a mock token,
/// and one resolver for `lelantos.xyz`. Run after `DeployTest.s.sol`, whose
/// KEY=value output supplies `TOKEN_1`.
///
/// No ENS registry exists on a dev chain, so the resolver is not installed
/// anywhere; it is deployed so `resolve(bytes,bytes)` can be called directly.
/// Registration and `recordOf` do not involve it.
///
/// Required env:
///   TOKEN_1 — the fee token (must have code)
///
/// Optional:
///   NAME_OWNER      — sets the fee; default the broadcaster
///   NAME_TREASURY   — receives the fee; default 0x…dEaD, as the pool's dev treasury
///   NAME_FEE_AMOUNT — base units of TOKEN_1; default 1e6
contract DeployTestNames is BaseNamesDeploy {
    string constant PARENT = "lelantos.xyz";
    string constant TEXT_KEY = "xyz.lelantos.address";
    /// anvil's last default account: a key every dev has, so a reserved handle
    /// can be published under on a dev chain.
    address constant RESERVED_CONTROLLER = 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;

    function run() external returns (address registrar, address resolver) {
        RegistrarParams memory p;
        p.owner = vm.envOr("NAME_OWNER", tx.origin);
        p.feeToken = vm.envAddress("TOKEN_1");
        uint256 feeAmount = vm.envOr("NAME_FEE_AMOUNT", uint256(1e6));
        require(feeAmount <= type(uint96).max, "NAME_FEE_AMOUNT overflows uint96");
        p.feeAmount = uint96(feeAmount);
        p.treasury = vm.envOr("NAME_TREASURY", 0x000000000000000000000000000000000000dEaD);
        p.reservedLabels = new string[](3);
        p.reservedLabels[0] = "admin";
        p.reservedLabels[1] = "support";
        p.reservedLabels[2] = "lelantos";
        p.reservedController = RESERVED_CONTROLLER;
        require(p.feeToken.code.length != 0, "TOKEN_1 has no code");

        vm.startBroadcast();
        LelantosNameRegistrar reg = _deployRegistrar(p);
        LelantosNameResolver res = _deployResolver(reg, PARENT, TEXT_KEY, address(0));
        vm.stopBroadcast();

        registrar = address(reg);
        resolver = address(res);
        _logRegistrarKv(reg);
        _logResolverKv(res);
    }
}
