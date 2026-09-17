// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";

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

        adapter.cancelNative(
            id,
            uint48(publicIn),
            bytes32(uint256(0x1)),
            [uint256(0), 0],
            ASSET_WETH,
            FEE_BPS,
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );

        assertEq(DEPOSITOR.balance, total, "funder made whole in native");
        assertEq(weth.balanceOf(DEPOSITOR), 0, "refund is unwrapped");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter drained");
        (address refundTo,) = adapter.escrows(id);
        assertEq(refundTo, address(0), "record cleared");
    }

    function test_cancelNative_revert_NoEscrowRecord() public {
        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.NoEscrowRecord.selector, uint256(7)));
        adapter.cancelNative(
            7,
            1,
            bytes32(uint256(0x1)),
            [uint256(0), 0],
            ASSET_WETH,
            FEE_BPS,
            uint32(vm.getBlockNumber()),
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
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
        adapter.cancelNative(
            id,
            uint48(publicIn),
            bytes32(uint256(0x1)),
            [uint256(0), 0],
            ASSET_WETH,
            FEE_BPS,
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
        assertEq(DEPOSITOR.balance, total, "funder paid out");
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
        adapter.cancelNative(
            flushedId,
            uint48(publicIn),
            bytes32(uint256(0x1)),
            [uint256(0), 0],
            ASSET_WETH,
            FEE_BPS,
            uint32(vm.getBlockNumber()),
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
        // Flush moves no coin out of the pool, so both deposits remain.
        assertEq(weth.balanceOf(address(masp)), 2 * total, "the surviving escrow is untouched");
    }

    /// Flushes an adapter-owned deposit, leaving its record unfunded.
    function _flush(uint256 id, uint64 publicIn, uint64 startIndex) internal {
        _mockVerifiers();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: address(adapter), submittedAt: uint32(vm.getBlockNumber()), fbps: FEE_BPS });

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = startIndex;
        // Principal at slot 0, the relayer's fee note at slot 1. The builder
        // escrows a zero-value fee note, so its leaf carries `publicIn = 0`.
        tpi.actualCount = 2;
        tpi.cms[0] = bytes32(uint256(0x1));
        tpi.leafAsset[0] = ASSET_WETH;
        tpi.leafPublicIn[0] = publicIn;
        tpi.isDeposit[0] = 1;
        tpi.cms[1] = bytes32(uint256(0xfee));
        tpi.leafAsset[1] = 0;
        tpi.leafPublicIn[1] = 0;
        tpi.isDeposit[1] = 1;
        masp.flushBatch(ids, meta, FixtureLoader.emptyProof(), tpi);
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

        adapter.cancelNative(
            liveId,
            uint48(publicIn),
            bytes32(uint256(0x1)),
            [uint256(0), 0],
            ASSET_WETH,
            FEE_BPS,
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );

        assertEq(address(0xCAFE).balance, total, "live escrow refunded");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter holds nothing after the payout");
    }
}
