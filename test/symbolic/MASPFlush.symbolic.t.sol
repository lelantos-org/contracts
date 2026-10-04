// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { PoolFixture } from "./PoolFixture.sol";

/// Symbolic proofs for the flush side of the escrow lifecycle.
///
/// `flushBatch` and `cancelDeposit` both resupply a pending deposit's digest
/// preimage from calldata and consume the escrow. `flushBatch` is called by a
/// relayer rather than the depositor and mints the relayer's fee note from the
/// same calldata, so the keccak equality is its only binding to submit-time
/// values.
///
/// Every proof is a rejection and stays tractable because `flushBatch` validates
/// the batch header and drains and digest-checks every deposit (phase 1) before
/// reaching `tpi.compress()` and the verifier (phase 3).
///
/// The pool, its mocks and `_submit`'s symbolic-`inner` escrow come from
/// `PoolFixture`; see `_submit` for why `inner` must not be concrete.
contract MASPFlushSymbolicTest is PoolFixture {
    /// The valid batch for a single pending deposit: two adjacent leaves (the
    /// principal, then the note paying the flusher) at the start of an empty tree.
    ///
    /// On a deposit leaf `cms[k]` carries the note's `inner`, not a commitment:
    /// the circuit builds the leaf from it and that slot's `leafAsset` and
    /// `leafPublicIn`.
    function _batchFor(bytes32 inner) internal pure returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = EMPTY_ROOT;
        tpi.newRoot = bytes32(uint256(0xbeef));
        tpi.startIndex = 0;
        tpi.actualCount = 2;
        tpi.cms[0] = inner;
        tpi.cms[1] = FEE_INNER;
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafAsset[1] = ASSET_ID;
        tpi.leafPublicIn[0] = PUBLIC_IN;
        tpi.leafPublicIn[1] = FEE_IN;
        tpi.isDeposit[0] = 1;
        tpi.isDeposit[1] = 1;
    }

    /// A plain-asset escrow's meta: `pulled`, the refund cap, stays zero.
    function _meta(address payer, uint32 subAt, uint16 fbps) internal pure returns (MASP.DepositMeta memory m) {
        m.payer = payer;
        m.submittedAt = subAt;
        m.fbps = fbps;
    }

    function _flush(uint256[] memory ids, MASP.DepositMeta[] memory meta, PubInputs.TreeUpdateBatch memory tpi)
        internal
        returns (bool ok, bytes memory ret)
    {
        MASP.Proof memory tp;
        (ok, ret) = address(masp).call(abi.encodeCall(MASP.flushBatch, (ids, meta, tp, tpi)));
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _oneMeta(MASP.DepositMeta memory m) internal pure returns (MASP.DepositMeta[] memory meta) {
        meta = new MASP.DepositMeta[](1);
        meta[0] = m;
    }

    // --- digest binding, flush side ---------------------------------------

    /// No preimage but the submitted one flushes the escrow.
    ///
    /// The flusher supplies `payer`, `submittedAt`, `fbps` and the refund cap
    /// `pulled` in `meta` and the leaf values in `tpi`, authenticated only by
    /// this equality. Without it a relayer could flush a deposit with an
    /// inflated `leafPublicIn`, mint a larger fee note than the depositor
    /// agreed to, or replace either note's `inner` and so its owner: the
    /// circuit hashes whatever `(leafAsset, leafPublicIn, cms)` the calldata
    /// holds into the leaf, and both leaves come from calldata. The escrow is
    /// in a plain asset, so the submitted cap is zero.
    function check_flush_digestBindsEveryField(
        bytes32 submittedInner,
        bytes32 inner,
        uint64 leafPublicIn,
        uint64 leafFeeIn,
        bytes32 feeInner,
        address payer,
        uint32 subAt,
        uint16 fbps,
        uint256 pulled
    ) public {
        uint256 id = _submit(submittedInner);

        bool matchesSubmitted = inner == submittedInner && leafPublicIn == PUBLIC_IN && leafFeeIn == FEE_IN
            && feeInner == FEE_INNER && payer == address(this) && subAt == submittedAt && fbps == FEE_BPS && pulled == 0;
        vm.assume(!matchesSubmitted);
        // Out-of-range widths fail an earlier check, covered by
        // `check_flush_rejectsOutOfRangeLeafAmount`.
        vm.assume(leafPublicIn <= type(uint48).max && leafFeeIn <= type(uint48).max);

        PubInputs.TreeUpdateBatch memory tpi = _batchFor(inner);
        tpi.leafPublicIn[0] = leafPublicIn;
        tpi.leafPublicIn[1] = leafFeeIn;
        tpi.cms[1] = feeInner;

        MASP.DepositMeta memory m = _meta(payer, subAt, fbps);
        m.pulled = pulled;
        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(m), tpi);

        _assertRejected(ok, ret, MASP.DigestMismatch.selector, "rejected by the digest check");
        assertTrue(masp.escrowed(id) != bytes32(0), "escrow survives a rejected flush");
    }

    /// Leaf amounts are narrowed to `uint48` before entering the digest, so a
    /// wider value is rejected rather than truncated into a matching hash.
    function check_flush_rejectsOutOfRangeLeafAmount(bytes32 submittedInner, uint64 leafPublicIn) public {
        vm.assume(leafPublicIn > type(uint48).max);

        uint256 id = _submit(submittedInner);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedInner);
        tpi.leafPublicIn[0] = leafPublicIn;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), tpi);

        _assertRejected(ok, ret, MASP.PublicInTooLarge.selector);
    }

    /// The fee leaf's asset is the `feeAssetId` escrowed at submit, for every
    /// other id, zero included. `leafAsset` of the fee slot enters the digest as
    /// `FeeNote.feeAssetId`, and the circuit hashes it into the fee leaf beside
    /// the value; a fee leaf declaring another asset would be a note in an asset
    /// the depositor never funded.
    function check_flush_rejectsMismatchedFeeAsset(bytes32 submittedInner, uint64 feeAsset) public {
        vm.assume(feeAsset != ASSET_ID);

        uint256 id = _submit(submittedInner);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedInner);
        tpi.leafAsset[1] = feeAsset;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), tpi);

        _assertRejected(ok, ret, MASP.DigestMismatch.selector);
    }

    /// Both of a deposit's leaves must be flagged as deposit leaves, for every
    /// flag pair. The circuit reads `cms[k]` by this flag: set, it builds the
    /// leaf from the slot's asset, amount and `inner`; clear, it inserts
    /// `cms[k]` as it stands. Nothing in the circuit forces the flag on a
    /// deposit, so the contract pins it; otherwise a depositor could escrow a
    /// commitment of its choosing as `inner` and hold a note of any value.
    function check_flush_rejectsNonDepositLeaf(bytes32 submittedInner, uint8 flagA, uint8 flagB) public {
        vm.assume(flagA != 1 || flagB != 1);

        uint256 id = _submit(submittedInner);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedInner);
        tpi.isDeposit[0] = flagA;
        tpi.isDeposit[1] = flagB;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), tpi);

        _assertRejected(ok, ret, MASP.BadDepositMode.selector);
    }

    // --- lifecycle exclusivity --------------------------------------------

    /// A cancelled escrow cannot then be flushed.
    ///
    /// Cancel and flush both consume an escrow by clearing the record to the
    /// zero sentinel, which makes them mutually exclusive; otherwise a depositor
    /// could take the refund and still have the note inserted.
    function check_flush_rejectsCancelledEscrow(bytes32 submittedInner) public {
        uint256 id = _submit(submittedInner);

        vm.roll(block.number + masp.cancelDelay());
        assertTrue(_cancelSubmitted(id, submittedInner), "cancel settles");

        (bool ok, bytes memory ret) =
            _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), _batchFor(submittedInner));

        _assertRejected(ok, ret, MASP.DepositNotPending.selector);
    }

    /// The same deposit cannot be drained twice in one batch. `_drainDeposit`
    /// deletes each record as it goes, so the second slot finds nothing pending
    /// and the batch reverts instead of paying the relayer's note twice.
    function check_flush_rejectsRepeatedIdWithinOneBatch(bytes32 submittedInner) public {
        uint256 id = _submit(submittedInner);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](2);
        meta[0] = _meta(address(this), submittedAt, FEE_BPS);
        meta[1] = meta[0];

        // Four leaves for two deposit slots.
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedInner);
        tpi.actualCount = 4;
        tpi.cms[2] = submittedInner;
        tpi.cms[3] = FEE_INNER;
        tpi.leafAsset[2] = ASSET_ID;
        tpi.leafAsset[3] = ASSET_ID;
        tpi.leafPublicIn[2] = PUBLIC_IN;
        tpi.leafPublicIn[3] = FEE_IN;
        tpi.isDeposit[2] = 1;
        tpi.isDeposit[3] = 1;

        (bool ok, bytes memory ret) = _flush(ids, meta, tpi);

        _assertRejected(ok, ret, MASP.DepositNotPending.selector);
    }

    // --- batch placement ---------------------------------------------------

    /// A batch must extend the live root and start at the committed leaf count,
    /// so a flush cannot insert leaves at a gap or over existing ones.
    function check_flush_rejectsMisplacedBatch(bytes32 submittedInner, bytes32 oldRoot, uint64 startIndex) public {
        vm.assume(oldRoot != EMPTY_ROOT || startIndex != 0);

        uint256 id = _submit(submittedInner);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedInner);
        tpi.oldRoot = oldRoot;
        tpi.startIndex = startIndex;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), tpi);

        _assertRejected(ok, ret, oldRoot != EMPTY_ROOT ? MASP.StaleOldRoot.selector : MASP.BatchMisaligned.selector);
    }

    /// The leaf count must equal two per deposit slot.
    function check_flush_rejectsWrongLeafCount(bytes32 submittedInner, uint64 actualCount) public {
        vm.assume(actualCount != 2);

        uint256 id = _submit(submittedInner);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedInner);
        tpi.actualCount = actualCount;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), tpi);

        _assertRejected(ok, ret, MASP.BatchMisaligned.selector);
    }
}
