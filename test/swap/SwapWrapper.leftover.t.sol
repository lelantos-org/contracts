// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { UniV3Adapter } from "../../src/swap/UniV3Adapter.sol";

import { MockSwapRouter02 } from "./mocks/MockSwapRouter02.sol";
import { SwapWrapperUnitBase } from "./SwapWrapperUnitBase.sol";

/// The closing leftover invariant of `SwapWrapper`: a venue that returns input,
/// over-delivers output, under-reports, or partially fills must neither leave
/// a balance on the wrapper or adapter nor bypass the wrapper's own `minOut`.
contract SwapWrapperLeftoverTest is SwapWrapperUnitBase {
    // -------- closing leftover invariant --------------------------------

    /// A venue that returns part of the input leaves `tokenIn` on the wrapper.
    /// Only the closing invariant detects this, preventing a balance the next
    /// swap could spend.
    function test_revert_adapterReturnsInputToken() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        uint256 stray = 5 * SCALE;
        adapter.setRefundIn(stray);

        vm.expectRevert(abi.encodeWithSelector(SwapWrapper.LeftoverBalance.selector, address(tokenA), stray));
        _swap(a);
    }

    /// Mirror case on the output side: a venue that delivers more `tokenOut`
    /// than it reports. The surplus is outside both the MASP pull and the dust
    /// forward, so it would sit on the wrapper unattributed.
    function test_revert_adapterOverDeliversOutputToken() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        uint256 surplus = 3 * SCALE;
        _fundAdapter(surplus); // cover the extra it will send
        adapter.setExtraOut(surplus);

        vm.expectRevert(abi.encodeWithSelector(SwapWrapper.LeftoverBalance.selector, address(tokenB), surplus));
        _swap(a);
    }

    /// The wrapper re-checks `minOut` itself rather than trusting the adapter
    /// to revert. Adapters are owner-allowlisted but still external code.
    function test_refundWhenAdapterUnderReportsBelowMinOut() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        uint256 short_ = a.minOut - 1;
        adapter.setIgnoreMinOut(true);
        adapter.setNextActualOut(short_);

        vm.expectEmit(true, true, false, false, address(wrapper));
        emit SwapWrapper.SwapRefunded(address(adapter), address(tokenA), 0, 0, 0, SwapWrapper.InsufficientOut.selector);
        (uint256 actualOut,) = _swap(a);
        assertEq(actualOut, 0, "nothing swapped");
        assertEq(pool.lastDepositAssetId(), ASSET_A, "A escrowed back");
    }

    /// A real `UniV3Adapter` whose router fills only part of the input reverts
    /// `PartialFill` inside the venue leg, which unwinds the router's pull and
    /// the adapter's receipt, so the whole input is escrowed back as A rather
    /// than left on the adapter where nothing could move it.
    function test_partialFillRefundsInsteadOfStranding() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        MockSwapRouter02 router = new MockSwapRouter02();
        router.setNextOut(a.minOut * 2);
        router.setConsumeBps(5_000);
        a.adapter = address(new UniV3Adapter(address(router), address(wrapper)));
        vm.prank(OWNER);
        wrapper.setAdapterAllowed(a.adapter, true);
        uint256 treasuryBefore = tokenA.balanceOf(TREASURY);
        uint256 refundPull = uint256(a.refund_d.publicIn) * SCALE;
        refundPull += (refundPull * FEE_BPS) / 10_000;

        vm.expectEmit(address(wrapper));
        emit SwapWrapper.SwapRefunded(
            a.adapter, address(tokenA), a.amountIn, a.amountIn - refundPull, 0, UniV3Adapter.PartialFill.selector
        );
        (uint256 actualOut, uint256 depositId) = _swap(a);

        (, uint256 pulled) = wrapper.escrows(depositId);
        assertEq(actualOut, 0, "nothing swapped");
        assertEq(pool.lastDepositAssetId(), ASSET_A, "A escrowed back");
        assertEq(pulled + tokenA.balanceOf(TREASURY) - treasuryBefore, a.amountIn, "all of the unshield accounted for");
        assertEq(tokenA.balanceOf(a.adapter), 0, "nothing stranded on the adapter");
        assertEq(tokenA.balanceOf(address(router)), 0, "router pull unwound");
        assertEq(tokenB.balanceOf(a.adapter), 0, "no output stranded either");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "wrapper keeps no A");
    }
}
