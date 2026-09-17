// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { CallExecutor } from "../../src/generic/CallExecutor.sol";

import { GenericCallTestBase } from "./GenericCallTestBase.sol";
import { GenericIntent } from "./GenericIntent.sol";

/// Every field outside the withdraw proof is bound through `pi_w.intentHash`:
/// changing any of them after the wallet bound the payload reverts
/// `IntentMismatch`, so the submitter cannot alter what the funds do.
contract GenericCallWrapperBindingTest is GenericCallTestBase {
    function setUp() public override {
        super.setUp();
        _fundWithdraw();
    }

    /// A bound two-output payload, with every optional field set, that the tamper
    /// tests start from.
    function _bound() internal view returns (GenericCallWrapper.GenericArgs memory a) {
        a = _base();
        a.calls = _splitCalls(_received(), _pull(400), _pull(10));
        a.outputs = _twoOutputs(_output(ASSET_B, 400), _output(ASSET_C, 10));
        a.minGas = 100_000;
        a.deadline = block.timestamp + 1 hours;
        a.outputs[0].aux.ciphertext = hex"0000aa";
        a.refund_aux_d.ciphertext = hex"0000bb";
        a = GenericIntent.bind(a);
    }

    function _expectMismatch(GenericCallWrapper.GenericArgs memory a) internal {
        vm.expectRevert(GenericCallWrapper.IntentMismatch.selector);
        wrapper.execute(a);
    }

    /// The untouched payload lands, so each tamper test fails on its field alone.
    function test_untampered_lands() public {
        uint256[] memory ids = wrapper.execute(_bound());
        assertEq(ids.length, 2, "both outputs escrowed");
    }

    function test_tamper_refundTo() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.refundTo = address(0xBAD);
        _expectMismatch(a);
    }

    function test_tamper_surplusTo() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.surplusTo = address(0xBAD);
        _expectMismatch(a);
    }

    function test_tamper_deadline() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.deadline += 1;
        _expectMismatch(a);
    }

    function test_tamper_minGas() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.minGas = 0;
        _expectMismatch(a);
    }

    function test_tamper_callTarget() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.calls[1].target = address(0xBAD);
        _expectMismatch(a);
    }

    function test_tamper_callValue() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.calls[1].value = 1;
        _expectMismatch(a);
    }

    function test_tamper_callData() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.calls[1].data[a.calls[1].data.length - 1] = 0x01;
        _expectMismatch(a);
    }

    function test_tamper_dropCall() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        CallExecutor.Call[] memory one = new CallExecutor.Call[](1);
        one[0] = a.calls[0];
        a.calls = one;
        _expectMismatch(a);
    }

    function test_tamper_appendCall() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        CallExecutor.Call[] memory three = new CallExecutor.Call[](3);
        three[0] = a.calls[0];
        three[1] = a.calls[1];
        three[2] = a.calls[1];
        a.calls = three;
        _expectMismatch(a);
    }

    function test_tamper_minOut() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.outputs[0].minOut -= 1;
        _expectMismatch(a);
    }

    function test_tamper_outputRecipient() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.outputs[0].deposit.recipient = address(0xBAD);
        _expectMismatch(a);
    }

    function test_tamper_outputCommitment() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.outputs[0].deposit.outCm = bytes32(uint256(0xBAD));
        _expectMismatch(a);
    }

    function test_tamper_outputValue() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.outputs[0].deposit.publicIn -= 1;
        _expectMismatch(a);
    }

    function test_tamper_outputFeeNote() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.outputs[0].deposit.feeCm = bytes32(uint256(0xBAD));
        _expectMismatch(a);
    }

    function test_tamper_outputAux() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.outputs[0].aux.ciphertext = hex"0000cc";
        _expectMismatch(a);
    }

    function test_tamper_outputFeeAux() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.outputs[1].feeAux.clueRx = 1;
        _expectMismatch(a);
    }

    function test_tamper_swapOutputOrder() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        (a.outputs[0], a.outputs[1]) = (a.outputs[1], a.outputs[0]);
        _expectMismatch(a);
    }

    function test_tamper_dropOutput() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.outputs = _oneOutput(a.outputs[0]);
        _expectMismatch(a);
    }

    function test_tamper_refundRecipient() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.refund_d.recipient = address(0xBAD);
        _expectMismatch(a);
    }

    function test_tamper_refundValue() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.refund_d.publicIn -= 1;
        _expectMismatch(a);
    }

    function test_tamper_refundAux() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.refund_aux_d.ciphertext = hex"0000cc";
        _expectMismatch(a);
    }

    function test_tamper_refundFeeAux() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.refund_fee_aux_d.ephPubX = 1;
        _expectMismatch(a);
    }
}
