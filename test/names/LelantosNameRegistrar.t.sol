// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LelantosNameRegistrar } from "../../src/names/LelantosNameRegistrar.sol";
import { OwnableInit } from "../../src/OwnableInit.sol";

import { NameRegistrarTestBase } from "./NameRegistrarTestBase.sol";

/// `LelantosNameRegistrar`: registration, the label and value rules, and the
/// constructor's reserved labels.
contract LelantosNameRegistrarTest is NameRegistrarTestBase {
    function test_register_storesTheRecord() public {
        assertTrue(registrar.available(LABEL), "free before");

        vm.expectEmit(address(registrar));
        emit LelantosNameRegistrar.HandleRegistered(keccak256(bytes(LABEL)), controller, LABEL);
        vm.expectEmit(address(registrar));
        emit LelantosNameRegistrar.ValueChanged(keccak256(bytes(LABEL)), VALUE);
        registrar.register(LABEL, VALUE, controller);

        (string memory value, address ctl, uint64 nonce) = registrar.recordOf(LABEL);
        assertEq(value, VALUE, "value");
        assertEq(ctl, controller, "controller");
        assertEq(nonce, 0, "nonce");
        assertEq(registrar.valueOf(keccak256(bytes(LABEL))), VALUE, "valueOf");
        assertFalse(registrar.available(LABEL), "taken after");
    }

    function test_register_anyCallerMayRegisterForAnyController() public {
        vm.prank(address(0xBEEF));
        registrar.register(LABEL, VALUE, controller);
        (, address ctl,) = registrar.recordOf(LABEL);
        assertEq(ctl, controller);
    }

    function test_revert_LabelTaken() public {
        registrar.register(LABEL, VALUE, controller);
        vm.expectRevert(LelantosNameRegistrar.LabelTaken.selector);
        registrar.register(LABEL, "other", address(0xBAD));
    }

    function test_revert_InvalidController() public {
        vm.expectRevert(LelantosNameRegistrar.InvalidController.selector);
        registrar.register(LABEL, VALUE, address(0));
    }

    function test_revert_InvalidValue_empty() public {
        vm.expectRevert(LelantosNameRegistrar.InvalidValue.selector);
        registrar.register(LABEL, "", controller);
    }

    function test_revert_InvalidValue_tooLong() public {
        bytes memory long = new bytes(registrar.MAX_VALUE_LENGTH() + 1);
        for (uint256 i; i < long.length; ++i) {
            long[i] = "a";
        }
        vm.expectRevert(LelantosNameRegistrar.InvalidValue.selector);
        registrar.register(LABEL, string(long), controller);
    }

    function test_register_acceptsTheLongestValue() public {
        bytes memory longest = new bytes(registrar.MAX_VALUE_LENGTH());
        for (uint256 i; i < longest.length; ++i) {
            longest[i] = "~";
        }
        registrar.register(LABEL, string(longest), controller);
        assertEq(registrar.valueOf(keccak256(bytes(LABEL))), string(longest));
    }

    /// Space, DEL, a control character, a high byte, and each of them placed
    /// in the padded tail of a word and on a word boundary.
    function test_revert_InvalidValue_nonPrintable() public {
        string[8] memory bad = [
            "a b",
            "ab\x7f",
            "a\nb",
            "ab\x80",
            "\x00",
            "0123456789012345678901234567890 ",
            "01234567890123456789012345678901\x1f",
            "0123456789012345678901234567890123456789\xff"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(LelantosNameRegistrar.InvalidValue.selector);
            registrar.register(LABEL, bad[i], controller);
        }
    }

    function test_isValidLabel_acceptsTheAllowedShapes() public view {
        string[6] memory good = ["abc", "a-b", "a1b2c3", "000", "mehow", "abcdefghijklmnopqrstuvwxyz012345"];
        for (uint256 i; i < good.length; ++i) {
            assertTrue(registrar.isValidLabel(good[i]), good[i]);
        }
    }

    function test_isValidLabel_rejectsEverythingElse() public view {
        string[12] memory bad = [
            "",
            "ab",
            "abcdefghijklmnopqrstuvwxyz0123456",
            "-ab",
            "ab-",
            "a--b",
            "ab--cd",
            "Abc",
            "a.b",
            "a b",
            "a_b",
            "ab\xc3\xa9"
        ];
        for (uint256 i; i < bad.length; ++i) {
            assertFalse(registrar.isValidLabel(bad[i]), bad[i]);
        }
    }

    function test_revert_InvalidLabel() public {
        vm.expectRevert(LelantosNameRegistrar.InvalidLabel.selector);
        registrar.register("Mehow", VALUE, controller);
    }

    function test_available_isFalseForAnInvalidLabel() public view {
        assertFalse(registrar.available("a--b"));
    }

    // --- constructor ---

    function test_constructor_seedsReservedLabels() public {
        (string memory value, address ctl,) = registrar.recordOf("admin");
        assertEq(value, "", "reserved value is empty");
        assertEq(ctl, RESERVED_CONTROLLER, "reserved controller");
        assertFalse(registrar.available("support"));

        vm.expectRevert(LelantosNameRegistrar.LabelTaken.selector);
        registrar.register("admin", VALUE, controller);
    }

    function test_constructor_setsOwnerAndFee() public view {
        assertEq(registrar.owner(), OWNER);
        assertEq(registrar.feeAmount(), 0);
    }

    function test_constructor_revert_reservedWithoutController() public {
        string[] memory reserved = new string[](1);
        reserved[0] = "admin";
        vm.expectRevert(LelantosNameRegistrar.InvalidController.selector);
        _newRegistrar(reserved, address(0));
    }

    function test_constructor_revert_invalidReservedLabel() public {
        string[] memory reserved = new string[](1);
        reserved[0] = "Admin";
        vm.expectRevert(LelantosNameRegistrar.InvalidLabel.selector);
        _newRegistrar(reserved, RESERVED_CONTROLLER);
    }

    function test_constructor_revert_duplicateReservedLabel() public {
        string[] memory reserved = new string[](2);
        reserved[0] = "admin";
        reserved[1] = "admin";
        vm.expectRevert(LelantosNameRegistrar.LabelTaken.selector);
        _newRegistrar(reserved, RESERVED_CONTROLLER);
    }

    function test_constructor_revert_zeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableInit.OwnableInvalidOwner.selector, address(0)));
        new LelantosNameRegistrar(address(0), IERC20(address(0)), 0, address(0), new string[](0), address(0));
    }
}
