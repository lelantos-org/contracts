// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { CallExecutor } from "../../src/generic/CallExecutor.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { GenericCallTestBase } from "./GenericCallTestBase.sol";
import { GenericIntent } from "./GenericIntent.sol";

/// Every field outside the withdraw proof is bound through `pi_w.intentHash`:
/// changing any of them after the wallet bound the payload reverts
/// `IntentMismatch`, so the submitter cannot alter what the funds do.
contract GenericCallWrapperBindingTest is GenericCallTestBase {
    /// `test_intentHash_crossLanguageVector`'s expected hash.
    uint256 internal constant INTENT_VECTOR =
        827_219_559_487_417_732_596_895_015_167_420_095_798_095_380_869_771_450_310_630_500_175_677_464_989;

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

    function test_tamper_outputInner() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.outputs[0].deposit.inner = bytes32(uint256(0xBAD));
        _expectMismatch(a);
    }

    function test_tamper_outputValue() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.outputs[0].deposit.publicIn -= 1;
        _expectMismatch(a);
    }

    function test_tamper_outputFeeNote() public {
        GenericCallWrapper.GenericArgs memory a = _bound();
        a.outputs[0].deposit.feeInner = bytes32(uint256(0xBAD));
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

    /// Cross-language vector. The SDK (`genericIntentHash`) and the relayer
    /// (`generic_intent_hash`) pin the same literal payload to the same value; a
    /// change to the encoding must update all three.
    function test_intentHash_crossLanguageVector() public view {
        GenericCallWrapper.GenericArgs memory a;
        a.refundTo = address(0x4EF0);
        a.surplusTo = address(0x5E55);
        a.deadline = 1_900_000_000;
        a.minGas = 600_000;

        a.calls = new CallExecutor.Call[](2);
        a.calls[0] = CallExecutor.Call({ target: address(0xCA11), value: 0, data: hex"aabbccdd01" });
        a.calls[1] = CallExecutor.Call({ target: address(0xCA12), value: 7, data: "" });

        a.outputs = new GenericCallWrapper.Output[](2);
        a.outputs[0].minOut = 990e10;
        a.outputs[0].deposit = PubInputs.DepositRequest({
            chainId: 31_337,
            publicAssetId: 2,
            publicIn: 990,
            payer: address(0x5A5A),
            recipient: address(0xBEEF),
            inner: bytes32(uint256(1)),
            feeAssetId: 2,
            feeIn: 5,
            feeInner: bytes32(uint256(6))
        });
        a.outputs[0].aux = AuxValidation.Output({
            clueRx: 10, clueRy: 11, clueQx: 40, clueQy: 41, ephPubX: 12, ephPubY: 13, ciphertext: hex"0102"
        });
        a.outputs[0].feeAux = AuxValidation.Output({
            clueRx: 14, clueRy: 15, clueQx: 42, clueQy: 43, ephPubX: 16, ephPubY: 17, ciphertext: hex"030405"
        });
        a.outputs[1].minOut = 3e10;
        a.outputs[1].deposit = PubInputs.DepositRequest({
            chainId: 31_337,
            publicAssetId: 3,
            publicIn: 3,
            payer: address(0x5A5A),
            recipient: address(0xBEEF),
            inner: bytes32(uint256(0x21)),
            feeAssetId: 0,
            feeIn: 0,
            feeInner: bytes32(0)
        });
        a.outputs[1].aux = AuxValidation.Output({
            clueRx: 50, clueRy: 51, clueQx: 52, clueQy: 53, ephPubX: 54, ephPubY: 55, ciphertext: hex"09"
        });
        a.outputs[1].feeAux = AuxValidation.Output({
            clueRx: 56, clueRy: 57, clueQx: 58, clueQy: 59, ephPubX: 60, ephPubY: 61, ciphertext: hex"0a0b"
        });

        a.refund_d = PubInputs.DepositRequest({
            chainId: 31_337,
            publicAssetId: 1,
            publicIn: 995,
            payer: address(0x5A5A),
            recipient: address(0xBEEF),
            inner: bytes32(uint256(0x12)),
            feeAssetId: 1,
            feeIn: 22,
            feeInner: bytes32(uint256(0x17))
        });
        a.refund_aux_d = AuxValidation.Output({
            clueRx: 27, clueRy: 28, clueQx: 44, clueQy: 45, ephPubX: 29, ephPubY: 30, ciphertext: hex"06"
        });
        a.refund_fee_aux_d = AuxValidation.Output({
            clueRx: 31, clueRy: 32, clueQx: 46, clueQy: 47, ephPubX: 33, ephPubY: 34, ciphertext: hex"0708"
        });

        assertEq(GenericIntent.hash(a), INTENT_VECTOR, "cross-language vector");
        assertEq(wrapper.intentHash(a), INTENT_VECTOR, "contract agrees");
    }
}
