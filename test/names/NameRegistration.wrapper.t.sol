// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { LelantosNameRegistrar } from "../../src/names/LelantosNameRegistrar.sol";

import { GenericIntent } from "../generic/GenericIntent.sol";
import { NameRegistrationTestBase } from "./NameRegistrationTestBase.sol";

/// Registration through `GenericCallWrapper.execute`: the handle is recorded
/// and the fee paid from unshielded funds, or the input is refunded.
contract NameRegistrationWrapperTest is NameRegistrationTestBase {
    function setUp() public override {
        super.setUp();
        _fundWithdraw();
    }

    function test_register_recordsTheHandleAndReshieldsTheChange() public {
        GenericCallWrapper.GenericArgs memory a = _registerArgs(LABEL);
        address clone = _nextExecutor();

        uint256[] memory ids = _execute(a);

        (string memory value, address ctl,) = registrar.recordOf(LABEL);
        assertEq(value, VALUE, "value");
        assertEq(ctl, controller, "controller");
        assertEq(tokenA.balanceOf(TREASURY), FEE, "fee at the treasury");

        assertEq(ids.length, 1, "one output escrowed");
        assertEq(pool.lastDepositAssetId(), ASSET_A, "change escrowed in A");
        uint256 change = _pull(_changeUnits());
        assertEq(tokenA.balanceOf(SURPLUS_TO), _received() - FEE - change, "rounding to surplusTo");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "nothing left on the wrapper");
        assertEq(tokenA.balanceOf(clone), 0, "nothing left on the clone");
        assertEq(tokenA.allowance(clone, address(registrar)), 0, "approval spent");
    }

    function test_register_labelTakenRefundsTheInput() public {
        _registerDirect(LABEL, "lelantos1first", address(0xF1257));
        // The fee of that direct registration; none is taken below.
        uint256 before = tokenA.balanceOf(TREASURY);

        bytes4 reason = _executeExpectRefund(_registerArgs(LABEL));

        assertEq(reason, LelantosNameRegistrar.LabelTaken.selector, "reason");
        (string memory value, address ctl,) = registrar.recordOf(LABEL);
        assertEq(value, "lelantos1first", "first registration stands");
        assertEq(ctl, address(0xF1257), "its controller too");
        assertEq(tokenA.balanceOf(TREASURY), before, "no fee taken");
    }

    function test_register_feeRaisedAfterSigningRefunds() public {
        GenericCallWrapper.GenericArgs memory a = _registerArgs(LABEL);
        vm.prank(OWNER);
        registrar.setFee(IERC20(address(tokenA)), FEE + 1, TREASURY);

        bytes4 reason = _executeExpectRefund(a);

        assertEq(reason, IERC20Errors.ERC20InsufficientAllowance.selector, "reason");
        assertTrue(registrar.available(LABEL), "not registered");
        assertEq(tokenA.balanceOf(TREASURY), 0, "no fee taken");
    }

    function test_register_feeLoweredAfterSigningLands() public {
        GenericCallWrapper.GenericArgs memory a = _registerArgs(LABEL);
        vm.prank(OWNER);
        registrar.setFee(IERC20(address(tokenA)), FEE - 1e10, TREASURY);

        _execute(a);

        assertFalse(registrar.available(LABEL), "registered");
        assertEq(tokenA.balanceOf(TREASURY), FEE - 1e10, "the lower fee");
        // What the registrar did not take comes back with the change.
        assertEq(tokenA.balanceOf(SURPLUS_TO), _received() - (FEE - 1e10) - _pull(_changeUnits()), "surplus");
    }

    function test_register_invalidLabelRefunds() public {
        bytes4 reason = _executeExpectRefund(_registerArgs("Mehow"));
        assertEq(reason, LelantosNameRegistrar.InvalidLabel.selector);
    }

    /// The submitter cannot register another label or controller with the
    /// user's proof.
    function test_register_revert_tamperedCall() public {
        GenericCallWrapper.GenericArgs memory a = GenericIntent.bind(_registerArgs(LABEL));
        a.calls[1].data = abi.encodeCall(LelantosNameRegistrar.register, (LABEL, VALUE, address(0xBAD)));
        vm.expectRevert(GenericCallWrapper.IntentMismatch.selector);
        wrapper.execute(a);
    }

    function test_setValue_throughTheWrapper() public {
        _registerDirect(LABEL, VALUE, controller);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(CONTROLLER_KEY, registrar.setValueDigest(LABEL, "lelantos1next", deadline));

        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _oneCall(
            _call(
                address(registrar),
                abi.encodeCall(
                    LelantosNameRegistrar.setValue, (LABEL, "lelantos1next", deadline, abi.encodePacked(r, s, v))
                )
            )
        );
        // No fee: the whole input comes back.
        a.outputs = _oneOutput(_output(ASSET_A, _refundUnits()));
        _execute(a);

        (string memory value,, uint64 nonce) = registrar.recordOf(LABEL);
        assertEq(value, "lelantos1next", "value");
        assertEq(nonce, 1, "nonce");
    }
}
