// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { LelantosNameRegistrar } from "../../src/names/LelantosNameRegistrar.sol";
import { OwnableInit } from "../../src/OwnableInit.sol";

import { NameRegistrarTestBase } from "./NameRegistrarTestBase.sol";
import { NoReturnERC20 } from "./mocks/NoReturnERC20.sol";

/// The registration fee: pulled from the caller to the treasury, and set by
/// the owner alone.
contract LelantosNameRegistrarFeeTest is NameRegistrarTestBase {
    uint96 internal constant FEE = 5e6;
    address internal constant PAYER = address(0xFA7E);

    function test_register_pullsTheFeeToTheTreasury() public {
        _setFee(FEE);
        feeToken.mint(PAYER, FEE);
        vm.startPrank(PAYER);
        feeToken.approve(address(registrar), FEE);
        registrar.register(LABEL, VALUE, controller);
        vm.stopPrank();

        assertEq(feeToken.balanceOf(TREASURY), FEE, "treasury paid");
        assertEq(feeToken.balanceOf(PAYER), 0, "payer charged");
        assertEq(feeToken.balanceOf(address(registrar)), 0, "nothing held");
    }

    function test_register_zeroFeeTouchesNoToken() public {
        // The fee token is the zero address here: a call to it would revert.
        registrar.register(LABEL, VALUE, controller);
        assertFalse(registrar.available(LABEL));
    }

    function test_register_revert_withoutAllowance() public {
        _setFee(FEE);
        feeToken.mint(PAYER, FEE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(registrar), 0, FEE)
        );
        vm.prank(PAYER);
        registrar.register(LABEL, VALUE, controller);
        assertTrue(registrar.available(LABEL), "not registered");
    }

    function test_register_worksWithATokenReturningNothing() public {
        NoReturnERC20 token = new NoReturnERC20();
        vm.prank(OWNER);
        registrar.setFee(IERC20(address(token)), FEE, TREASURY);
        token.mint(PAYER, FEE);
        vm.startPrank(PAYER);
        token.approve(address(registrar), FEE);
        registrar.register(LABEL, VALUE, controller);
        vm.stopPrank();
        assertEq(token.balanceOf(TREASURY), FEE);
    }

    function test_setValue_chargesNothing() public {
        registrar.register(LABEL, VALUE, controller);
        _setFee(FEE);
        // No allowance and no balance: a pull would revert.
        registrar.setValue(LABEL, "next", 2e9, _sign(CONTROLLER_KEY, LABEL, "next", 2e9));
    }

    function test_setFee_emitsAndStores() public {
        vm.expectEmit(address(registrar));
        emit LelantosNameRegistrar.FeeSet(IERC20(address(feeToken)), FEE, TREASURY);
        _setFee(FEE);
        assertEq(address(registrar.feeToken()), address(feeToken));
        assertEq(registrar.feeAmount(), FEE);
        assertEq(registrar.treasury(), TREASURY);
    }

    function test_setFee_revert_notOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableInit.OwnableUnauthorizedAccount.selector, address(this)));
        registrar.setFee(IERC20(address(feeToken)), FEE, TREASURY);
    }

    function test_setFee_revert_InvalidFee() public {
        vm.startPrank(OWNER);
        vm.expectRevert(LelantosNameRegistrar.InvalidFee.selector);
        registrar.setFee(IERC20(address(0)), FEE, TREASURY);
        vm.expectRevert(LelantosNameRegistrar.InvalidFee.selector);
        registrar.setFee(IERC20(address(feeToken)), FEE, address(0));
        vm.stopPrank();
    }

    function test_setFee_zeroDisablesWithAnyTokenAndTreasury() public {
        _setFee(FEE);
        vm.prank(OWNER);
        registrar.setFee(IERC20(address(0)), 0, address(0));
        registrar.register(LABEL, VALUE, controller);
    }

    function test_constructor_revert_InvalidFee() public {
        vm.expectRevert(LelantosNameRegistrar.InvalidFee.selector);
        new LelantosNameRegistrar(OWNER, IERC20(address(0)), FEE, TREASURY, new string[](0), address(0));
    }
}
