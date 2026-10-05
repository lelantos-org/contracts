// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Test.sol";

import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";

import { NameRegistrationTestBase } from "./NameRegistrationTestBase.sol";

/// Gas of the registration call leg, which sizes the `minGas` a wallet binds
/// into its intent.
///
/// The figure that counts is the one a plain `forge test` reports. There the
/// input reaches the wrapper in the same transaction as the leg, as it does on
/// chain, so the sweep back writes a balance slot that began the transaction
/// empty. Under `--isolate` the input predates the transaction and that write
/// is about 20k cheaper.
///
///     forge test --match-contract NameRegistrationGasTest -vv
contract NameRegistrationGasTest is NameRegistrationTestBase {
    /// The leg, with the allowance for a dearer fee token, must fit
    /// `REGISTER_MIN_GAS` with a quarter to spare.
    function test_gas_registerCallLeg_fitsMinGas() public {
        GenericCallWrapper.GenericArgs memory a = _registerArgs(LABEL);
        uint256 used = _callLegGas(a);
        emit log_named_uint("register call leg gas", used);
        uint256 budgeted = used + FEE_TOKEN_PREMIUM;
        assertLe(budgeted + budgeted / 4, REGISTER_MIN_GAS, "REGISTER_MIN_GAS no longer covers the call leg");
    }

    function test_gas_registerExecute() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _registerArgs(LABEL);
        a.minGas = REGISTER_MIN_GAS;
        _execute(a);
        Vm.Gas memory g = vm.lastCallGas();
        emit log_named_uint("register execute gas (stub pool)", g.gasTotalUsed);
        assertFalse(registrar.available(LABEL), "registered");
    }

    /// `callLeg` run directly, as the wrapper calls itself, with the input
    /// already delivered.
    function _callLegGas(GenericCallWrapper.GenericArgs memory a) internal returns (uint256) {
        tokenA.mint(address(wrapper), _received());
        GenericCallWrapper.CallLeg memory leg;
        leg.tokenIn = address(tokenA);
        leg.amountIn = _received();
        leg.tokens = new address[](1);
        leg.tokens[0] = address(tokenA);
        leg.baseline = new uint256[](1);
        leg.minOuts = new uint256[](1);
        leg.minOuts[0] = a.outputs[0].minOut;
        leg.deadline = a.deadline;
        leg.nativeTo = a.surplusTo;

        vm.prank(address(wrapper));
        wrapper.callLeg(a.calls, leg);
        return vm.lastCallGas().gasTotalUsed;
    }
}
