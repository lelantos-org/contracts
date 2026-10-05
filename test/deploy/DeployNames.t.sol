// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { BaseNamesDeploy } from "../../script/base/BaseNamesDeploy.s.sol";
import { Ens } from "../../script/base/Ens.sol";
import { LelantosNameRegistrar } from "../../src/names/LelantosNameRegistrar.sol";
import { LelantosNameResolver } from "../../src/names/LelantosNameResolver.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

contract NamesDeployHarness is BaseNamesDeploy {
    function deployRegistrar(RegistrarParams memory p) external returns (LelantosNameRegistrar) {
        return _deployRegistrar(p);
    }

    function deployResolver(
        LelantosNameRegistrar registrar,
        string memory parent,
        string memory textKey,
        address fallbackResolver
    ) external returns (LelantosNameResolver) {
        return _deployResolver(registrar, parent, textKey, fallbackResolver);
    }

    function dnsEncode(string memory name) external pure returns (bytes memory) {
        return Ens.dnsEncode(name);
    }
}

/// The names deploy base and the shape of its example configs.
contract DeployNamesTest is Test {
    address internal constant OWNER = address(0x0A11CE);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant RESERVED = address(0x5E5E);

    NamesDeployHarness internal harness;
    MockERC20 internal token;

    function setUp() public {
        harness = new NamesDeployHarness();
        token = new MockERC20("Fee", "FEE", 6);
    }

    function _params() internal view returns (BaseNamesDeploy.RegistrarParams memory p) {
        p.owner = OWNER;
        p.feeToken = address(token);
        p.feeAmount = 5e6;
        p.treasury = TREASURY;
        p.reservedLabels = new string[](2);
        p.reservedLabels[0] = "admin";
        p.reservedLabels[1] = "support";
        p.reservedController = RESERVED;
    }

    function test_deployRegistrar_appliesTheParams() public {
        LelantosNameRegistrar registrar = harness.deployRegistrar(_params());
        assertEq(registrar.owner(), OWNER, "owner");
        assertEq(address(registrar.feeToken()), address(token), "fee token");
        assertEq(registrar.feeAmount(), 5e6, "fee amount");
        assertEq(registrar.treasury(), TREASURY, "treasury");
        (, address ctl,) = registrar.recordOf("support");
        assertEq(ctl, RESERVED, "reserved label");
        assertTrue(registrar.available("mehow"), "others free");
    }

    function test_deployResolver_servesTheDottedParent() public {
        LelantosNameRegistrar registrar = harness.deployRegistrar(_params());
        LelantosNameResolver resolver =
            harness.deployResolver(registrar, "lelantos.xyz", "xyz.lelantos.address", address(0));
        assertEq(resolver.parentName(), hex"086c656c616e746f730378797a00", "wire format");
        assertEq(address(resolver.REGISTRAR()), address(registrar), "registrar");
        assertEq(resolver.textKey(), "xyz.lelantos.address", "key");
    }

    function test_dnsEncode() public view {
        assertEq(harness.dnsEncode("eth"), hex"0365746800");
        assertEq(harness.dnsEncode("lelantosid.eth"), hex"0a6c656c616e746f7369640365746800");
        assertEq(harness.dnsEncode("a.b.c"), hex"016101620163" hex"00");
    }

    function test_dnsEncode_revert_badLabels() public {
        string[4] memory bad = ["", "lelantos..xyz", ".xyz", "lelantos."];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(bytes("bad label in name"));
            harness.dnsEncode(bad[i]);
        }
        vm.expectRevert(bytes("bad label in name"));
        harness.dnsEncode(string(abi.encodePacked(new bytes(64), ".eth")));
    }

    /// Against `cast namehash`.
    function test_ensNodes() public pure {
        assertEq(Ens.subnode(bytes32(0), "eth"), Ens.ETH_NODE, "eth");
        assertEq(
            Ens.subnode(Ens.ETH_NODE, "lelantos"),
            0xca5edeae72deb7cf29a02235847105a4b47092d8e30116f8434bd1b3a949daad,
            "lelantos.eth"
        );
    }

    function test_exampleConfigs_parse() public {
        string memory j = vm.readFile("script/config/mainnet.names.example.json");
        vm.parseJsonAddress(j, ".owner");
        vm.parseJsonAddress(j, ".feeToken");
        assertLe(vm.parseJsonUint(j, ".feeAmount"), type(uint96).max, "feeAmount width");
        vm.parseJsonAddress(j, ".treasury");
        vm.parseJsonAddress(j, ".reservedController");
        // The reserved labels deploy: each is valid and none repeats.
        BaseNamesDeploy.RegistrarParams memory p = _params();
        p.reservedLabels = vm.parseJsonStringArray(j, ".reservedLabels");
        LelantosNameRegistrar registrar = harness.deployRegistrar(p);
        for (uint256 i; i < p.reservedLabels.length; ++i) {
            assertFalse(registrar.available(p.reservedLabels[i]), p.reservedLabels[i]);
        }

        string memory r = vm.readFile("script/config/mainnet.names.resolver.example.json");
        vm.parseJsonAddress(r, ".registrar");
        vm.parseJsonAddress(r, ".fallbackResolver");
        assertEq(vm.parseJsonString(r, ".textKey"), "xyz.lelantos.address", "one key under every parent");
        harness.deployResolver(
            registrar, vm.parseJsonString(r, ".parent"), vm.parseJsonString(r, ".textKey"), address(0)
        );
    }
}
