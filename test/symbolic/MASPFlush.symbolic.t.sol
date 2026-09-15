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
/// The pool, its mocks and `_submit`'s symbolic-`cm` escrow come from
/// `PoolFixture`; see `_submit` for why `cm` must not be concrete.
contract MASPFlushSymbolicTest is PoolFixture {
    /// The valid batch for a single pending deposit: two adjacent leaves (the
    /// principal, then the note paying the flusher) at the start of an empty tree.
    function _batchFor(bytes32 cm) internal pure returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = EMPTY_ROOT;
        tpi.newRoot = bytes32(uint256(0xbeef));
        tpi.startIndex = 0;
        tpi.actualCount = 2;
        tpi.cms[0] = cm;
        tpi.cms[1] = FEE_CM;
        tpi.cvDeps[0] = [CV_DEP_X, CV_DEP_Y];
        tpi.cvDeps[1] = [FEE_CV_DEP_X, FEE_CV_DEP_Y];
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafAsset[1] = ASSET_ID;
        tpi.leafPublicIn[0] = PUBLIC_IN;
        tpi.leafPublicIn[1] = FEE_IN;
        tpi.isDeposit[0] = 1;
        tpi.isDeposit[1] = 1;
    }

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
    /// The flusher supplies `payer`, `submittedAt` and `fbps` in `meta` and the
    /// leaf values in `tpi`, authenticated only by this equality. Without it a
    /// relayer could flush a deposit with an inflated `leafPublicIn` or mint a
    /// larger fee note than the depositor agreed to; the fee leaf is bound because
    /// `flushBatch` supplies both leaves from calldata.
    function check_flush_digestBindsEveryField(
        bytes32 submittedCm,
        bytes32 cm,
        uint64 leafPublicIn,
        uint64 leafFeeIn,
        bytes32 feeCm,
        address payer,
        uint32 subAt,
        uint16 fbps
    ) public {
        uint256 id = _submit(submittedCm);

        bool matchesSubmitted = cm == submittedCm && leafPublicIn == PUBLIC_IN && leafFeeIn == FEE_IN && feeCm == FEE_CM
            && payer == address(this) && subAt == submittedAt && fbps == FEE_BPS;
        vm.assume(!matchesSubmitted);
        // Out-of-range widths fail an earlier check, covered by
        // `check_flush_rejectsOutOfRangeLeafAmount`.
        vm.assume(leafPublicIn <= type(uint48).max && leafFeeIn <= type(uint48).max);

        PubInputs.TreeUpdateBatch memory tpi = _batchFor(cm);
        tpi.leafPublicIn[0] = leafPublicIn;
        tpi.leafPublicIn[1] = leafFeeIn;
        tpi.cms[1] = feeCm;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(payer, subAt, fbps)), tpi);

        _assertRejected(ok, ret, MASP.DigestMismatch.selector, "rejected by the digest check");
        assertTrue(masp.escrowed(id) != bytes32(0), "escrow survives a rejected flush");
    }

    /// Leaf amounts are narrowed to `uint48` before entering the digest, so a
    /// wider value is rejected rather than truncated into a matching hash.
    function check_flush_rejectsOutOfRangeLeafAmount(bytes32 submittedCm, uint64 leafPublicIn) public {
        vm.assume(leafPublicIn > type(uint48).max);

        uint256 id = _submit(submittedCm);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedCm);
        tpi.leafPublicIn[0] = leafPublicIn;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), tpi);

        _assertRejected(ok, ret, MASP.PublicInTooLarge.selector);
    }

    /// A non-zero fee note is denominated in the deposit's asset. A fee leaf
    /// declaring another asset would be paid from an asset the depositor never
    /// funded.
    function check_flush_rejectsMismatchedFeeAsset(bytes32 submittedCm, uint64 feeAsset) public {
        vm.assume(feeAsset != ASSET_ID);

        uint256 id = _submit(submittedCm);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedCm);
        tpi.leafAsset[1] = feeAsset;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), tpi);

        _assertRejected(ok, ret, MASP.DigestMismatch.selector);
    }

    /// Both of a deposit's leaves must be flagged as deposit leaves, for every
    /// flag pair. The circuit does not enforce this, so the contract does.
    function check_flush_rejectsNonDepositLeaf(bytes32 submittedCm, uint8 flagA, uint8 flagB) public {
        vm.assume(flagA != 1 || flagB != 1);

        uint256 id = _submit(submittedCm);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedCm);
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
    function check_flush_rejectsCancelledEscrow(bytes32 submittedCm) public {
        uint256 id = _submit(submittedCm);

        vm.roll(block.number + masp.cancelDelay());
        (bool cancelled,) = address(masp)
            .call(
                abi.encodeCall(
                    MASP.cancelDeposit,
                    (
                        id,
                        PUBLIC_IN,
                        submittedCm,
                        [CV_DEP_X, CV_DEP_Y],
                        ASSET_ID,
                        FEE_BPS,
                        address(this),
                        submittedAt,
                        PubInputs.FeeNote({
                            feeIn: FEE_IN, feeAssetId: ASSET_ID, feeCm: FEE_CM, feeCvDep: [FEE_CV_DEP_X, FEE_CV_DEP_Y]
                        })
                    )
                )
            );
        assertTrue(cancelled, "cancel settles");

        (bool ok, bytes memory ret) =
            _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), _batchFor(submittedCm));

        _assertRejected(ok, ret, MASP.DepositNotPending.selector);
    }

    /// The same deposit cannot be drained twice in one batch. `_drainDeposit`
    /// deletes each record as it goes, so the second slot finds nothing pending
    /// and the batch reverts instead of paying the relayer's note twice.
    function check_flush_rejectsRepeatedIdWithinOneBatch(bytes32 submittedCm) public {
        uint256 id = _submit(submittedCm);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](2);
        meta[0] = _meta(address(this), submittedAt, FEE_BPS);
        meta[1] = meta[0];

        // Four leaves for two deposit slots.
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedCm);
        tpi.actualCount = 4;
        tpi.cms[2] = submittedCm;
        tpi.cms[3] = FEE_CM;
        tpi.cvDeps[2] = [CV_DEP_X, CV_DEP_Y];
        tpi.cvDeps[3] = [FEE_CV_DEP_X, FEE_CV_DEP_Y];
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
    function check_flush_rejectsMisplacedBatch(bytes32 submittedCm, bytes32 oldRoot, uint64 startIndex) public {
        vm.assume(oldRoot != EMPTY_ROOT || startIndex != 0);

        uint256 id = _submit(submittedCm);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedCm);
        tpi.oldRoot = oldRoot;
        tpi.startIndex = startIndex;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), tpi);

        _assertRejected(ok, ret, oldRoot != EMPTY_ROOT ? MASP.StaleOldRoot.selector : MASP.BatchMisaligned.selector);
    }

    /// The leaf count must equal two per deposit slot.
    function check_flush_rejectsWrongLeafCount(bytes32 submittedCm, uint64 actualCount) public {
        vm.assume(actualCount != 2);

        uint256 id = _submit(submittedCm);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedCm);
        tpi.actualCount = actualCount;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), tpi);

        _assertRejected(ok, ret, MASP.BatchMisaligned.selector);
    }
}
