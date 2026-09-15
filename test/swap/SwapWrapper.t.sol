// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { UniV3Adapter } from "../../src/swap/UniV3Adapter.sol";

import { GasBurner, NestedGasBurner } from "../mocks/GasBurner.sol";
import { MockSwapRouter02 } from "./mocks/MockSwapRouter02.sol";
import { SwapTestBase } from "./SwapTestBase.sol";
import { SwapIntent } from "./SwapIntent.sol";

/// Unit tests for `SwapWrapper`. Uses a stub MASP and stub adapter so the
/// orchestration logic can be exercised without real Groth16 proofs.
contract SwapWrapperTest is SwapTestBase {
    // -------- helpers ---------------------------------------------------

    function _mintToPool(uint256 amt) internal {
        tokenA.mint(address(pool), amt);
    }

    function _fundAdapter(uint256 amt) internal {
        tokenB.mint(address(adapter), amt);
    }

    function _args(
        uint256 amountIn,
        uint256 minOut,
        uint64 piOut,
        uint64 depositIn,
        address adapter_,
        address recipient,
        address payer
    ) internal view returns (SwapWrapper.SwapArgs memory a) {
        a.p_w = _emptyProof();
        a.tp_w = _emptyProof();
        a.pi_w = _piWithdraw(piOut, recipient);
        a.tpi_w = _emptyTpi();
        a.aux_w = _emptyAux();
        a.deposit_d = _request(depositIn, payer);
        a.aux_d = _emptyAux()[0];
        a.refund_d = _refundRequest(piOut);
        a.adapter = adapter_;
        a.route = abi.encode(uint24(500), uint160(0));
        a.deadline = type(uint256).max;
        // Distinct from the driver, so a refund that follows `payer` fails the
        // escrow-recovery tests.
        a.refundTo = SWAP_REFUND_TO;
        a.tokenIn = address(tokenA);
        a.tokenOut = address(tokenB);
        a.amountIn = amountIn;
        a.minOut = minOut;
    }

    // -------- happy path -----------------------------------------------

    function testHappyPathForwardsDustToTreasury() public {
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
    function testSwapUsesMeasuredReceiptNotAmountIn() public {
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
    function testRevertWhenWithdrawBelowFloor() public {
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
    function testDonationDoesNotBrickSwap() public {
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

    function testRevertWhenAdapterNotAllowed() public {
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

    function testRevertWhenRecipientNotWrapper() public {
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

    function testRevertWhenPayerNotWrapper() public {
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
    function testRevertWhenRefundToInvalid() public {
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

    function testRevertWhenZeroAmounts() public {
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
    function testRefundWhenAdapterReverts() public {
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
    function testRevertWhenVenueRunsOutOfGas() public {
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
    function testDeepOutOfGasRevertsInsteadOfRefunding() public {
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
    function testRevertVenueLegFromOutside() public {
        vm.expectRevert(SwapWrapper.OnlySelf.selector);
        wrapper.venueLeg(address(tokenA), address(tokenB), address(adapter), 1, 1, type(uint256).max, "");
    }

    /// A refund escrow is recoverable like any other.
    function testCancelRefundEscrowRefundsRefundTo() public {
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
    function testRevertWhenMaspPullExceedsActualOut() public {
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

    // -------- admin -----------------------------------------------------

    function testOnlyOwnerCanAllowAdapter() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        wrapper.setAdapterAllowed(address(adapter), false);
    }

    function testOwnerCanFlipAllowlist() public {
        assertTrue(wrapper.adapterAllowed(address(adapter)));
        vm.prank(OWNER);
        wrapper.setAdapterAllowed(address(adapter), false);
        assertFalse(wrapper.adapterAllowed(address(adapter)));
    }

    function testRevertWhenSameToken() public {
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE,
            minOut: 990 * SCALE,
            piOut: 1_000,
            depositIn: 990,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
        a.tokenOut = a.tokenIn;
        vm.expectRevert(SwapWrapper.SameToken.selector);
        _swap(a);
    }

    function testConstructorRejectsZeroPool() public {
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        new SwapWrapper(IMASPPool(address(0)), permit2, OWNER, TREASURY);
    }

    function testConstructorRejectsZeroPermit2() public {
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        new SwapWrapper(pool, IAllowanceTransfer(address(0)), OWNER, TREASURY);
    }

    function testConstructorRejectsZeroTreasury() public {
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        new SwapWrapper(pool, permit2, OWNER, address(0));
    }

    function testSetTreasuryRejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        wrapper.setTreasury(address(0));
    }

    function testSetAdapterAllowedRejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        wrapper.setAdapterAllowed(address(0), true);
    }

    function testPrepareTokenSetsBothAllowances() public {
        // tokenA has no Permit2 allowance until prepareToken runs.
        wrapper.prepareToken(IERC20(address(tokenA)));
        assertEq(tokenA.allowance(address(wrapper), address(permit2)), type(uint256).max);
        (uint160 cap,,) = permit2.allowance(address(wrapper), address(tokenA), address(pool));
        assertEq(cap, type(uint160).max, "permit2 to pool allowance");
    }

    function testSetTreasuryUpdatesDestination() public {
        address newTreasury = address(0xDEAD5E7);
        vm.expectEmit(true, true, true, true, address(wrapper));
        emit SwapWrapper.TreasurySet(newTreasury);
        vm.prank(OWNER);
        wrapper.setTreasury(newTreasury);
        assertEq(wrapper.treasury(), newTreasury, "treasury updated");
    }

    function testOnlyOwnerCanSetTreasury() public {
        vm.expectRevert();
        wrapper.setTreasury(address(0xDEAD5E7));
    }

    // -------- closing leftover invariant --------------------------------

    /// Sets up the happy path, then lets the caller perturb the adapter. All
    /// amounts mirror `testHappyPathForwardsDustToTreasury`.
    function _armSwap() internal returns (SwapWrapper.SwapArgs memory a, uint256 actualOut) {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        actualOut = minOut + (minOut * FEE_BPS) / 10_000 + 7 * SCALE;

        _mintToPool(grossIn);
        _fundAdapter(actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            depositIn: minPublicIn,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
    }

    /// A venue that returns part of the input leaves `tokenIn` on the wrapper.
    /// Only the closing invariant detects this, preventing a balance the next
    /// swap could spend.
    function testRevertWhenAdapterReturnsInputToken() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        uint256 stray = 5 * SCALE;
        adapter.setRefundIn(stray);

        vm.expectRevert(abi.encodeWithSelector(SwapWrapper.LeftoverBalance.selector, address(tokenA), stray));
        _swap(a);
    }

    /// Mirror case on the output side: a venue that delivers more `tokenOut`
    /// than it reports. The surplus is outside both the MASP pull and the dust
    /// forward, so it would sit on the wrapper unattributed.
    function testRevertWhenAdapterOverDeliversOutputToken() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        uint256 surplus = 3 * SCALE;
        _fundAdapter(surplus); // cover the extra it will send
        adapter.setExtraOut(surplus);

        vm.expectRevert(abi.encodeWithSelector(SwapWrapper.LeftoverBalance.selector, address(tokenB), surplus));
        _swap(a);
    }

    /// The wrapper re-checks `minOut` itself rather than trusting the adapter
    /// to revert. Adapters are owner-allowlisted but still external code.
    function testRefundWhenAdapterUnderReportsBelowMinOut() public {
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
    function testPartialFillRefundsInsteadOfStranding() public {
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

    // -------- escrow recovery -------------------------------------------

    /// Run the happy path and return the escrow it created.
    function _swapAndEscrow() internal returns (uint256 depositId, uint256 pulled) {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        (, depositId) = _swap(a);
        (, pulled) = wrapper.escrows(depositId);
    }

    /// An escrow that never gets flushed is refunded to the intent-bound
    /// `refundTo`, not the address that drove the swap. Without this path the
    /// coin is unreachable: MASP pays the digest-bound payer, which is the
    /// wrapper, and only the wrapper may cancel its own deposit.
    function testCancelEscrowRefundsRefundTo() public {
        (uint256 depositId, uint256 pulled) = _swapAndEscrow();
        uint256 driverBefore = tokenB.balanceOf(address(this));
        assertGt(pulled, 0, "escrow recorded");
        uint256 refundBefore = tokenB.balanceOf(SWAP_REFUND_TO);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit SwapWrapper.EscrowRefunded(depositId, SWAP_REFUND_TO, address(tokenB), pulled);
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );

        assertEq(tokenB.balanceOf(SWAP_REFUND_TO) - refundBefore, pulled, "refundTo refunded");
        assertEq(tokenB.balanceOf(address(this)), driverBefore, "driver gets nothing");
        assertEq(tokenB.balanceOf(address(wrapper)), 0, "wrapper keeps nothing");
        (address recorded,) = wrapper.escrows(depositId);
        assertEq(recorded, address(0), "record cleared");
    }

    /// Anyone may drive the cancel; the destination is the recorded `refundTo`.
    function testCancelEscrowIsPermissionless() public {
        (uint256 depositId, uint256 pulled) = _swapAndEscrow();
        uint256 refundBefore = tokenB.balanceOf(SWAP_REFUND_TO);

        vm.prank(address(0xDEAD));
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );

        assertEq(tokenB.balanceOf(SWAP_REFUND_TO) - refundBefore, pulled, "refund follows the record, not the caller");
        assertEq(tokenB.balanceOf(address(0xDEAD)), 0, "caller gets nothing");
    }

    /// The refund token comes from the cancel's `publicAssetId`, so naming
    /// another registered asset must not pay out in that asset: the pool checks
    /// the id against the escrow digest and the whole cancel reverts.
    function testRevertCancelEscrowWithAnotherAssetId() public {
        (uint256 depositId,) = _swapAndEscrow();
        tokenA.mint(address(wrapper), 1e24);
        uint256 refundA = tokenA.balanceOf(SWAP_REFUND_TO);

        vm.expectRevert("MockMASPSwap: digest mismatch");
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

        assertEq(tokenA.balanceOf(SWAP_REFUND_TO), refundA, "no payout in the other asset");
        (address recorded,) = wrapper.escrows(depositId);
        assertEq(recorded, SWAP_REFUND_TO, "record intact");
    }

    function testRevertCancelEscrowWithoutRecord() public {
        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.NoEscrowRecord.selector, uint256(42)));
        wrapper.cancelEscrow(
            42,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
    }

    function testRevertCancelEscrowReplay() public {
        (uint256 depositId,) = _swapAndEscrow();
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );

        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.NoEscrowRecord.selector, depositId));
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
    }

    /// A flushed deposit leaves a stale record and returns nothing. Paying it
    /// out would spend another escrow's coin, so it is rejected up front.
    function testRevertCancelEscrowAfterFlush() public {
        (uint256 depositId,) = _swapAndEscrow();
        pool.simulateFlush(depositId);

        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.DepositAlreadySettled.selector, depositId));
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
    }

    /// The refund is attributed by delta and checked against the pool's reported
    /// refund, so a pool that delivers less than it reports must not settle the
    /// record out of some other escrow's coin.
    function testRevertCancelEscrowRefundMismatch() public {
        (uint256 depositId, uint256 pulled) = _swapAndEscrow();
        pool.setRefundShortfall(1);

        vm.expectRevert(
            abi.encodeWithSelector(MaspEscrowSatellite.RefundMismatch.selector, depositId, pulled - 1, pulled)
        );
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
    }

    /// A refund below the record that the pool reports honestly is forwarded as
    /// delivered. A yield-asset cancel is capped at the pull and floored at the
    /// current index, so it can fall short of the record; rejecting it would
    /// leave the escrow with no refund path, since only the wrapper may cancel.
    function testCancelEscrowForwardsShortRefundWhenPoolReportsIt() public {
        (uint256 depositId, uint256 pulled) = _swapAndEscrow();
        uint256 shortfall = pulled / 4 + 1;
        pool.setRefundShortfall(shortfall);
        pool.setReportShortfall(true);
        uint256 refundBefore = tokenB.balanceOf(SWAP_REFUND_TO);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit SwapWrapper.EscrowRefunded(depositId, SWAP_REFUND_TO, address(tokenB), pulled - shortfall);
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );

        assertEq(tokenB.balanceOf(SWAP_REFUND_TO) - refundBefore, pulled - shortfall, "short refund forwarded");
        assertEq(tokenB.balanceOf(address(wrapper)), 0, "wrapper keeps nothing");
        (address recorded,) = wrapper.escrows(depositId);
        assertEq(recorded, address(0), "record cleared");
    }
}
