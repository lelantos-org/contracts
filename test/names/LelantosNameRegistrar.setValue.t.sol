// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { LelantosNameRegistrar } from "../../src/names/LelantosNameRegistrar.sol";

import { NameRegistrarTestBase } from "./NameRegistrarTestBase.sol";

/// `setValue`: only the handle's controller changes its value, once per
/// signature, on this contract and chain.
contract LelantosNameRegistrarSetValueTest is NameRegistrarTestBase {
    string internal constant NEXT = "lelantos1next";
    uint256 internal constant DEADLINE = 2_000_000_000;

    function setUp() public override {
        super.setUp();
        registrar.register(LABEL, VALUE, controller);
    }

    function test_setValue_replacesTheValue() public {
        bytes memory sig = _sign(CONTROLLER_KEY, LABEL, NEXT, DEADLINE);

        vm.expectEmit(address(registrar));
        emit LelantosNameRegistrar.ValueChanged(keccak256(bytes(LABEL)), NEXT);
        // Anyone may submit it.
        vm.prank(address(0xBEEF));
        registrar.setValue(LABEL, NEXT, DEADLINE, sig);

        (string memory value, address ctl, uint64 nonce) = registrar.recordOf(LABEL);
        assertEq(value, NEXT, "value");
        assertEq(ctl, controller, "controller unchanged");
        assertEq(nonce, 1, "nonce");
    }

    function test_setValue_emptyClearsAndKeepsTheHandle() public {
        registrar.setValue(LABEL, "", DEADLINE, _sign(CONTROLLER_KEY, LABEL, "", DEADLINE));

        (string memory value, address ctl,) = registrar.recordOf(LABEL);
        assertEq(value, "", "cleared");
        assertEq(ctl, controller, "still registered");
        assertFalse(registrar.available(LABEL), "not released");

        vm.expectRevert(LelantosNameRegistrar.LabelTaken.selector);
        registrar.register(LABEL, VALUE, address(0xBAD));

        // And it can be published again.
        registrar.setValue(LABEL, VALUE, DEADLINE, _sign(CONTROLLER_KEY, LABEL, VALUE, DEADLINE));
        assertEq(registrar.valueOf(keccak256(bytes(LABEL))), VALUE, "republished");
    }

    function test_revert_InvalidSigner_wrongKey() public {
        bytes memory sig = _sign(0xBAD, LABEL, NEXT, DEADLINE);
        vm.expectRevert(LelantosNameRegistrar.InvalidSigner.selector);
        registrar.setValue(LABEL, NEXT, DEADLINE, sig);
    }

    function test_revert_InvalidSigner_replay() public {
        bytes memory sig = _sign(CONTROLLER_KEY, LABEL, NEXT, DEADLINE);
        registrar.setValue(LABEL, NEXT, DEADLINE, sig);
        vm.expectRevert(LelantosNameRegistrar.InvalidSigner.selector);
        registrar.setValue(LABEL, NEXT, DEADLINE, sig);
    }

    function test_revert_InvalidSigner_otherValue() public {
        bytes memory sig = _sign(CONTROLLER_KEY, LABEL, NEXT, DEADLINE);
        vm.expectRevert(LelantosNameRegistrar.InvalidSigner.selector);
        registrar.setValue(LABEL, "lelantos1other", DEADLINE, sig);
    }

    function test_revert_InvalidSigner_otherDeadline() public {
        bytes memory sig = _sign(CONTROLLER_KEY, LABEL, NEXT, DEADLINE);
        vm.expectRevert(LelantosNameRegistrar.InvalidSigner.selector);
        registrar.setValue(LABEL, NEXT, DEADLINE + 1, sig);
    }

    /// A signature for one handle does not move another with the same controller.
    function test_revert_InvalidSigner_otherLabel() public {
        registrar.register("other", VALUE, controller);
        bytes memory sig = _sign(CONTROLLER_KEY, LABEL, NEXT, DEADLINE);
        vm.expectRevert(LelantosNameRegistrar.InvalidSigner.selector);
        registrar.setValue("other", NEXT, DEADLINE, sig);
    }

    function test_revert_InvalidSigner_otherContract() public {
        LelantosNameRegistrar other = _newRegistrar(new string[](0), address(0));
        other.register(LABEL, VALUE, controller);
        bytes memory sig = _sign(CONTROLLER_KEY, LABEL, NEXT, DEADLINE);
        vm.expectRevert(LelantosNameRegistrar.InvalidSigner.selector);
        other.setValue(LABEL, NEXT, DEADLINE, sig);
    }

    function test_revert_InvalidSigner_otherChain() public {
        bytes memory sig = _sign(CONTROLLER_KEY, LABEL, NEXT, DEADLINE);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(LelantosNameRegistrar.InvalidSigner.selector);
        registrar.setValue(LABEL, NEXT, DEADLINE, sig);
    }

    function test_revert_highS() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CONTROLLER_KEY, registrar.setValueDigest(LABEL, NEXT, DEADLINE));
        // The same signature with `s` mirrored: valid ECDSA, rejected as malleable.
        bytes32 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(uint256(n) - uint256(s));
        bytes memory sig = abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        registrar.setValue(LABEL, NEXT, DEADLINE, sig);
    }

    function test_revert_SignatureExpired() public {
        bytes memory sig = _sign(CONTROLLER_KEY, LABEL, NEXT, DEADLINE);
        vm.warp(DEADLINE + 1);
        vm.expectRevert(LelantosNameRegistrar.SignatureExpired.selector);
        registrar.setValue(LABEL, NEXT, DEADLINE, sig);
    }

    function test_setValue_landsAtTheDeadline() public {
        bytes memory sig = _sign(CONTROLLER_KEY, LABEL, NEXT, DEADLINE);
        vm.warp(DEADLINE);
        registrar.setValue(LABEL, NEXT, DEADLINE, sig);
    }

    function test_revert_UnknownLabel() public {
        bytes memory sig = _sign(CONTROLLER_KEY, "nobody", NEXT, DEADLINE);
        vm.expectRevert(LelantosNameRegistrar.UnknownLabel.selector);
        registrar.setValue("nobody", NEXT, DEADLINE, sig);
    }

    function test_revert_InvalidValue() public {
        bytes memory sig = _sign(CONTROLLER_KEY, LABEL, "a b", DEADLINE);
        vm.expectRevert(LelantosNameRegistrar.InvalidValue.selector);
        registrar.setValue(LABEL, "a b", DEADLINE, sig);
    }

    /// A reserved handle's controller is an ordinary address; without its key
    /// the handle stays empty.
    function test_reservedHandle_cannotBeSetByAnotherKey() public {
        bytes memory sig = _sign(CONTROLLER_KEY, "admin", NEXT, DEADLINE);
        vm.expectRevert(LelantosNameRegistrar.InvalidSigner.selector);
        registrar.setValue("admin", NEXT, DEADLINE, sig);
    }
}
