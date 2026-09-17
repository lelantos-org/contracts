// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { GasBurner, NestedGasBurner } from "../mocks/GasBurner.sol";
import { SwapWrapperUnitBase } from "./SwapWrapperUnitBase.sol";
import { SwapIntent } from "./SwapIntent.sol";

/// Unit tests for `SwapWrapper`. Uses a stub MASP and stub adapter so the
/// orchestration logic can be exercised without real Groth16 proofs.
///
/// Covers the happy path and the swap revert and refund paths; admin, the
/// closing leftover invariant and escrow recovery live in the sibling
/// `SwapWrapper.{admin,leftover,escrow}.t.sol` suites.
contract SwapWrapperTest is SwapWrapperUnitBase {
    // -------- happy path -----------------------------------------------

    function test_happyPathForwardsDustToTreasury() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 feeOnA = (grossIn * FEE_BPS) / 10_000;
        uint256 netIn = grossIn - feeOnA; // what MASP.withdraw actually delivers
        uint64 minPublicIn = 990; // minOut = 990 * SCALE
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 expectedFeeOnB = (minOut * FEE_BPS) / 10_000;
        // Venues deliver gross output; the wrapper computes the dust
        // (gross - MASP pull) from its balance delta. Venue output covers
        // MASP's fee-on-publicIn pull plus a 7-unit surplus forwarded to the
        // treasury.
        uint256 expectedDust = 7 * SCALE;
        uint256 actualOut = minOut + expectedFeeOnB + expectedDust;

        _mintToPool(grossIn);
        _fundAdapter(actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            depositIn: minPublicIn,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });

        (uint256 ret, uint256 depositId) = _swap(a);
        assertEq(ret, actualOut, "actualOut mismatch");
        assertEq(depositId, 0, "deposit id");

        assertEq(tokenB.balanceOf(TREASURY), expectedDust, "dust to treasury");
        assertEq(tokenB.balanceOf(address(wrapper)), 0, "wrapper holds no B");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "wrapper holds no A");
        // Wrapper swapped the net receipt; pool kept the withdraw fee and the
        // adapter received exactly the net (not the gross `publicOut*scale`).
        assertEq(tokenA.balanceOf(address(pool)), feeOnA, "pool retained withdraw fee");
        assertEq(tokenA.balanceOf(address(adapter)), netIn, "adapter got net input");
        assertEq(tokenB.balanceOf(address(pool)), minOut + expectedFeeOnB, "pool received minOut + fee");
    }

    /// The wrapper must swap the *measured* receipt from MASP.withdraw, not the
    /// caller-supplied `amountIn` (which is only a floor). Sets the floor below
    /// the net receipt and asserts the full net reached the adapter.
    function test_swapUsesMeasuredReceiptNotAmountIn() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint256 floorIn = netIn - 3 * SCALE; // below the net receipt
        uint64 minPublicIn = 900;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 expectedFeeOnB = (minOut * FEE_BPS) / 10_000;
        uint256 actualOut = minOut + expectedFeeOnB;

        _mintToPool(grossIn);
        _fundAdapter(actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: floorIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            depositIn: minPublicIn,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });

        _swap(a);
        assertEq(tokenA.balanceOf(address(adapter)), netIn, "adapter got full net receipt");
    }

    /// Reverts `InsufficientWithdraw` when MASP delivers less than the floor
    /// (e.g. a fee bump between quote and execution).
    function test_revert_withdrawBelowFloor() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint256 floorIn = netIn + 1; // demand more than MASP will deliver

        _mintToPool(grossIn);
        pool.setNextWithdrawAmount(grossIn);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: floorIn,
            minOut: 900 * SCALE,
            piOut: uint64(grossIn / SCALE),
            depositIn: 900,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });

        vm.expectRevert(abi.encodeWithSelector(SwapWrapper.InsufficientWithdraw.selector, netIn, floorIn));
        _swap(a);
    }

    /// Pre-existing token balances do not block a swap: the leftover invariant
    /// tolerates donations, which remain in the wrapper afterwards.
    function test_donationDoesNotBrickSwap() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 expectedFeeOnB = (minOut * FEE_BPS) / 10_000;
        uint256 expectedDust = 4 * SCALE;
        uint256 actualOut = minOut + expectedFeeOnB + expectedDust;

        _mintToPool(grossIn);
        _fundAdapter(actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        // Donations held by the wrapper before the swap.
        tokenA.mint(address(wrapper), 3);
        tokenB.mint(address(wrapper), 5);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            depositIn: minPublicIn,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });

        _swap(a);

        // Swap succeeded; only the donated dust remains (untouched).
        assertEq(tokenA.balanceOf(address(wrapper)), 3, "tokenA donation preserved");
        assertEq(tokenB.balanceOf(address(wrapper)), 5, "tokenB donation preserved");
        assertEq(tokenB.balanceOf(TREASURY), expectedDust, "dust to treasury");
    }

    // -------- revert paths ---------------------------------------------

    function test_revert_adapterNotAllowed() public {
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE,
            minOut: 990 * SCALE,
            piOut: 1_000,
            depositIn: 990,
            adapter_: address(0xDEAD),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
        vm.expectRevert(SwapWrapper.AdapterNotAllowed.selector);
        _swap(a);
    }

    function test_revert_recipientNotWrapper() public {
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE,
            minOut: 990 * SCALE,
            piOut: 1_000,
            depositIn: 990,
            adapter_: address(adapter),
            recipient: address(0xBAD),
            payer: address(wrapper)
        });
        vm.expectRevert(SwapWrapper.WrapperNotRecipient.selector);
        _swap(a);
    }

    function test_revert_payerNotWrapper() public {
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE,
            minOut: 990 * SCALE,
            piOut: 1_000,
            depositIn: 990,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(0xBAD)
        });
        vm.expectRevert(SwapWrapper.WrapperNotPayer.selector);
        _swap(a);
    }

    /// A `refundTo` of zero or of the wrapper itself would strand a cancelled
    /// escrow, so the swap is refused up front.
    function test_revert_refundToInvalid() public {
        address[2] memory bad = [address(0), address(wrapper)];
        for (uint256 i; i < bad.length; ++i) {
            SwapWrapper.SwapArgs memory a = _args({
                amountIn: 1_000 * SCALE,
                minOut: 990 * SCALE,
                piOut: 1_000,
                depositIn: 990,
                adapter_: address(adapter),
                recipient: address(wrapper),
                payer: address(wrapper)
            });
            a.refundTo = bad[i];
            vm.expectRevert(SwapWrapper.InvalidRefundTo.selector);
            _swap(a);
        }
    }

    function test_revert_zeroAmounts() public {
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 0,
            minOut: 990 * SCALE,
            piOut: 0,
            depositIn: 990,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
        vm.expectRevert(SwapWrapper.AmountInZero.selector);
        _swap(a);

        a.amountIn = 1_000 * SCALE;
        a.minOut = 0;
        vm.expectRevert(SwapWrapper.MinOutZero.selector);
        _swap(a);
    }

    /// A venue that reverts refunds the swap: A goes back into MASP and the
    /// venue's own funds stay put.
    function test_refundWhenAdapterReverts() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        adapter.setNextActualOut(a.minOut - 1); // triggers MockSwapAdapter's own revert
        uint256 venueBefore = tokenB.balanceOf(address(adapter));
        uint256 treasuryBefore = tokenA.balanceOf(TREASURY);

        vm.expectEmit(true, true, false, false, address(wrapper));
        // `Error(string)`, from the mock's `require`.
        emit SwapWrapper.SwapRefunded(address(adapter), address(tokenA), a.amountIn, 0, 0, bytes4(0x08c379a0));
        (uint256 actualOut, uint256 depositId) = _swap(a);

        (, uint256 pulled) = wrapper.escrows(depositId);
        assertEq(actualOut, 0, "nothing swapped");
        assertEq(pool.lastDepositAssetId(), ASSET_A, "A escrowed back");
        assertEq(pulled + tokenA.balanceOf(TREASURY) - treasuryBefore, a.amountIn, "all of the unshield accounted for");
        assertEq(tokenB.balanceOf(address(adapter)), venueBefore, "venue funds untouched");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "wrapper keeps no A");
    }

    /// A venue that runs out of gas reverts the swap rather than refunding it:
    /// more gas might have completed it.
    function test_revert_venueRunsOutOfGas() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        a.adapter = address(new GasBurner());
        vm.prank(OWNER);
        wrapper.setAdapterAllowed(a.adapter, true);

        vm.expectRevert(SwapWrapper.VenueOutOfGas.selector);
        this.swapWithGas(a, 3_000_000);
    }

    /// An out-of-gas several frames below the adapter still reverts rather than
    /// refunds. Four forwarding frames in front of the burner, plus `venueLeg`
    /// itself, each keep back 1/64 of their gas, so about 7.6% of the budget
    /// comes back unspent and the innermost failure surfaces as
    /// `InnerCallFailed`, not as an out-of-gas. A 1/32 slack read that as a
    /// market failure and refunded, letting the driver force a refund through
    /// its choice of gas limit.
    function test_deepOutOfGasRevertsInsteadOfRefunding() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        address next = address(new GasBurner());
        for (uint256 i; i < 4; ++i) {
            next = address(new NestedGasBurner(next));
        }
        a.adapter = next;
        vm.prank(OWNER);
        wrapper.setAdapterAllowed(a.adapter, true);

        vm.expectRevert(SwapWrapper.VenueOutOfGas.selector);
        this.swapWithGas(a, 3_000_000);
    }

    function swapWithGas(SwapWrapper.SwapArgs memory a, uint256 gasLimit) external {
        wrapper.swap{ gas: gasLimit }(SwapIntent.bind(a));
    }

    /// Only the wrapper may run the venue leg.
    function test_revert_venueLegFromOutside() public {
        vm.expectRevert(SwapWrapper.OnlySelf.selector);
        wrapper.venueLeg(address(tokenA), address(tokenB), address(adapter), 1, 1, type(uint256).max, "");
    }

    /// A refund escrow is recoverable like any other.
    function test_cancelRefundEscrowRefundsRefundTo() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        a.deadline = block.timestamp - 1;
        (, uint256 depositId) = _swap(a);
        (, uint256 pulled) = wrapper.escrows(depositId);

        uint256 refundBefore = tokenA.balanceOf(SWAP_REFUND_TO);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit SwapWrapper.EscrowRefunded(depositId, SWAP_REFUND_TO, address(tokenA), pulled);
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_A,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );

        assertEq(tokenA.balanceOf(SWAP_REFUND_TO) - refundBefore, pulled, "refund reached refundTo");
    }

    /// The MASP fee can push the pulled total above what the venue delivered,
    /// leaving the wrapper short of `dust` to forward. The explicit guard
    /// rejects this. Pre-mints exactly `fee` extra B to the wrapper so the
    /// Permit2 pull does not run out of balance, isolating the wrapper-level
    /// invariant `pulled <= actualOut`.
    function test_revert_maspPullExceedsActualOut() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 expectedFeeOnB = (minOut * FEE_BPS) / 10_000;
        // Venue delivered exactly minOut.
        uint256 actualOut = minOut;

        _mintToPool(grossIn);
        _fundAdapter(actualOut);
        // Give Permit2 the balance to satisfy `minOut + fee` so the wrapper
        // guard is exercised rather than a Permit2 underflow.
        tokenB.mint(address(wrapper), expectedFeeOnB);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            depositIn: minPublicIn,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
        vm.expectRevert(
            abi.encodeWithSelector(MaspEscrowSatellite.PullExceedsMax.selector, minOut + expectedFeeOnB, actualOut)
        );
        _swap(a);
    }
}
