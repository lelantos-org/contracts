// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { NativeAdapter } from "../src/native/NativeAdapter.sol";
import { IMASPNative } from "../src/native/IMASPNative.sol";
import { IWrappedNative } from "../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockWETH9 } from "./mocks/MockWETH9.sol";
import { MockNativePool } from "./mocks/MockNativePool.sol";

/// `NativeAdapter` guards that a well-behaved MASP cannot trip: a deposit that
/// pulls nothing, and a cancel that under-refunds. Both would silently
/// mis-credit an escrow record, so they are asserted against a stand-in pool.
/// Constructor argument checks live here too.
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
            new NativeAdapter(IMASPNative(address(pool)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));
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
    }

    /// Deposit `AMOUNT`, with the pool pulling all of it.
    function _deposit() internal returns (uint256 id) {
        pool.setPullAmount(uint160(AMOUNT));
        vm.deal(DEPOSITOR, AMOUNT);
        vm.prank(DEPOSITOR);
        id = adapter.depositNative{ value: AMOUNT }(_request(), _aux());
    }

    // --- constructor -------------------------------------------------------

    function test_revert_ZeroPool() public {
        vm.expectRevert(NativeAdapter.ZeroAddress.selector);
        new NativeAdapter(IMASPNative(address(0)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));
    }

    function test_revert_ZeroWrappedNative() public {
        vm.expectRevert(NativeAdapter.ZeroAddress.selector);
        new NativeAdapter(IMASPNative(address(pool)), IWrappedNative(address(0)), IAllowanceTransfer(permit2));
    }

    function test_revert_ZeroPermit2() public {
        vm.expectRevert(NativeAdapter.ZeroAddress.selector);
        new NativeAdapter(IMASPNative(address(pool)), IWrappedNative(address(weth)), IAllowanceTransfer(address(0)));
    }

    // --- deposit -----------------------------------------------------------

    /// A pool that escrows nothing must not leave a zero-amount record behind:
    /// the wrap would be stranded with no claim on it.
    function test_revert_NothingEscrowed() public {
        pool.setPullAmount(0);
        vm.deal(DEPOSITOR, AMOUNT);
        vm.prank(DEPOSITOR);
        vm.expectRevert(NativeAdapter.NothingEscrowed.selector);
        adapter.depositNative{ value: AMOUNT }(_request(), _aux());
    }

    /// The pool's Permit2 allowance covers the adapter's whole balance, not
    /// just the coin that arrived with the call. A caller who oversizes the
    /// deposit must not be able to escrow refunds parked here for other
    /// depositors into a note of their own.
    function test_revert_PullExceedsValue() public {
        // Park a refund: fund the adapter with wrapped coin it did not receive
        // from this call. `MockWETH9.mint` stands in for a third-party cancel.
        uint256 parked = 5 ether;
        weth.mint(address(adapter), parked);

        // Pool pulls more than the caller sent, dipping into the parked coin.
        pool.setPullAmount(uint160(AMOUNT + parked));
        vm.deal(DEPOSITOR, AMOUNT);
        vm.prank(DEPOSITOR);
        vm.expectRevert(abi.encodeWithSelector(NativeAdapter.PullExceedsValue.selector, AMOUNT + parked, AMOUNT));
        adapter.depositNative{ value: AMOUNT }(_request(), _aux());

        assertEq(weth.balanceOf(address(adapter)), parked, "parked coin untouched");
    }

    // --- cancel ------------------------------------------------------------

    /// The funded branch attributes the refund by delta. A short refund fails
    /// there rather than paying the record out of another escrow's coin.
    function test_revert_RefundNotFunded_shortRefund() public {
        uint256 id = _deposit();
        pool.setRefundAmount(AMOUNT - 1);

        vm.expectRevert(abi.encodeWithSelector(NativeAdapter.RefundNotFunded.selector, id));
        adapter.cancelNative(id, 1, bytes32(uint256(0x1)), [uint256(0), 0], ASSET_WETH, 25, uint32(vm.getBlockNumber()));
    }

    /// Same guard against an over-refund: the delta must match the record
    /// exactly, so a pool paying too much cannot inflate a claim either.
    function test_revert_RefundNotFunded_overRefund() public {
        uint256 id = _deposit();
        // Fund the pool beyond what it escrowed so it can overpay.
        vm.deal(address(this), AMOUNT);
        weth.deposit{ value: AMOUNT }();
        weth.transfer(address(pool), AMOUNT);
        pool.setRefundAmount(AMOUNT + 1);

        vm.expectRevert(abi.encodeWithSelector(NativeAdapter.RefundNotFunded.selector, id));
        adapter.cancelNative(id, 1, bytes32(uint256(0x1)), [uint256(0), 0], ASSET_WETH, 25, uint32(vm.getBlockNumber()));
    }

    /// Exact refund on the funded branch pays the recorded funder in native.
    function test_cancelNative_fundedBranchPaysOut() public {
        uint256 id = _deposit();
        pool.setRefundAmount(AMOUNT);

        adapter.cancelNative(id, 1, bytes32(uint256(0x1)), [uint256(0), 0], ASSET_WETH, 25, uint32(vm.getBlockNumber()));

        assertEq(DEPOSITOR.balance, AMOUNT, "funder refunded in native");
    }
}
