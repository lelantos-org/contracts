// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";

import { NativeAdapterTestBase } from "./NativeAdapterTestBase.sol";

/// `NativeAdapter` refund path for adapter-owned escrows: native refunds to the
/// funder, and records left stale by a flush. Fixture and helpers in
/// `NativeAdapterTestBase`.
contract NativeAdapterCancelTest is NativeAdapterTestBase {
    // --- cancel ------------------------------------------------------------

    function test_cancelNative_refundsFunderInNative() public {
        uint64 publicIn = 3;
        uint256 total = _total(publicIn);
        uint256 id = _deposit(DEPOSITOR, publicIn, total);
        uint32 submittedAt = uint32(vm.getBlockNumber());

        vm.roll(block.number + masp.cancelDelay());

        vm.expectEmit(true, true, true, true, address(adapter));
        emit NativeAdapter.NativeRefunded(id, DEPOSITOR, total);

        _cancel(id, publicIn, submittedAt);

        assertEq(DEPOSITOR.balance, total, "funder made whole in native");
        assertEq(weth.balanceOf(DEPOSITOR), 0, "refund is unwrapped");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter drained");
        (address refundTo,) = adapter.escrows(id);
        assertEq(refundTo, address(0), "record cleared");
    }

    function test_cancelNative_revert_NoEscrowRecord() public {
        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.NoEscrowRecord.selector, uint256(7)));
        _cancel(7, 1, uint32(vm.getBlockNumber()));
    }

    /// The pool accepts a cancel of a contract payer's deposit only from that
    /// contract. Otherwise a third party could settle the pool leg directly and
    /// leave the refund here, indistinguishable on-chain from a flushed deposit,
    /// stranding the funder's claim.
    function test_pool_rejectsThirdPartyCancelOfAdapterDeposit() public {
        uint64 publicIn = 3;
        uint256 total = _total(publicIn);
        uint256 id = _deposit(DEPOSITOR, publicIn, total);
        uint32 submittedAt = uint32(vm.getBlockNumber());

        vm.roll(block.number + masp.cancelDelay());
        vm.expectRevert(MASP.PayerNotSender.selector);
        _poolCancel(id, publicIn, submittedAt);

        // The adapter-driven path settles it.
        _cancel(id, publicIn, submittedAt);
        assertEq(DEPOSITOR.balance, total, "funder paid out");
    }

    /// The adapter keeps none of the escrow digest preimage: the canceller
    /// resupplies it, and the pool binds every word. A cancel naming another
    /// `inner`, for the depositor's note or for the relayer's, is refused, and
    /// the escrow and its record stay.
    function test_cancelNative_revert_DigestMismatch_wrongInner() public {
        uint64 publicIn = 3;
        uint256 id = _deposit(DEPOSITOR, publicIn, _total(publicIn));
        uint32 submittedAt = uint32(vm.getBlockNumber());
        vm.roll(vm.getBlockNumber() + masp.cancelDelay());

        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        _cancelWith(id, publicIn, bytes32(uint256(0x2)), DepositFixture.FEE_INNER, submittedAt);

        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        _cancelWith(id, publicIn, INNER, bytes32(uint256(0xbad)), submittedAt);

        assertTrue(masp.escrowed(id) != bytes32(0), "escrow survives every rejected cancel");
        (address refundTo,) = adapter.escrows(id);
        assertEq(refundTo, DEPOSITOR, "record intact");
        assertEq(DEPOSITOR.balance, 0, "nothing refunded");

        _cancel(id, publicIn, submittedAt);
        assertEq(DEPOSITOR.balance, _total(publicIn), "the submitted preimage settles it");
    }

    /// `cancelNative` with the preimage `_deposit` escrowed.
    function _cancel(uint256 id, uint64 publicIn, uint32 submittedAt) internal {
        _cancelWith(id, publicIn, INNER, DepositFixture.FEE_INNER, submittedAt);
    }

    /// `cancelNative` for a WETH escrow with a zero-value relayer note, naming
    /// `inner` and `feeInner`. Makes no other call, so a pending
    /// `vm.expectRevert` applies to the cancel itself.
    function _cancelWith(uint256 id, uint64 publicIn, bytes32 inner, bytes32 feeInner, uint32 submittedAt) internal {
        adapter.cancelNative(
            id,
            uint48(publicIn),
            inner,
            ASSET_WETH,
            FEE_BPS,
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeInner: feeInner }),
            0
        );
    }

    /// A flushed deposit zeroes `escrowed[id]` and returns nothing. Its record
    /// is stale, and paying it out would spend another escrow's coin, so the
    /// settled-deposit check rejects it before any refund is attempted.
    function test_cancelNative_revert_DepositAlreadySettled_afterFlush() public {
        uint64 publicIn = 3;
        uint256 total = _total(publicIn);
        uint256 flushedId = _deposit(DEPOSITOR, publicIn, total);
        // A second, pending escrow whose funds would be at risk.
        _deposit(address(0xCAFE), publicIn, total);

        _flush(flushedId, publicIn, masp.committedCount());

        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.DepositAlreadySettled.selector, flushedId));
        _cancel(flushedId, publicIn, uint32(vm.getBlockNumber()));
        // Flush moves no coin out of the pool, so both deposits remain.
        assertEq(weth.balanceOf(address(masp)), 2 * total, "the surviving escrow is untouched");
    }

    /// Flushes an adapter-owned deposit, leaving its record unfunded.
    function _flush(uint256 id, uint64 publicIn, uint64 startIndex) internal {
        _mockVerifiers();
        MASP.DepositMeta[] memory meta = DepositFixture.metas(1, address(adapter), uint32(vm.getBlockNumber()), FEE_BPS);

        // Principal at slot 0, the zero-value relayer note at slot 1.
        PubInputs.TreeUpdateBatch memory tpi =
            DepositFixture.batch(masp.currentRoot(), bytes32(uint256(0xdead)), startIndex, 1);
        DepositFixture.setDepositLeaves(tpi, 0, INNER, ASSET_WETH, publicIn);
        masp.flushBatch(DepositFixture.ids(id), meta, FixtureLoader.emptyProof(), tpi);
    }

    /// A stale record left by a flushed deposit does not block an ordinary
    /// cancel: that path proves funding by balance delta across its own pool
    /// call and consults no shared state.
    function test_cancelNative_unaffectedByStaleFlushedRecord() public {
        uint64 publicIn = 3;
        uint256 total = _total(publicIn);
        uint256 flushedId = _deposit(DEPOSITOR, publicIn, total);
        uint256 liveId = _deposit(address(0xCAFE), publicIn, total);
        uint32 submittedAt = uint32(vm.getBlockNumber());

        _flush(flushedId, publicIn, masp.committedCount());
        vm.roll(vm.getBlockNumber() + masp.cancelDelay());

        _cancel(liveId, publicIn, submittedAt);

        assertEq(address(0xCAFE).balance, total, "live escrow refunded");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter holds nothing after the payout");
    }
}
