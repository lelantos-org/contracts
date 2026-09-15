// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../../src/BabyJubJub.sol";
import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { MockNativePool } from "../mocks/MockNativePool.sol";

/// `NativeAdapter` guards that a well-behaved MASP cannot trigger: a deposit that
/// pulls nothing, and a cancel that delivers other than it reports. Both would mis-credit an
/// escrow record, so they are exercised against a stand-in pool. Also covers
/// constructor argument checks.
contract NativeAdapterGuardsTest is Test {
    uint64 internal constant ASSET_WETH = 2;
    uint256 internal constant AMOUNT = 1 ether;

    address internal constant DEPOSITOR = address(0xBEEF);

    MockWETH9 internal weth;
    MockNativePool internal pool;
    NativeAdapter internal adapter;
    address internal permit2;

    function setUp() public {
        weth = new MockWETH9();
        permit2 = new DeployPermit2().deployPermit2();
        pool = new MockNativePool(IAllowanceTransfer(permit2), weth);
        adapter =
            new NativeAdapter(IMASPPool(address(pool)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));
    }

    function _aux() internal pure returns (AuxValidation.Output memory a) {
        a.clueRx = BabyJubJub.BASE8_X;
        a.clueRy = BabyJubJub.BASE8_Y;
        a.ephPubX = BabyJubJub.BASE8_X;
        a.ephPubY = BabyJubJub.BASE8_Y;
        a.ciphertext = hex"0001";
    }

    function _request() internal view returns (PubInputs.DepositRequest memory d) {
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_WETH;
        d.publicIn = 1;
        d.payer = address(adapter);
        d.recipient = address(0xF00D);
        d.outCm = bytes32(uint256(0x1));
        d.feeCm = bytes32(uint256(0xfee));
    }

    /// Deposits `AMOUNT`, with the pool pulling all of it.
    function _deposit() internal returns (uint256 id) {
        pool.setPullAmount(uint160(AMOUNT));
        vm.deal(DEPOSITOR, AMOUNT);
        vm.prank(DEPOSITOR);
        id = adapter.depositNative{ value: AMOUNT }(_request(), _aux(), _aux());
    }

    // --- constructor -------------------------------------------------------

    function test_revert_ZeroPool() public {
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        new NativeAdapter(IMASPPool(address(0)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));
    }

    function test_revert_ZeroWrappedNative() public {
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        new NativeAdapter(IMASPPool(address(pool)), IWrappedNative(address(0)), IAllowanceTransfer(permit2));
    }

    /// `withdrawNative` forwards through a low-level call, which would succeed
    /// against an address with no code.
    function test_revert_CodelessPool() public {
        vm.expectRevert(NativeAdapter.PoolNotAContract.selector);
        new NativeAdapter(IMASPPool(address(0xC0DE)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));
    }

    function test_revert_ZeroPermit2() public {
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        new NativeAdapter(IMASPPool(address(pool)), IWrappedNative(address(weth)), IAllowanceTransfer(address(0)));
    }

    // --- deposit -----------------------------------------------------------

    /// A pool that escrows nothing does not leave a zero-amount record, which
    /// would strand the wrapped coin with no claim on it.
    function test_revert_NothingEscrowed() public {
        pool.setPullAmount(0);
        vm.deal(DEPOSITOR, AMOUNT);
        vm.prank(DEPOSITOR);
        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.PullBelowMin.selector, uint256(0), uint256(1)));
        adapter.depositNative{ value: AMOUNT }(_request(), _aux(), _aux());
    }

    /// The pool's Permit2 allowance covers the adapter's whole balance, not
    /// just the coin that arrived with the call. A caller who oversizes the
    /// deposit cannot escrow refunds held here for other depositors into their
    /// own note.
    function test_revert_PullExceedsValue() public {
        // Funds the adapter with wrapped coin not received from this call.
        // `MockWETH9.mint` stands in for a third-party cancel refund.
        uint256 parked = 5 ether;
        weth.mint(address(adapter), parked);

        // The pool pulls more than the caller sent, reaching into the parked coin.
        pool.setPullAmount(uint160(AMOUNT + parked));
        vm.deal(DEPOSITOR, AMOUNT);
        vm.prank(DEPOSITOR);
        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.PullExceedsMax.selector, AMOUNT + parked, AMOUNT));
        adapter.depositNative{ value: AMOUNT }(_request(), _aux(), _aux());

        assertEq(weth.balanceOf(address(adapter)), parked, "parked coin untouched");
    }

    /// The escrow record stores `amount` in 96 bits so the pair shares one
    /// slot. A pull that does not fit reverts; truncation would under-record the
    /// escrow and strand the difference on cancel.
    function test_revert_EscrowAmountTooLarge() public {
        uint256 tooLarge = uint256(type(uint96).max) + 1;
        pool.setPullAmount(uint160(tooLarge));
        vm.deal(DEPOSITOR, tooLarge);
        vm.prank(DEPOSITOR);
        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.EscrowAmountTooLarge.selector, tooLarge));
        adapter.depositNative{ value: tooLarge }(_request(), _aux(), _aux());
    }

    /// The largest pull the record can hold is accepted, and reads back intact.
    function test_escrowAmountAtWidthBoundary() public {
        uint256 atMax = uint256(type(uint96).max);
        pool.setPullAmount(uint160(atMax));
        vm.deal(DEPOSITOR, atMax);
        vm.prank(DEPOSITOR);
        uint256 id = adapter.depositNative{ value: atMax }(_request(), _aux(), _aux());

        (address refundTo, uint256 amount) = adapter.escrows(id);
        assertEq(refundTo, DEPOSITOR, "funder recorded");
        assertEq(amount, atMax, "amount recorded without truncation");
    }

    // --- cancel ------------------------------------------------------------

    /// The refund is attributed by balance delta and checked against the amount
    /// the pool reports paying. A pool that reports more than it delivers
    /// reverts rather than paying the record out of another escrow's coin.
    function test_revert_RefundMismatch_underDelivered() public {
        uint256 id = _deposit();
        pool.setRefundAmount(AMOUNT - 1);
        pool.setReportedAmount(AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.RefundMismatch.selector, id, AMOUNT - 1, AMOUNT));
        _cancel(id);
    }

    /// A delivery above the reported refund is rejected too: the surplus is not
    /// attributable to this escrow and would indicate fee-on-transfer behaviour
    /// or a balance movement the pool did not account for.
    function test_revert_RefundMismatch_overDelivered() public {
        uint256 id = _deposit();
        // Fund the pool beyond what it escrowed so it can overpay.
        vm.deal(address(this), AMOUNT);
        weth.deposit{ value: AMOUNT }();
        weth.transfer(address(pool), AMOUNT);
        pool.setRefundAmount(AMOUNT + 1);
        pool.setReportedAmount(AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.RefundMismatch.selector, id, AMOUNT + 1, AMOUNT));
        _cancel(id);
    }

    /// A refund below the recorded amount, reported as such, is accepted and
    /// forwarded as delivered.
    ///
    /// This covers yield assets: a cancel refunds the escrow's units at the
    /// current index, floored and capped at the pull, so it falls a wei short at
    /// a flat index and further after a venue loss. A floor at the record would
    /// revert those cancels, and the pool accepts a contract payer's cancel only
    /// from the payer itself, so the escrow would have no refund path.
    function test_cancelNative_forwardsReportedShortRefund() public {
        uint256 id = _deposit();
        uint256 refund = AMOUNT / 3;
        pool.setRefundAmount(refund);

        _cancel(id);

        assertEq(DEPOSITOR.balance, refund, "the reported short refund is forwarded");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter keeps nothing");
        (address refundTo,) = adapter.escrows(id);
        assertEq(refundTo, address(0), "record cleared");
    }

    /// Exact refund on the funded branch pays the recorded funder in native.
    function test_cancelNative_fundedBranchPaysOut() public {
        uint256 id = _deposit();
        pool.setRefundAmount(AMOUNT);

        _cancel(id);

        assertEq(DEPOSITOR.balance, AMOUNT, "funder refunded in native");
    }

    /// A second-token refund cannot arrive unaccounted for: the adapter never
    /// escrows a relayer note in another asset, and reverts if the pool reports
    /// paying one.
    function test_revert_cancelNative_feeRefundedReported() public {
        uint256 id = _deposit();
        pool.setRefundAmount(AMOUNT);
        pool.setFeeRefundedReport(1);

        vm.expectRevert(MaspEscrowSatellite.FeeAssetMismatch.selector);
        _cancel(id);
    }

    /// Cancels `id` with the preimage `_deposit` escrowed; the stand-in pool
    /// checks none of it.
    function _cancel(uint256 id) internal {
        adapter.cancelNative(
            id,
            1,
            bytes32(uint256(0x1)),
            [uint256(0), 0],
            ASSET_WETH,
            25,
            uint32(vm.getBlockNumber()),
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
    }
}
