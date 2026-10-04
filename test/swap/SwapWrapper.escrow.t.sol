// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { SwapWrapperUnitBase } from "./SwapWrapperUnitBase.sol";

/// Escrow recovery for `SwapWrapper`: `cancelEscrow` refunds an unflushed
/// escrow to the intent-bound `refundTo`, permissionlessly, and rejects a wrong
/// asset, a missing or replayed record, a flushed deposit and a refund mismatch.
contract SwapWrapperEscrowTest is SwapWrapperUnitBase {
    /// Runs the happy path and returns the escrow it created.
    function _swapAndEscrow() internal returns (uint256 depositId, uint256 pulled) {
        (SwapWrapper.SwapArgs memory a,) = _armSwap();
        (, depositId) = _swap(a);
        (, pulled) = wrapper.escrows(depositId);
    }

    /// An escrow that never gets flushed is refunded to the intent-bound
    /// `refundTo`, not the address that drove the swap. Without this path the
    /// coin is unreachable: MASP pays the digest-bound payer, which is the
    /// wrapper, and only the wrapper may cancel its own deposit.
    function test_cancelEscrowRefundsRefundTo() public {
        (uint256 depositId, uint256 pulled) = _swapAndEscrow();
        uint256 driverBefore = tokenB.balanceOf(address(this));
        assertGt(pulled, 0, "escrow recorded");
        uint256 refundBefore = tokenB.balanceOf(SWAP_REFUND_TO);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit SwapWrapper.EscrowRefunded(depositId, SWAP_REFUND_TO, address(tokenB), pulled);
        _cancelEscrow(depositId, ASSET_B);

        assertEq(tokenB.balanceOf(SWAP_REFUND_TO) - refundBefore, pulled, "refundTo refunded");
        assertEq(tokenB.balanceOf(address(this)), driverBefore, "driver gets nothing");
        assertEq(tokenB.balanceOf(address(wrapper)), 0, "wrapper keeps nothing");
        (address recorded,) = wrapper.escrows(depositId);
        assertEq(recorded, address(0), "record cleared");
    }

    /// Anyone may drive the cancel; the destination is the recorded `refundTo`.
    function test_cancelEscrowIsPermissionless() public {
        (uint256 depositId, uint256 pulled) = _swapAndEscrow();
        uint256 refundBefore = tokenB.balanceOf(SWAP_REFUND_TO);

        vm.prank(address(0xDEAD));
        _cancelEscrow(depositId, ASSET_B);

        assertEq(tokenB.balanceOf(SWAP_REFUND_TO) - refundBefore, pulled, "refund follows the record, not the caller");
        assertEq(tokenB.balanceOf(address(0xDEAD)), 0, "caller gets nothing");
    }

    /// The wrapper keeps none of the escrow digest preimage, so `cancelEscrow`
    /// must hand the pool what the caller read from `DepositEscrowed`, each
    /// value in its own slot, with itself as the payer. The stub pool checks
    /// only the asset id, so the forwarded call is pinned here, with a distinct
    /// value in every slot.
    function test_cancelEscrowForwardsThePreimageToThePool() public {
        (uint256 depositId,) = _swapAndEscrow();
        PubInputs.FeeNote memory feeNote =
            PubInputs.FeeNote({ feeIn: 5, feeAssetId: ASSET_B, feeInner: bytes32(uint256(0xfee)) });

        vm.expectCall(
            address(pool),
            abi.encodeCall(
                IMASPPool.cancelDeposit,
                (depositId, 990, bytes32(uint256(0x1)), ASSET_B, FEE_BPS, address(wrapper), 7, feeNote, 11)
            )
        );
        wrapper.cancelEscrow(depositId, 990, bytes32(uint256(0x1)), ASSET_B, FEE_BPS, 7, feeNote, 11);
    }

    /// The refund token comes from the cancel's `publicAssetId`, so naming
    /// another registered asset must not pay out in that asset: the pool checks
    /// the id against the escrow digest and the whole cancel reverts.
    function test_revert_cancelEscrowWithAnotherAssetId() public {
        (uint256 depositId,) = _swapAndEscrow();
        tokenA.mint(address(wrapper), 1e24);
        uint256 refundA = tokenA.balanceOf(SWAP_REFUND_TO);

        vm.expectRevert("MockMASPSwap: digest mismatch");
        _cancelEscrow(depositId, ASSET_A);

        assertEq(tokenA.balanceOf(SWAP_REFUND_TO), refundA, "no payout in the other asset");
        (address recorded,) = wrapper.escrows(depositId);
        assertEq(recorded, SWAP_REFUND_TO, "record intact");
    }

    function test_revert_cancelEscrowWithoutRecord() public {
        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.NoEscrowRecord.selector, uint256(42)));
        _cancelEscrow(42, ASSET_B);
    }

    function test_revert_cancelEscrowReplay() public {
        (uint256 depositId,) = _swapAndEscrow();
        _cancelEscrow(depositId, ASSET_B);

        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.NoEscrowRecord.selector, depositId));
        _cancelEscrow(depositId, ASSET_B);
    }

    /// A flushed deposit leaves a stale record and returns nothing. Paying it
    /// out would spend another escrow's coin, so it is rejected up front.
    function test_revert_cancelEscrowAfterFlush() public {
        (uint256 depositId,) = _swapAndEscrow();
        pool.simulateFlush(depositId);

        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.DepositAlreadySettled.selector, depositId));
        _cancelEscrow(depositId, ASSET_B);
    }

    /// The refund is attributed by delta and checked against the pool's reported
    /// refund, so a pool that delivers less than it reports must not settle the
    /// record out of some other escrow's coin.
    function test_revert_cancelEscrowRefundMismatch() public {
        (uint256 depositId, uint256 pulled) = _swapAndEscrow();
        pool.setRefundShortfall(1);

        vm.expectRevert(
            abi.encodeWithSelector(MaspEscrowSatellite.RefundMismatch.selector, depositId, pulled - 1, pulled)
        );
        _cancelEscrow(depositId, ASSET_B);
    }

    /// A refund below the record that the pool reports accurately is forwarded as
    /// delivered. A yield-asset cancel is capped at the pull and floored at the
    /// current index, so it can fall short of the record; rejecting it would
    /// leave the escrow with no refund path, since only the wrapper may cancel.
    function test_cancelEscrowForwardsShortRefundWhenPoolReportsIt() public {
        (uint256 depositId, uint256 pulled) = _swapAndEscrow();
        uint256 shortfall = pulled / 4 + 1;
        pool.setRefundShortfall(shortfall);
        pool.setReportShortfall(true);
        uint256 refundBefore = tokenB.balanceOf(SWAP_REFUND_TO);

        vm.expectEmit(true, true, true, true, address(wrapper));
        emit SwapWrapper.EscrowRefunded(depositId, SWAP_REFUND_TO, address(tokenB), pulled - shortfall);
        _cancelEscrow(depositId, ASSET_B);

        assertEq(tokenB.balanceOf(SWAP_REFUND_TO) - refundBefore, pulled - shortfall, "short refund forwarded");
        assertEq(tokenB.balanceOf(address(wrapper)), 0, "wrapper keeps nothing");
        (address recorded,) = wrapper.escrows(depositId);
        assertEq(recorded, address(0), "record cleared");
    }
}
