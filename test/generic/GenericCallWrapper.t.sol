// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { CallExecutor } from "../../src/generic/CallExecutor.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";

import { GenericCallTestBase } from "./GenericCallTestBase.sol";
import { GenericIntent } from "./GenericIntent.sol";
import { MockRouter } from "./mocks/MockCallTargets.sol";

/// `GenericCallWrapper` orchestration against the stub pool: outputs, surplus
/// routing, refunds and escrow recovery.
contract GenericCallWrapperTest is GenericCallTestBase {
    // =====================================================================
    // Landed executions
    // =====================================================================

    function test_singleOutput_escrowsAndForwardsSurplus() public {
        uint64 units = 990;
        uint256 cushion = 7 * SCALE;
        _fundWithdraw();

        vm.recordLogs();
        uint256[] memory ids = _execute(_swapArgs(units, _pull(units) + cushion));
        address executor = _executorOf(vm.getRecordedLogs());

        assertEq(ids.length, 1, "one escrow");
        assertEq(tokenB.balanceOf(address(pool)), _pull(units), "pool pulled the note");
        assertEq(tokenB.balanceOf(SURPLUS_TO), cushion, "cushion to surplusTo");
        assertEq(pool.lastDepositRecipient(), NOTE_RECIPIENT, "note recipient");

        (address refundTo, uint256 amount) = wrapper.escrows(ids[0]);
        assertEq(refundTo, REFUND_TO, "escrow owner");
        assertEq(amount, _pull(units), "escrow amount");

        _assertEmpty(address(wrapper));
        _assertEmpty(executor);
        assertGt(executor.code.length, 0, "clone deployed");
    }

    /// A liquidity-removal shape: one input, two outputs in different tokens.
    function test_twoOutputs_eachEscrowed() public {
        uint64 unitsB = 400;
        uint64 unitsC = 500;
        _fundWithdraw();

        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _splitCalls(_received(), _pull(unitsB), _pull(unitsC) + 1);
        a.outputs = _twoOutputs(_output(ASSET_B, unitsB), _output(ASSET_C, unitsC));
        uint256[] memory ids = _execute(a);

        assertEq(ids.length, 2, "two escrows");
        assertEq(tokenB.balanceOf(address(pool)), _pull(unitsB), "B note");
        assertEq(tokenC.balanceOf(address(pool)), _pull(unitsC), "C note");
        assertEq(tokenC.balanceOf(SURPLUS_TO), 1, "C cushion");
        (, uint256 amountB) = wrapper.escrows(ids[0]);
        (, uint256 amountC) = wrapper.escrows(ids[1]);
        assertEq(amountB, _pull(unitsB), "B record");
        assertEq(amountC, _pull(unitsC), "C record");
    }

    /// The maximum of four outputs, with the unspent half of the input among them.
    function test_fourOutputs_includingInput() public {
        _fundWithdraw();
        uint256 half = _received() / 2;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 unitsA = uint64(half / SCALE) - 10;

        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _append(
            _splitCalls(half, _pull(10), _pull(20)),
            _call(address(router), abi.encodeCall(MockRouter.swap, (address(tokenA), address(weth), 0, _pull(30))))
        );
        a.outputs = new GenericCallWrapper.Output[](4);
        a.outputs[0] = _output(ASSET_B, 10);
        a.outputs[1] = _output(ASSET_C, 20);
        a.outputs[2] = _output(ASSET_W, 30);
        a.outputs[3] = _output(ASSET_A, unitsA);

        uint256[] memory ids = _execute(a);

        assertEq(ids.length, 4, "four escrows");
        assertEq(tokenA.balanceOf(address(pool)), _gross() - _received() + _pull(unitsA), "A note");
        assertEq(tokenA.balanceOf(SURPLUS_TO), _received() - half - _pull(unitsA), "A cushion");
        _assertEmpty(address(wrapper));
    }

    /// Input the calls leave unspent, when A is not an output, goes to `surplusTo`.
    function test_unusedInput_toSurplus() public {
        uint64 units = 100;
        uint256 used = _received() / 4;
        _fundWithdraw();

        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _swapCalls(address(tokenB), used, _pull(units));
        a.outputs = _oneOutput(_output(ASSET_B, units));
        _execute(a);

        assertEq(tokenA.balanceOf(SURPLUS_TO), _received() - used, "unused input");
        _assertEmpty(address(wrapper));
    }

    /// Unwrap to native and re-wrap, with the native leftover swept to `surplusTo`.
    function test_nativeRoundTrip_leftoverToSurplus() public {
        uint256 received = _fundWrappedNativeWithdraw();
        uint256 leftover = 3 * SCALE;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 units = uint64((received - leftover) / SCALE) - 10;

        GenericCallWrapper.GenericArgs memory a = _wrappedNativeBase();
        a.calls = _twoCalls(
            _call(address(weth), abi.encodeCall(IWrappedNative.withdraw, (received))),
            CallExecutor.Call({
                target: address(weth), value: received - leftover, data: abi.encodeCall(IWrappedNative.deposit, ())
            })
        );
        a.outputs = _oneOutput(_output(ASSET_W, units));
        _execute(a);

        assertEq(SURPLUS_TO.balance, leftover, "native leftover");
        assertEq(weth.balanceOf(address(pool)), _gross() - received + _pull(units), "W note");
    }

    /// A call with no payload is a plain transfer, allowed to an account without code.
    function test_plainNativeSend_toAccountWithoutCode() public {
        _fundWrappedNativeWithdraw();
        address payee = address(0xCAFE);

        GenericCallWrapper.GenericArgs memory a = _wrappedNativeBase();
        a.calls = _twoCalls(
            _call(address(weth), abi.encodeCall(IWrappedNative.withdraw, (SCALE))),
            CallExecutor.Call({ target: payee, value: SCALE, data: "" })
        );
        a.outputs = _oneOutput(_output(ASSET_W, 900));
        _execute(a);

        assertEq(payee.balance, SCALE, "paid");
    }

    function test_freshExecutorPerExecution() public {
        _fundWithdraw();
        vm.recordLogs();
        _execute(_swapArgs(990, _pull(990)));
        address first = _executorOf(vm.getRecordedLogs());

        _fundWithdraw();
        vm.recordLogs();
        _execute(_swapArgs(990, _pull(990)));
        address second = _executorOf(vm.getRecordedLogs());

        assertTrue(first != second, "new clone");
        assertEq(CallExecutor(payable(second)).WRAPPER(), address(wrapper), "clone carries the wrapper");
    }

    /// The on-chain helper wallets can call agrees with the independent test-side hash.
    function test_intentHash_matchesIndependentImplementation() public view {
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.minGas = 123_456;
        a.deadline = 42;
        assertEq(wrapper.intentHash(a), GenericIntent.hash(a), "intent hash");
    }

    // =====================================================================
    // Refunds
    // =====================================================================

    function test_refund_onFailingCall() public {
        _fundWithdraw();
        address next = _nextExecutor();
        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _oneCall(_call(address(router), abi.encodeCall(MockRouter.fail, ())));
        a.outputs = _oneOutput(_output(ASSET_B, 1));

        bytes4 reason = _executeExpectRefund(a);

        assertEq(reason, MockRouter.RouterFailed.selector, "re-raised reason");
        assertEq(tokenA.balanceOf(address(pool)), _gross() - _received() + _pull(_refundUnits()), "A refund note");
        assertEq(tokenA.balanceOf(SURPLUS_TO), _received() - _pull(_refundUnits()), "refund surplus");
        assertEq(next.code.length, 0, "clone rolled back");
        (address refundTo,) = wrapper.escrows(0);
        assertEq(refundTo, REFUND_TO, "refund escrow owner");
    }

    function test_refund_onShortfall() public {
        _fundWithdraw();
        bytes4 reason = _executeExpectRefund(_swapArgs(990, _pull(990) / 2));
        assertEq(reason, GenericCallWrapper.InsufficientOut.selector, "shortfall");
        _assertEmpty(address(wrapper));
    }

    function test_refund_afterDeadline() public {
        _fundWithdraw();
        vm.warp(1_000);
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.deadline = 999;
        assertEq(_executeExpectRefund(a), GenericCallWrapper.Expired.selector, "expired");
    }

    function test_refund_silentRevert_reportsCallFailed() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _oneCall(_call(address(router), abi.encodeCall(MockRouter.silent, ())));
        a.outputs = _oneOutput(_output(ASSET_B, 1));
        assertEq(_executeExpectRefund(a), CallExecutor.CallFailed.selector, "empty payload");
    }

    function test_refund_returndataBomb_reportsCallFailed() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _oneCall(_call(address(router), abi.encodeCall(MockRouter.bomb, ())));
        a.outputs = _oneOutput(_output(ASSET_B, 1));
        assertEq(_executeExpectRefund(a), CallExecutor.CallFailed.selector, "oversized payload replaced");
    }

    // =====================================================================
    // Escrow recovery
    // =====================================================================

    function test_cancelEscrow_refundsOneOutputToRefundTo() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _splitCalls(_received(), _pull(40), _pull(50));
        a.outputs = _twoOutputs(_output(ASSET_B, 40), _output(ASSET_C, 50));
        uint256[] memory ids = _execute(a);

        PubInputs.FeeNote memory feeNote;
        vm.prank(address(0xD00D));
        wrapper.cancelEscrow(ids[1], 50, bytes32(0), [uint256(0), 0], ASSET_C, 0, 0, feeNote);

        assertEq(tokenC.balanceOf(REFUND_TO), _pull(50), "C refunded to refundTo");
        assertEq(tokenB.balanceOf(REFUND_TO), 0, "B escrow untouched");
        (address cleared,) = wrapper.escrows(ids[1]);
        assertEq(cleared, address(0), "record cleared");
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _assertEmpty(address who) internal view {
        assertEq(tokenA.balanceOf(who), 0, "no A left");
        assertEq(tokenB.balanceOf(who), 0, "no B left");
        assertEq(tokenC.balanceOf(who), 0, "no C left");
    }

    /// Funds the stub pool for a withdraw of wrapped native, backed by real
    /// native coin so it can be unwrapped. Returns the net received.
    function _fundWrappedNativeWithdraw() internal returns (uint256) {
        weth.mint(address(pool), _gross());
        vm.deal(address(weth), _gross());
        pool.setNextWithdrawAmount(_gross());
        return _received();
    }

    function _wrappedNativeBase() internal view returns (GenericCallWrapper.GenericArgs memory a) {
        a = _base();
        a.pi_w.publicAssetId = ASSET_W;
        a.refund_d.publicAssetId = ASSET_W;
    }
}
