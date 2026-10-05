// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ens } from "../../../script/base/Ens.sol";
import { LelantosNameResolver } from "../../../src/names/LelantosNameResolver.sol";

import { MockEnsResolver } from "../mocks/MockEnsResolver.sol";
import { EnsForkBase } from "./EnsForkBase.sol";

/// Handles resolved through mainnet's ENS registry and Universal Resolver, the
/// path `getEnsText` takes, under a `.eth` parent and a DNS parent.
///
/// Each parent is created by pranking the owner of its TLD node, which stands
/// in for a `.eth` registration and for a DNSSEC claim: neither is under test,
/// and a DNSSEC proof is live data that cannot be pinned. What is under test is
/// that a parent whose resolver is a `LelantosNameResolver` serves every handle
/// with no registry entry of its own.
contract EnsResolutionForkTest is EnsForkBase {
    LelantosNameResolver internal ethResolver;
    LelantosNameResolver internal xyzResolver;
    MockEnsResolver internal legacy;

    function setUp() public {
        if (!_forkWithRegistrar()) return;

        legacy = new MockEnsResolver();
        ethResolver = new LelantosNameResolver(registrar, _parentName("eth"), TEXT_KEY, address(legacy));
        xyzResolver = new LelantosNameResolver(registrar, _parentName("xyz"), TEXT_KEY, address(0));
        _createParent("eth", address(ethResolver));
        _createParent("xyz", address(xyzResolver));
    }

    /// Creates the test parent under `tld`, owned by `OWNER`, with `resolver`.
    function _createParent(string memory tld, address resolver) internal {
        address tldOwner = Ens.REGISTRY.owner(_tldNode(tld));
        assertTrue(tldOwner != address(0), "TLD missing from the registry");
        assertEq(Ens.REGISTRY.owner(_parentNode(tld)), address(0), "pick another PARENT_LABEL");
        vm.prank(tldOwner);
        Ens.REGISTRY.setSubnodeRecord(_tldNode(tld), keccak256(bytes(PARENT_LABEL)), OWNER, resolver, 0);
    }

    function test_handleResolvesUnderTheEthParent() public view {
        (string memory value, address resolver) = _resolveText(LABEL, "eth", TEXT_KEY);
        assertEq(value, VALUE, "value");
        assertEq(resolver, address(ethResolver), "served by the wildcard resolver");
        // No registry entry exists for the handle itself.
        assertEq(Ens.REGISTRY.owner(Ens.subnode(_parentNode("eth"), LABEL)), address(0), "no subnode");
    }

    function test_handleResolvesUnderTheDnsParent() public view {
        (string memory value, address resolver) = _resolveText(LABEL, "xyz", TEXT_KEY);
        assertEq(value, VALUE, "value");
        assertEq(resolver, address(xyzResolver), "served by the wildcard resolver");
    }

    function test_unknownLabelAndOtherKeyAreEmpty() public view {
        (string memory unknown,) = _resolveText("nobody", "eth", TEXT_KEY);
        assertEq(unknown, "", "unknown label");
        (string memory other,) = _resolveText(LABEL, "eth", "description");
        assertEq(other, "", "other key");
    }

    function test_aHandleRegisteredLaterResolvesAtOnce() public {
        registrar.register("later", "lelantos1later", vm.addr(CONTROLLER_KEY));
        (string memory eth,) = _resolveText("later", "eth", TEXT_KEY);
        (string memory xyz,) = _resolveText("later", "xyz", TEXT_KEY);
        assertEq(eth, "lelantos1later", "under .eth");
        assertEq(xyz, "lelantos1later", "under .xyz");
    }

    function test_clearedRecordResolvesEmpty() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CONTROLLER_KEY, registrar.setValueDigest(LABEL, "", deadline));
        registrar.setValue(LABEL, "", deadline, abi.encodePacked(r, s, v));
        (string memory value,) = _resolveText(LABEL, "xyz", TEXT_KEY);
        assertEq(value, "");
    }

    function test_addrOfAHandleIsUnsupported() public {
        bytes memory name = _subname(LABEL, _parentName("eth"));
        vm.expectRevert();
        UNIVERSAL_RESOLVER.resolve(name, abi.encodeWithSignature("addr(bytes32)", bytes32(0)));
    }

    function test_deeperNameDoesNotResolve() public {
        bytes memory name = _subname("a", _subname(LABEL, _parentName("eth")));
        vm.expectRevert();
        UNIVERSAL_RESOLVER.resolve(name, _textCall(bytes32(0), TEXT_KEY));
    }

    /// The parent's own records are still answered, by the fallback resolver.
    function test_parentRecordsComeFromTheFallback() public {
        legacy.setAddr(_parentNode("eth"), address(0xCAFE));
        bytes memory data = abi.encodeWithSignature("addr(bytes32)", _parentNode("eth"));
        (bytes memory out, address resolver) = UNIVERSAL_RESOLVER.resolve(_parentName("eth"), data);
        assertEq(abi.decode(out, (address)), address(0xCAFE), "forwarded");
        assertEq(resolver, address(ethResolver), "through the wildcard resolver");
    }

    /// A real subnode under the parent shadows the wildcard: the parent's owner
    /// keeps that power until the name is locked.
    function test_parentOwnerCanShadowAHandle() public {
        MockEnsResolver other = new MockEnsResolver();
        vm.prank(OWNER);
        Ens.REGISTRY.setSubnodeRecord(_parentNode("eth"), keccak256(bytes(LABEL)), OWNER, address(other), 0);

        bytes memory name = _subname(LABEL, _parentName("eth"));
        try UNIVERSAL_RESOLVER.resolve(name, _textCall(bytes32(0), TEXT_KEY)) returns (bytes memory, address resolver) {
            assertEq(resolver, address(other), "the subnode's resolver answers");
        } catch {
            // The stand-in resolver has no text record; a revert also shows the
            // wildcard no longer answers.
        }
        // The registrar is untouched.
        assertEq(registrar.valueOf(keccak256(bytes(LABEL))), VALUE);
    }
}
