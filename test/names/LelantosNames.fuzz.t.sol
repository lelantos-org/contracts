// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { LelantosNameRegistrar } from "../../src/names/LelantosNameRegistrar.sol";

import { NameRegistrarTestBase } from "./NameRegistrarTestBase.sol";

/// The label and value rules against independent reference checks, and the
/// resolver's refusal of every name that is not a direct subname.
contract LelantosNamesFuzzTest is NameRegistrarTestBase {
    bytes internal constant LABEL_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789--";

    function setUp() public override {
        super.setUp();
        registrar.register(LABEL, VALUE, controller);
    }

    // --- references ---

    function _refLabel(bytes memory b) internal pure returns (bool) {
        if (b.length < 3 || b.length > 32) return false;
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            bool alnum = (c >= 97 && c <= 122) || (c >= 48 && c <= 57);
            if (!alnum && c != 45) return false;
            if (c == 45 && (i == 0 || i == b.length - 1 || uint8(b[i - 1]) == 45)) return false;
        }
        return true;
    }

    function _refValue(bytes memory b) internal pure returns (bool) {
        if (b.length > 1024) return false;
        for (uint256 i; i < b.length; ++i) {
            if (uint8(b[i]) < 0x21 || uint8(b[i]) > 0x7e) return false;
        }
        return true;
    }

    /// Bytes drawn from the label alphabet, so valid labels are common.
    function _label(bytes memory seed, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(bound(length, 0, 34));
        for (uint256 i; i < out.length; ++i) {
            uint256 pick = seed.length == 0 ? i : uint8(seed[i % seed.length]);
            out[i] = LABEL_ALPHABET[pick % LABEL_ALPHABET.length];
        }
    }

    // --- labels ---

    function testFuzz_isValidLabel_matchesReference_anyBytes(bytes memory raw) public view {
        assertEq(registrar.isValidLabel(string(raw)), _refLabel(raw));
    }

    function testFuzz_isValidLabel_matchesReference_alphabet(bytes memory seed, uint256 length) public view {
        bytes memory label = _label(seed, length);
        assertEq(registrar.isValidLabel(string(label)), _refLabel(label));
    }

    function testFuzz_validLabel_registersAndResolves(bytes memory seed, uint256 length) public {
        bytes memory label = _label(seed, length);
        vm.assume(_refLabel(label) && registrar.available(string(label)));
        registrar.register(string(label), VALUE, controller);
        assertEq(_resolveText(string(label)), VALUE);
    }

    // --- values ---

    function testFuzz_value_matchesReference_anyBytes(bytes memory raw) public {
        _assertValueRule(raw);
    }

    /// Printable bytes with one byte replaced, so the boundary cases at every
    /// offset of a word are exercised.
    function testFuzz_value_matchesReference_oneOddByte(uint256 length, uint256 position, uint8 odd) public {
        bytes memory raw = new bytes(bound(length, 1, 200));
        for (uint256 i; i < raw.length; ++i) {
            raw[i] = bytes1(uint8(0x21 + (i % 94)));
        }
        raw[bound(position, 0, raw.length - 1)] = bytes1(odd);
        _assertValueRule(raw);
    }

    function _assertValueRule(bytes memory raw) internal {
        bool expected = raw.length != 0 && _refValue(raw);
        if (!expected) vm.expectRevert(LelantosNameRegistrar.InvalidValue.selector);
        registrar.register("fuzzed", string(raw), controller);
        if (expected) assertEq(registrar.valueOf(keccak256("fuzzed")), string(raw));
    }

    // --- resolver ---

    /// No byte string but `<label>.<parent>` of a registered label yields a value.
    function testFuzz_resolve_onlyDirectSubnamesAnswer(bytes memory name) public view {
        try resolver.resolve(name, _textCall(TEXT_KEY)) returns (bytes memory out) {
            string memory value = abi.decode(out, (string));
            if (bytes(value).length != 0) assertEq(name, _name(LABEL), "a value under another name");
        } catch { }
    }

    /// A prefix in front of a valid name, or a suffix behind it, is refused.
    function testFuzz_resolve_refusesPaddedNames(bytes memory pad) public {
        vm.assume(pad.length != 0);
        bytes memory name = _name(LABEL);
        vm.expectRevert();
        resolver.resolve(abi.encodePacked(name, pad), _textCall(TEXT_KEY));

        bytes memory prefixed = abi.encodePacked(pad, name);
        try resolver.resolve(prefixed, _textCall(TEXT_KEY)) returns (bytes memory out) {
            // Accepted only when the prefix happens to form a single label of the
            // right length, which is then an unregistered handle.
            assertEq(abi.decode(out, (string)), "", "a value under a padded name");
        } catch { }
    }

    // --- signatures ---

    function testFuzz_setValue_bindsEveryField(uint256 deadline, uint256 otherDeadline, uint256 key) public {
        deadline = bound(deadline, block.timestamp, type(uint64).max);
        otherDeadline = bound(otherDeadline, block.timestamp, type(uint64).max);
        key = bound(key, 1, 2 ** 200);
        vm.assume(otherDeadline != deadline && key != CONTROLLER_KEY);

        bytes memory sig = _sign(CONTROLLER_KEY, LABEL, "next", deadline);
        vm.expectRevert(LelantosNameRegistrar.InvalidSigner.selector);
        registrar.setValue(LABEL, "next", otherDeadline, sig);

        bytes memory forged = _sign(key, LABEL, "next", deadline);
        vm.expectRevert(LelantosNameRegistrar.InvalidSigner.selector);
        registrar.setValue(LABEL, "next", deadline, forged);

        registrar.setValue(LABEL, "next", deadline, sig);
        assertEq(_resolveText(LABEL), "next");
    }
}
