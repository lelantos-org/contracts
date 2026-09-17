// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { CallExecutor } from "../../src/generic/CallExecutor.sol";

import { GenericCallTestBase } from "./GenericCallTestBase.sol";
import { GenericIntent } from "./GenericIntent.sol";
import { MockRouter } from "./mocks/MockCallTargets.sol";

/// Reverts of `execute` (nothing lands, the proof stays unspent) and refunds for
/// denied targets (the input comes back as a note).
contract GenericCallWrapperNegTest is GenericCallTestBase {
    // -------- binding checks revert -------------------------------------

    function test_revert_notRecipient() public {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.pi_w.recipient = address(0xBAD);
        vm.expectRevert(GenericCallWrapper.WrapperNotRecipient.selector);
        _execute(a);
    }

    function test_revert_notRelayer() public {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.pi_w.relayer = address(0xBAD);
        vm.expectRevert(GenericCallWrapper.WrapperNotRelayer.selector);
        _execute(a);
    }

    function test_revert_refundPayerNotWrapper() public {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.refund_d.payer = address(0xBAD);
        vm.expectRevert(GenericCallWrapper.WrapperNotPayer.selector);
        _execute(a);
    }

    function test_revert_outputPayerNotWrapper() public {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.outputs[0].deposit.payer = address(0xBAD);
        vm.expectRevert(GenericCallWrapper.WrapperNotPayer.selector);
        _execute(a);
    }

    /// A proof lifted from the mempool cannot be landed by anyone but its payer.
    function test_revert_callerNotPayer() public {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.pi_w.payer = address(0xB0B);
        vm.expectRevert(
            abi.encodeWithSelector(GenericCallWrapper.UnauthorizedCaller.selector, address(this), address(0xB0B))
        );
        _execute(a);
    }

    function test_revert_badRefundTo() public {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.refundTo = address(0);
        vm.expectRevert(GenericCallWrapper.InvalidRefundTo.selector);
        _execute(a);
        a.refundTo = address(wrapper);
        vm.expectRevert(GenericCallWrapper.InvalidRefundTo.selector);
        _execute(a);
    }

    function test_revert_badSurplusTo() public {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.surplusTo = address(0);
        vm.expectRevert(GenericCallWrapper.InvalidSurplusTo.selector);
        _execute(a);
        a.surplusTo = address(wrapper);
        vm.expectRevert(GenericCallWrapper.InvalidSurplusTo.selector);
        _execute(a);
    }

    function test_revert_refundInAnotherToken() public {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.refund_d.publicAssetId = ASSET_B;
        vm.expectRevert(GenericCallWrapper.TokenInMismatch.selector);
        _execute(a);
    }

    /// Two asset ids sharing one token cannot both be outputs: one delivered
    /// balance would be counted twice.
    function test_revert_duplicateOutputToken_acrossAssetIds() public {
        uint64 assetB2 = 9;
        pool.registerAsset(assetB2, address(tokenB), SCALE);
        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _swapCalls(address(tokenB), _received(), 2 * _pull(400));
        a.outputs = _twoOutputs(_output(ASSET_B, 400), _output(assetB2, 400));
        vm.expectRevert(abi.encodeWithSelector(GenericCallWrapper.DuplicateOutputToken.selector, address(tokenB)));
        _execute(a);
    }

    function test_revert_outputCount() public {
        GenericCallWrapper.GenericArgs memory a = _base();
        vm.expectRevert(GenericCallWrapper.BadOutputCount.selector);
        _execute(a);

        a.outputs = new GenericCallWrapper.Output[](5);
        vm.expectRevert(GenericCallWrapper.BadOutputCount.selector);
        _execute(a);
    }

    function test_revert_tooManyCalls() public {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.calls = new CallExecutor.Call[](17);
        vm.expectRevert(GenericCallWrapper.TooManyCalls.selector);
        _execute(a);
    }

    function test_revert_zeroMinOut() public {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.outputs[0].minOut = 0;
        vm.expectRevert(abi.encodeWithSelector(GenericCallWrapper.MinOutZero.selector, 0));
        _execute(a);
    }

    function test_revert_zeroAmountIn() public {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.amountIn = 0;
        vm.expectRevert(GenericCallWrapper.AmountInZero.selector);
        _execute(a);
    }

    function test_revert_yieldOutput() public {
        pool.setYieldAsset(ASSET_B, true);
        vm.expectRevert(abi.encodeWithSelector(GenericCallWrapper.YieldAssetNotSupported.selector, ASSET_B));
        _execute(_swapArgs(990, _pull(990)));
    }

    function test_revert_yieldRefund() public {
        pool.setYieldAsset(ASSET_A, true);
        vm.expectRevert(abi.encodeWithSelector(GenericCallWrapper.YieldAssetNotSupported.selector, ASSET_A));
        _execute(_swapArgs(990, _pull(990)));
    }

    function test_revert_insufficientWithdraw() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.amountIn = _received() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(GenericCallWrapper.InsufficientWithdraw.selector, _received(), _received() + 1)
        );
        _execute(a);
    }

    // -------- gas -------------------------------------------------------

    /// Below the intent's gas floor the whole call reverts, so a submitter
    /// cannot choose a limit that turns the execution into a refund.
    function test_revert_belowMinGas() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.minGas = 10_000_000;
        GenericCallWrapper.GenericArgs memory signed = GenericIntent.bind(a);
        vm.expectPartialRevert(GenericCallWrapper.InsufficientGas.selector);
        wrapper.execute{ gas: 5_000_000 }(signed);

        // The same payload with the floor met lands.
        wrapper.execute{ gas: 12_000_000 }(signed);
        assertEq(tokenB.balanceOf(address(pool)), _pull(990), "landed above the floor");
    }

    /// At a very high limit EIP-150 forwards only 63/64 of the gas left, which
    /// can be less than all-but-the-reserve. The floor is checked against what
    /// the leg actually receives.
    function test_revert_minGasAboveTheEip150Cap() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        // Between 63/64 and all-but-the-reserve of a 40M limit.
        a.minGas = 39_350_000;
        GenericCallWrapper.GenericArgs memory signed = GenericIntent.bind(a);
        vm.expectPartialRevert(GenericCallWrapper.InsufficientGas.selector);
        wrapper.execute{ gas: 40_000_000 }(signed);
    }

    /// With the floor met, a call leg that exhausts its gas reverts rather than
    /// refunds.
    function test_revert_callLegOutOfGas() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _oneCall(_call(address(router), abi.encodeCall(MockRouter.burnGas, ())));
        a.outputs = _oneOutput(_output(ASSET_B, 1));
        GenericCallWrapper.GenericArgs memory signed = GenericIntent.bind(a);
        vm.expectRevert(GenericCallWrapper.CallLegOutOfGas.selector);
        wrapper.execute{ gas: 3_000_000 }(signed);
    }

    // -------- entry guards ----------------------------------------------

    function test_revert_callLeg_notSelf() public {
        GenericCallWrapper.CallLeg memory leg;
        leg.tokenIn = address(tokenA);
        leg.deadline = type(uint256).max;
        vm.expectRevert(GenericCallWrapper.OnlySelf.selector);
        wrapper.callLeg(new CallExecutor.Call[](0), leg);
    }

    function test_revert_executorRun_notWrapper() public {
        CallExecutor impl = CallExecutor(payable(wrapper.EXECUTOR_IMPL()));
        vm.expectRevert(CallExecutor.OnlyWrapper.selector);
        impl.run(new CallExecutor.Call[](0), new address[](0), SURPLUS_TO);
    }

    // -------- denied targets refund -------------------------------------

    function test_refund_targetPool() public {
        _assertTargetDenied(address(pool));
    }

    function test_refund_targetWrapper() public {
        _assertTargetDenied(address(wrapper));
    }

    function test_refund_targetExecutorItself() public {
        _assertTargetDenied(_nextExecutor());
    }

    function test_refund_targetZero() public {
        _assertTargetDenied(address(0));
    }

    /// A payload to an account without code would succeed doing nothing.
    function test_refund_payloadToAccountWithoutCode() public {
        _assertTargetDenied(address(0xC0FFEE));
    }

    function _assertTargetDenied(address target) internal {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _oneCall(_call(target, abi.encodeCall(IERC20.balanceOf, (address(this)))));
        a.outputs = _oneOutput(_output(ASSET_B, 1));
        assertEq(_executeExpectRefund(a), CallExecutor.TargetNotAllowed.selector, "denied");
    }
}
