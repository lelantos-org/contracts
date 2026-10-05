// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { LelantosNameRegistrar } from "../../src/names/LelantosNameRegistrar.sol";
import { LelantosNameResolver } from "../../src/names/LelantosNameResolver.sol";

import { NameRegistrarTestBase } from "./NameRegistrarTestBase.sol";
import { MockEnsResolver } from "./mocks/MockEnsResolver.sol";

/// `LelantosNameResolver`: what each query under the parent returns, and what
/// is refused.
contract LelantosNameResolverTest is NameRegistrarTestBase {
    /// `lelantosid.eth` in DNS wire format.
    bytes internal constant ETH_PARENT = hex"0a6c656c616e746f7369640365746800";
    bytes32 internal constant PARENT_NODE = keccak256("parent node");

    function setUp() public override {
        super.setUp();
        registrar.register(LABEL, VALUE, controller);
    }

    // --- subnames ---

    function test_resolve_textOfARegisteredLabel() public view {
        assertEq(_resolveText(LABEL), VALUE);
    }

    function test_resolve_unknownLabelIsEmpty() public view {
        assertEq(_resolveText("nobody"), "");
    }

    function test_resolve_clearedRecordIsEmpty() public {
        registrar.setValue(LABEL, "", 2e9, _sign(CONTROLLER_KEY, LABEL, "", 2e9));
        assertEq(_resolveText(LABEL), "");
    }

    function test_resolve_otherKeyIsEmpty() public view {
        bytes memory out = resolver.resolve(_name(LABEL), _textCall("description"));
        assertEq(abi.decode(out, (string)), "");
    }

    /// Labels are lowercase in the registrar; an unnormalized query finds nothing.
    function test_resolve_uppercaseLabelIsEmpty() public view {
        assertEq(_resolveText("MEHOW"), "");
    }

    function test_resolve_ignoresTheNodeInData() public view {
        bytes memory data = abi.encodeWithSignature("text(bytes32,string)", keccak256("anything"), TEXT_KEY);
        assertEq(abi.decode(resolver.resolve(_name(LABEL), data), (string)), VALUE);
    }

    function test_resolve_revert_otherRecordType() public {
        bytes memory data = abi.encodeWithSignature("addr(bytes32)", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(LelantosNameResolver.UnsupportedResolverProfile.selector, bytes4(data)));
        resolver.resolve(_name(LABEL), data);
    }

    function test_resolve_revert_shortData() public {
        vm.expectRevert(abi.encodeWithSelector(LelantosNameResolver.UnsupportedResolverProfile.selector, bytes4(0)));
        resolver.resolve(_name(LABEL), hex"59d1d4");
    }

    function test_unsupportedResolverProfile_hasEnsSelector() public pure {
        assertEq(LelantosNameResolver.UnsupportedResolverProfile.selector, bytes4(0x7b1c461b));
    }

    // --- names outside the parent ---

    function test_resolve_revert_deeperName() public {
        bytes memory name = _subname("a", _name(LABEL));
        vm.expectRevert(abi.encodeWithSelector(LelantosNameResolver.UnreachableName.selector, name));
        resolver.resolve(name, _textCall(TEXT_KEY));
    }

    function test_resolve_revert_otherParent() public {
        bytes memory name = _subname(LABEL, ETH_PARENT);
        vm.expectRevert(abi.encodeWithSelector(LelantosNameResolver.UnreachableName.selector, name));
        resolver.resolve(name, _textCall(TEXT_KEY));
    }

    function test_resolve_revert_emptyAndRootNames() public {
        bytes[3] memory names = [bytes(""), hex"00", abi.encodePacked(uint8(0), PARENT)];
        for (uint256 i; i < names.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(LelantosNameResolver.UnreachableName.selector, names[i]));
            resolver.resolve(names[i], _textCall(TEXT_KEY));
        }
    }

    /// A length byte that overstates the label cannot borrow bytes from the suffix.
    function test_resolve_revert_lengthByteDisagreesWithTheName() public {
        bytes memory name = abi.encodePacked(uint8(6), LABEL, PARENT);
        vm.expectRevert(abi.encodeWithSelector(LelantosNameResolver.UnreachableName.selector, name));
        resolver.resolve(name, _textCall(TEXT_KEY));
    }

    // --- the parent itself ---

    function test_resolve_parentWithoutFallbackIsUnsupported() public {
        bytes memory data = abi.encodeWithSignature("addr(bytes32)", PARENT_NODE);
        vm.expectRevert(abi.encodeWithSelector(LelantosNameResolver.UnsupportedResolverProfile.selector, bytes4(data)));
        resolver.resolve(PARENT, data);
    }

    function test_resolve_parentForwardsToTheFallback() public {
        MockEnsResolver legacy = new MockEnsResolver();
        legacy.setAddr(PARENT_NODE, address(0xCAFE));
        LelantosNameResolver r = new LelantosNameResolver(registrar, PARENT, TEXT_KEY, address(legacy));

        bytes memory out = r.resolve(PARENT, abi.encodeWithSignature("addr(bytes32)", PARENT_NODE));
        assertEq(abi.decode(out, (address)), address(0xCAFE), "forwarded answer");
        // Subnames are still answered here.
        assertEq(abi.decode(r.resolve(_name(LABEL), _textCall(TEXT_KEY)), (string)), VALUE, "subname");
    }

    function test_resolve_parentBubblesTheFallbackRevert() public {
        MockEnsResolver legacy = new MockEnsResolver();
        LelantosNameResolver r = new LelantosNameResolver(registrar, PARENT, TEXT_KEY, address(legacy));
        vm.expectRevert(MockEnsResolver.NoRecord.selector);
        r.resolve(PARENT, abi.encodeWithSignature("fail(bytes32)", PARENT_NODE));
    }

    // --- several parents, one registrar ---

    function test_twoParentsServeTheSameHandles() public {
        LelantosNameResolver eth = new LelantosNameResolver(registrar, ETH_PARENT, TEXT_KEY, address(0));
        bytes memory name = _subname(LABEL, ETH_PARENT);
        assertEq(abi.decode(eth.resolve(name, _textCall(TEXT_KEY)), (string)), VALUE, "under .eth");
        assertEq(_resolveText(LABEL), VALUE, "under .xyz");

        // Each refuses the other's names.
        vm.expectRevert(abi.encodeWithSelector(LelantosNameResolver.UnreachableName.selector, _name(LABEL)));
        eth.resolve(_name(LABEL), _textCall(TEXT_KEY));
    }

    // --- ERC-165 ---

    function test_supportsInterface() public view {
        assertTrue(resolver.supportsInterface(0x01ffc9a7), "ERC-165");
        assertTrue(resolver.supportsInterface(0x9061b923), "IExtendedResolver");
        assertFalse(resolver.supportsInterface(0xffffffff), "invalid id");
        assertFalse(resolver.supportsInterface(0x59d1d43c), "ITextResolver is reached through resolve only");
    }

    /// The Universal Resolver probes ERC-165 with 30 000 gas.
    function test_supportsInterface_fitsTheErc165GasCap() public view {
        (bool ok, bytes memory out) = address(resolver).staticcall{ gas: 30_000 }(
            abi.encodeWithSignature("supportsInterface(bytes4)", bytes4(0x9061b923))
        );
        assertTrue(ok && abi.decode(out, (bool)));
    }

    // --- constructor ---

    function test_constructor_exposesItsConfiguration() public view {
        assertEq(address(resolver.REGISTRAR()), address(registrar));
        assertEq(resolver.parentName(), PARENT);
        assertEq(resolver.textKey(), TEXT_KEY);
        assertEq(resolver.PARENT_NAME_HASH(), keccak256(PARENT));
        assertEq(resolver.PARENT_NAME_LENGTH(), PARENT.length);
        assertEq(resolver.FALLBACK_RESOLVER(), address(0));
    }

    function test_constructor_revert_ZeroAddress() public {
        vm.expectRevert(LelantosNameResolver.ZeroAddress.selector);
        new LelantosNameResolver(LelantosNameRegistrar(address(0)), PARENT, TEXT_KEY, address(0));
    }

    function test_constructor_revert_MalformedParentName() public {
        bytes[6] memory bad = [
            bytes(""),
            hex"00",
            // No root label.
            hex"086c656c616e746f730378797a",
            // Bytes after the root label.
            hex"086c656c616e746f730378797a0000",
            // A length byte running past the end.
            hex"096c656c616e746f730378797a00",
            // A 64-byte label.
            abi.encodePacked(uint8(64), new bytes(64), uint8(0))
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(LelantosNameResolver.MalformedParentName.selector);
            new LelantosNameResolver(registrar, bad[i], TEXT_KEY, address(0));
        }
    }
}
