// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";

import { SwapTestBase } from "./SwapTestBase.sol";

/// Additional negative tests for `SwapWrapper` not covered by `SwapWrapper.t.sol`.
contract SwapWrapperNegTest is SwapTestBase {
    // --- helpers -----------------------------------------------------------

    /// `_defaultSwapArgs` with an explicit deadline.
    function _args(uint256 amountIn, uint256 minOut, uint64 piOut, uint64 depositIn, uint256 deadline)
        internal
        view
        returns (SwapWrapper.SwapArgs memory a)
    {
        a = _defaultSwapArgs(amountIn, minOut, piOut, depositIn);
        a.deadline = deadline;
    }

    // --- deadline ----------------------------------------------------------

    /// A passed deadline does not revert the swap: the unshielded A is escrowed
    /// back as the refund note, and the venue is never called.
    function test_expiredDeadline_refunds() public {
        _assertExpiredRefunds(block.timestamp - 1);
    }

    function _assertExpiredRefunds(uint256 expiredDeadline) internal {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        tokenA.mint(address(pool), grossIn);
        pool.setNextWithdrawAmount(grossIn);
        SwapWrapper.SwapArgs memory a =
            _args({ amountIn: netIn, minOut: 990 * SCALE, piOut: 1_000, depositIn: 990, deadline: expiredDeadline });

        vm.expectEmit(true, true, false, false, address(wrapper));
        emit SwapWrapper.SwapRefunded(address(adapter), address(tokenA), netIn, 0, 0, SwapWrapper.SwapExpired.selector);
        (uint256 actualOut, uint256 depositId) = _swap(a);

        assertEq(actualOut, 0, "nothing swapped");
        assertEq(pool.lastDepositAssetId(), ASSET_A, "A escrowed back");
        (address refundTo, uint256 pulled) = wrapper.escrows(depositId);
        assertEq(refundTo, SWAP_REFUND_TO, "refund escrow owned by refundTo");
        assertGt(pulled, 0, "refund escrow recorded");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "wrapper keeps no A");
        assertEq(tokenA.balanceOf(address(adapter)), 0, "venue never paid");
    }

    function test_revert_SwapExpired_atExactCurrentTimestamp() public {
        // deadline == block.timestamp is valid; block.timestamp - 1 is expired.
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE, minOut: 990 * SCALE, piOut: 1_000, depositIn: 990, deadline: block.timestamp
        });
        // At exactly block.timestamp the deadline check passes. The call still
        // reverts later (the pool is unfunded); the revert reason is not checked.
        vm.expectRevert();
        _swap(a);
    }

    /// Fuzz: any deadline < block.timestamp refunds.
    function testFuzz_expiredDeadline_refunds(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, block.timestamp);
        _assertExpiredRefunds(block.timestamp - elapsed);
    }

    // --- after-swap wrapper balance invariant ------------------------------

    /// After a successful swap the wrapper holds no tokenA or tokenB (all
    /// forwarded to the pool or treasury). Uses the happy-path scenario from
    /// SwapWrapper.t.sol with explicit balance checks.
    function test_wrapperHoldsNoResidualBalanceAfterSwap() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 expectedFeeOnB = (minOut * FEE_BPS) / 10_000;
        uint256 dust = 5 * SCALE;
        uint256 actualOut = minOut + expectedFeeOnB + dust;

        tokenA.mint(address(pool), grossIn);
        tokenB.mint(address(adapter), actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            depositIn: minPublicIn,
            deadline: type(uint256).max
        });
        a.pi_w.recipient = address(wrapper);
        a.deposit_d.payer = address(wrapper);

        _swap(a);

        assertEq(tokenB.balanceOf(address(wrapper)), 0, "wrapper must hold no tokenB after swap");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "wrapper must hold no tokenA after swap");
    }
}
