// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { CallExecutor } from "../../src/generic/CallExecutor.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { FeeMath } from "../utils/FeeMath.sol";
import { WrapperTestBase } from "../utils/WrapperTestBase.sol";
import { MockRouter } from "./mocks/MockCallTargets.sol";
import { GenericIntent } from "./GenericIntent.sol";

/// Deployment and payload scaffolding shared by the `GenericCallWrapper` suites.
///
/// `WrapperTestBase` deploys the stub pool, Permit2 and tokens A and B; this
/// adds C, WETH, the wrapper and a router, all four assets armed.
///
/// Every execution withdraws `WITHDRAW_UNITS` of asset A. The stub pool pushes
/// that net of its fee (`_received`) and pulls `publicIn * SCALE` plus fee for
/// each deposit (`_pull`).
abstract contract GenericCallTestBase is WrapperTestBase {
    uint64 internal constant ASSET_C = 3;
    uint64 internal constant ASSET_W = 4;
    uint64 internal constant WITHDRAW_UNITS = 1_000;
    address internal constant REFUND_TO = TestConstants.SWAP_REFUND_TO;
    address internal constant SURPLUS_TO = address(0x5A5A);

    MockERC20 internal tokenC;
    MockWETH9 internal weth;
    GenericCallWrapper internal wrapper;
    MockRouter internal router;

    function _deployExtraTokens() internal override {
        tokenC = new MockERC20("Token C", "TKC", 18);
        weth = new MockWETH9();
    }

    function _assets() internal view override returns (uint64[] memory ids, address[] memory tokens) {
        ids = new uint64[](4);
        tokens = new address[](4);
        (ids[0], tokens[0]) = (ASSET_A, address(tokenA));
        (ids[1], tokens[1]) = (ASSET_B, address(tokenB));
        (ids[2], tokens[2]) = (ASSET_C, address(tokenC));
        (ids[3], tokens[3]) = (ASSET_W, address(weth));
    }

    function _deployWrapper() internal override {
        wrapper = new GenericCallWrapper(pool, permit2);
        router = new MockRouter();
    }

    function _wrapperAddress() internal view override returns (address) {
        return address(wrapper);
    }

    // =====================================================================
    // Amounts
    // =====================================================================

    function _gross() internal pure returns (uint256) {
        return uint256(WITHDRAW_UNITS) * SCALE;
    }

    /// What the stub withdraw delivers: gross net of the unshield fee.
    function _received() internal pure returns (uint256) {
        return _netOfFee(_gross());
    }

    /// What the stub pool pulls for a deposit of `publicIn` units.
    function _pull(uint64 publicIn) internal pure returns (uint256) {
        return FeeMath.gross(publicIn, SCALE, FEE_BPS);
    }

    /// The largest refund note whose pull fits what the withdraw nets: the
    /// `publicIn` of `_base`'s `refund_d`.
    function _refundUnits() internal pure returns (uint64) {
        return _netOfTwoFees(WITHDRAW_UNITS);
    }

    // =====================================================================
    // Payloads
    // =====================================================================

    /// A payload withdrawing A, with a valid refund and no calls or outputs.
    function _base() internal view returns (GenericCallWrapper.GenericArgs memory a) {
        a.amountIn = _received();
        a.deadline = type(uint256).max;
        a.refundTo = REFUND_TO;
        a.surplusTo = SURPLUS_TO;
        a.pi_w.publicAssetId = ASSET_A;
        a.pi_w.publicOut = WITHDRAW_UNITS;
        a.pi_w.recipient = address(wrapper);
        a.pi_w.relayer = address(wrapper);
        // The test contract drives every execution.
        a.pi_w.payer = address(this);
        a.refund_d = _refundRequest(WITHDRAW_UNITS);
        a.calls = new CallExecutor.Call[](0);
        a.outputs = new GenericCallWrapper.Output[](0);
    }

    /// Swaps everything received for `amountOut` of B, into one note of `publicIn` units.
    function _swapArgs(uint64 publicIn, uint256 amountOut)
        internal
        view
        returns (GenericCallWrapper.GenericArgs memory a)
    {
        a = _base();
        a.calls = _swapCalls(address(tokenB), _received(), amountOut);
        a.outputs = _oneOutput(_output(ASSET_B, publicIn));
    }

    /// An output note of `publicIn` units of `assetId`, paid by the wrapper.
    function _request(uint64 assetId, uint64 publicIn) internal view returns (PubInputs.DepositRequest memory) {
        return _noteRequest(assetId, publicIn, address(wrapper));
    }

    /// An output note of `publicIn` units, floored at their unscaled value.
    function _output(uint64 assetId, uint64 publicIn) internal view returns (GenericCallWrapper.Output memory o) {
        o.minOut = uint256(publicIn) * SCALE;
        o.deposit = _request(assetId, publicIn);
    }

    function _oneOutput(GenericCallWrapper.Output memory o)
        internal
        pure
        returns (GenericCallWrapper.Output[] memory outputs)
    {
        outputs = new GenericCallWrapper.Output[](1);
        outputs[0] = o;
    }

    function _twoOutputs(GenericCallWrapper.Output memory first, GenericCallWrapper.Output memory second)
        internal
        pure
        returns (GenericCallWrapper.Output[] memory outputs)
    {
        outputs = new GenericCallWrapper.Output[](2);
        outputs[0] = first;
        outputs[1] = second;
    }

    // =====================================================================
    // Calls
    // =====================================================================

    function _call(address target, bytes memory data) internal pure returns (CallExecutor.Call memory) {
        return CallExecutor.Call({ target: target, value: 0, data: data });
    }

    function _oneCall(CallExecutor.Call memory c) internal pure returns (CallExecutor.Call[] memory calls) {
        calls = new CallExecutor.Call[](1);
        calls[0] = c;
    }

    function _twoCalls(CallExecutor.Call memory first, CallExecutor.Call memory second)
        internal
        pure
        returns (CallExecutor.Call[] memory calls)
    {
        calls = new CallExecutor.Call[](2);
        calls[0] = first;
        calls[1] = second;
    }

    /// `calls` with `extra` appended.
    function _append(CallExecutor.Call[] memory calls, CallExecutor.Call memory extra)
        internal
        pure
        returns (CallExecutor.Call[] memory out)
    {
        out = new CallExecutor.Call[](calls.length + 1);
        for (uint256 i; i < calls.length; ++i) {
            out[i] = calls[i];
        }
        out[calls.length] = extra;
    }

    function _approveRouter(uint256 amount) internal view returns (CallExecutor.Call memory) {
        return _call(address(tokenA), abi.encodeCall(IERC20.approve, (address(router), amount)));
    }

    /// Approve the router, then swap `amountIn` of A for `amountOut` of `tokenOut`.
    function _swapCalls(address tokenOut, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (CallExecutor.Call[] memory)
    {
        return _twoCalls(
            _approveRouter(amountIn),
            _call(address(router), abi.encodeCall(MockRouter.swap, (address(tokenA), tokenOut, amountIn, amountOut)))
        );
    }

    /// Approve the router, then split `amountIn` of A into `bOut` of B and `cOut` of C.
    function _splitCalls(uint256 amountIn, uint256 bOut, uint256 cOut)
        internal
        view
        returns (CallExecutor.Call[] memory)
    {
        return _twoCalls(
            _approveRouter(amountIn),
            _call(
                address(router),
                abi.encodeCall(
                    MockRouter.split, (address(tokenA), amountIn, address(tokenB), bOut, address(tokenC), cOut)
                )
            )
        );
    }

    // =====================================================================
    // Driving
    // =====================================================================

    /// Funds the stub pool for one withdraw of A.
    function _fundWithdraw() internal {
        tokenA.mint(address(pool), _gross());
        pool.setNextWithdrawAmount(_gross());
    }

    /// Binds `a` to its own intent, as an honest wallet would, and executes.
    /// Internal until the wrapper call, so a pending `vm.expectRevert` applies
    /// to `execute` itself.
    function _execute(GenericCallWrapper.GenericArgs memory a) internal returns (uint256[] memory) {
        return wrapper.execute(GenericIntent.bind(a));
    }

    /// Executes and asserts it refunded the input as a note of A, returning the
    /// failure's selector.
    function _executeExpectRefund(GenericCallWrapper.GenericArgs memory a) internal returns (bytes4 reason) {
        vm.recordLogs();
        _execute(a);
        reason = _refundReason(vm.getRecordedLogs());
        assertEq(pool.lastDepositAssetId(), ASSET_A, "refund escrowed in A");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "no A left on the wrapper");
    }

    /// The address the next clone will be created at.
    function _nextExecutor() internal view returns (address) {
        return vm.computeCreateAddress(address(wrapper), vm.getNonce(address(wrapper)));
    }

    // =====================================================================
    // Logs
    // =====================================================================

    /// The `reason` of the `CallsRefunded` event in `logs`.
    function _refundReason(Vm.Log[] memory logs) internal view returns (bytes4 reason) {
        Vm.Log memory log = _findLog(logs, GenericCallWrapper.CallsRefunded.selector);
        (,,, reason) = abi.decode(log.data, (uint256, uint256, uint256, bytes4));
    }

    /// The executor named by the `CallsExecuted` event in `logs`.
    function _executorOf(Vm.Log[] memory logs) internal view returns (address) {
        Vm.Log memory log = _findLog(logs, GenericCallWrapper.CallsExecuted.selector);
        return address(uint160(uint256(log.topics[1])));
    }

    function _findLog(Vm.Log[] memory logs, bytes32 topic) internal view returns (Vm.Log memory) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(wrapper) && logs[i].topics[0] == topic) return logs[i];
        }
        revert("event not emitted");
    }
}
