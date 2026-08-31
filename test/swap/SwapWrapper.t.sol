// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockSwapAdapter } from "./mocks/MockSwapAdapter.sol";
import { MockMASPSwap } from "./mocks/MockMASPSwap.sol";
import { SwapTestBase } from "./SwapTestBase.sol";

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
        a.adapter = adapter_;
        a.route = abi.encode(uint24(500), uint160(0));
        a.deadline = type(uint256).max;
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
        // Real venues deliver gross output; wrapper computes the dust
        // (gross - MASP pull) on its own via balance delta. Size venue
        // output to cover MASP's fee-on-publicIn pull plus a 7-unit
        // surplus that ends up in the treasury.
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

        (uint256 ret, uint256 depositId) = wrapper.swap(a);
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
        uint256 floorIn = netIn - 3 * SCALE; // deliberately below the net receipt
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

        wrapper.swap(a);
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
        wrapper.swap(a);
    }

    /// Pre-existing token dust must not brick a swap (donation-tolerant
    /// leftover invariant). Donations remain in the wrapper afterwards.
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

        // Griefer donations sitting in the wrapper before the swap.
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

        wrapper.swap(a);

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
        wrapper.swap(a);
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
        wrapper.swap(a);
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
        wrapper.swap(a);
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
        wrapper.swap(a);

        a.amountIn = 1_000 * SCALE;
        a.minOut = 0;
        vm.expectRevert(SwapWrapper.MinOutZero.selector);
        wrapper.swap(a);
    }

    function testRevertWhenAdapterReturnsLessThanMin() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint256 minOut = 990 * SCALE;
        _mintToPool(grossIn);
        _fundAdapter(minOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(minOut - 1); // triggers MockSwapAdapter's own revert

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            depositIn: 990,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
        vm.expectRevert(bytes("MockSwapAdapter: insufficient out"));
        wrapper.swap(a);
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
        wrapper.swap(a);
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
        wrapper.swap(a);
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

    /// A venue that hands back part of the input leaves `tokenIn` on the
    /// wrapper. Nothing downstream notices — the closing invariant is the only
    /// thing standing between that and a balance the next swap could spend.
    function testRevertWhenAdapterReturnsInputToken() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        uint256 stray = 5 * SCALE;
        adapter.setRefundIn(stray);

        vm.expectRevert(abi.encodeWithSelector(SwapWrapper.LeftoverBalance.selector, address(tokenA), stray));
        wrapper.swap(a);
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
        wrapper.swap(a);
    }

    /// The wrapper re-checks `minOut` itself rather than trusting the adapter
    /// to revert. Adapters are owner-allowlisted but still external code.
    function testRevertWhenAdapterUnderReportsBelowMinOut() public {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        uint256 short_ = a.minOut - 1;
        adapter.setIgnoreMinOut(true);
        adapter.setNextActualOut(short_);

        vm.expectRevert(abi.encodeWithSelector(SwapWrapper.InsufficientOut.selector, short_, a.minOut));
        wrapper.swap(a);
    }

    // -------- escrow recovery -------------------------------------------

    /// Run the happy path and return the escrow it created.
    function _swapAndEscrow() internal returns (uint256 depositId, uint256 pulled, address driver) {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        driver = a.pi_w.payer;
        (, depositId) = wrapper.swap(a);
        (,, pulled) = wrapper.escrows(depositId);
    }

    /// An escrow that never gets flushed is refunded to the address that drove
    /// the swap. Without this path the coin is unreachable: MASP pays the
    /// digest-bound payer, which is the wrapper, and only the wrapper may
    /// cancel its own deposit.
    function testCancelEscrowRefundsSwapDriver() public {
        (uint256 depositId, uint256 pulled, address driver) = _swapAndEscrow();
        assertGt(pulled, 0, "escrow recorded");
        uint256 driverBefore = tokenB.balanceOf(driver);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit SwapWrapper.EscrowRefunded(depositId, driver, address(tokenB), pulled);
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );

        assertEq(tokenB.balanceOf(driver) - driverBefore, pulled, "driver refunded");
        assertEq(tokenB.balanceOf(address(wrapper)), 0, "wrapper keeps nothing");
        (address refundTo,,) = wrapper.escrows(depositId);
        assertEq(refundTo, address(0), "record cleared");
    }

    /// Anyone may drive the cancel; the destination is the recorded driver.
    function testCancelEscrowIsPermissionless() public {
        (uint256 depositId, uint256 pulled, address driver) = _swapAndEscrow();
        uint256 driverBefore = tokenB.balanceOf(driver);

        vm.prank(address(0xDEAD));
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );

        assertEq(tokenB.balanceOf(driver) - driverBefore, pulled, "refund follows the record, not the caller");
        assertEq(tokenB.balanceOf(address(0xDEAD)), 0, "caller gets nothing");
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
            PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
    }

    function testRevertCancelEscrowReplay() public {
        (uint256 depositId,,) = _swapAndEscrow();
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
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
            PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
    }

    /// A flushed deposit leaves a stale record and returns nothing. Paying it
    /// out would spend another escrow's coin, so it is rejected up front.
    function testRevertCancelEscrowAfterFlush() public {
        (uint256 depositId,,) = _swapAndEscrow();
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
            PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
    }

    /// The refund is attributed by delta, so a pool that returns less than the
    /// record must not settle it out of some other escrow's coin.
    function testRevertCancelEscrowShortRefund() public {
        (uint256 depositId,,) = _swapAndEscrow();
        pool.setRefundShortfall(1);

        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.RefundNotFunded.selector, depositId));
        wrapper.cancelEscrow(
            depositId,
            0,
            bytes32(0),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            0,
            PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
    }
}
