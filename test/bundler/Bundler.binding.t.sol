// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { Bundler } from "../../src/bundler/Bundler.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { SwapIntent } from "../swap/SwapIntent.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { BundlerTestBase } from "./BundlerTestBase.sol";

/// `Bundler.execute` submitter binding: spends and swaps bound to one Bundler
/// fail through another, and an operator cannot rewrite a bound swap. Fixture
/// and call builders in `BundlerTestBase`.
contract BundlerBindingTest is BundlerTestBase {
    // --- submitter binding across Bundlers ---------------------------------

    function test_spendBoundToAnotherBundler_fails() public {
        Bundler other = _createBundler(OTHER_OWNER);

        Bundler.Call[] memory calls = new Bundler.Call[](1);
        // Bound to `bundler`, submitted through `other`.
        calls[0] = _transferCall(bundler, 0x100, _root(1), masp.committedCount());

        vm.prank(OPERATOR);
        (uint256 executed, bytes memory reason) = other.execute(calls);

        assertEq(executed, 0, "rejected");
        assertEq(reason, abi.encodeWithSelector(MASP.BadRelayer.selector), "pool binding holds");
    }

    function test_swapBoundToAnotherBundler_fails() public {
        Bundler other = _createBundler(OTHER_OWNER);

        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = _swapCall(bundler, 0x400, _root(1), masp.committedCount());

        vm.prank(OPERATOR);
        (uint256 executed, bytes memory reason) = other.execute(calls);

        assertEq(executed, 0, "rejected");
        assertEq(
            reason,
            abi.encodeWithSelector(SwapWrapper.UnauthorizedSwapCaller.selector, address(other), address(bundler)),
            "wrapper binding holds"
        );
    }

    /// A swap whose venue leg fails still lands, as a refund, so the items
    /// behind it land too.
    function test_execute_refundedSwap_doesNotStopTheBundle() public {
        uint64 start = masp.committedCount();
        SwapWrapper.SwapArgs memory a = _swapArgs(bundler, 0x400, _root(1), start);
        a.deadline = block.timestamp - 1;
        Bundler.Call[] memory calls = new Bundler.Call[](2);
        calls[0] = _wrapperCall(SwapIntent.bind(a));
        calls[1] = _transferCall(bundler, 0x100, _root(2), start + 6);

        vm.expectEmit(true, true, false, false, address(wrapper));
        emit SwapWrapper.SwapRefunded(address(swapAdapter), address(tokenA), 0, 0, 0, SwapWrapper.SwapExpired.selector);
        vm.prank(OPERATOR);
        (uint256 executed,) = bundler.execute(calls);

        assertEq(executed, 2, "both landed");
        assertEq(masp.committedCount(), start + 12, "tree advanced past both");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "nothing stranded in the wrapper");
    }

    /// A bundled swap names the Bundler as `pi_w.payer`. A cancelled output
    /// escrow refunds the intent-bound `refundTo`, not the Bundler, which cannot
    /// move tokens out.
    function test_swapEscrowCancel_refundsRefundTo_notBundler() public {
        uint256 depositId = masp.nextDepositId();
        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = _swapCall(bundler, 0x400, _root(1), masp.committedCount());
        // `vm.getBlockNumber`, not `block.number`: via-IR may re-read the latter
        // after the `vm.roll` below.
        uint32 submittedAt = uint32(vm.getBlockNumber());

        vm.prank(OPERATOR);
        (uint256 executed,) = bundler.execute(calls);
        assertEq(executed, 1, "swap landed");

        (address refundTo, uint256 amount) = wrapper.escrows(depositId);
        assertEq(refundTo, SWAP_REFUND_TO, "escrow owned by refundTo");
        assertGt(amount, 0, "escrow recorded");

        vm.roll(uint256(submittedAt) + masp.cancelDelay());
        wrapper.cancelEscrow(
            depositId,
            990,
            bytes32(uint256(0x400) + 0x100),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: FEE_CM, feeCvDep: [uint256(0), 0] })
        );

        assertEq(tokenB.balanceOf(SWAP_REFUND_TO), amount, "refund reached refundTo");
        assertEq(tokenB.balanceOf(address(bundler)), 0, "nothing stranded in the Bundler");
        assertEq(tokenB.balanceOf(address(wrapper)), 0, "nothing stranded in the wrapper");
    }

    /// A Bundler operator submits as the swap's `payer` but cannot rewrite the
    /// swap's intent. Substituting its own output note and a floor of 1 into a
    /// user's bound payload fails the item instead of redirecting the proceeds.
    function test_operatorCannotRedirectSwapOutput() public {
        uint256 depositId = masp.nextDepositId();
        SwapWrapper.SwapArgs memory a = SwapIntent.bind(_swapArgs(bundler, 0x400, _root(1), masp.committedCount()));
        a.deposit_d.recipient = OPERATOR;
        a.deposit_d.outCm = bytes32(uint256(0x0BAD));
        a.minOut = 1;
        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = _wrapperCall(a);

        vm.prank(OPERATOR);
        (uint256 executed, bytes memory reason) = bundler.execute(calls);

        assertEq(executed, 0, "tampered swap rejected");
        assertEq(reason, abi.encodeWithSelector(SwapWrapper.IntentMismatch.selector), "intent binding holds");
        assertEq(masp.escrowed(depositId), bytes32(0), "nothing escrowed");
    }
}
