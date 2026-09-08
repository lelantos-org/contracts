// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { PoolFixture } from "./PoolFixture.sol";

/// Symbolic proofs for the flush side of the escrow lifecycle.
///
/// `flushBatch` is the counterpart to `cancelDeposit`: both resupply a pending
/// deposit's digest preimage from calldata and both consume the escrow. The
/// flush path is the more dangerous of the two — it is called by a relayer, not
/// the depositor, and it mints the relayer's own fee note from the same
/// calldata — so the binding matters more here, and the same keccak equality is
/// what enforces it.
///
/// Everything below is a rejection, and all of it is cheap for the same
/// structural reason: `flushBatch` drains and digest-checks every deposit in
/// phase 1 and only reaches `tpi.compress()` and the verifier in phase 3. A
/// malformed batch never gets near the Fiat-Shamir transcript.
///
/// The pool, its mocks and `_submit`'s symbolic-`cm` escrow come from
/// `PoolFixture`; the README explains why that field must not be concrete.
contract MASPFlushSymbolicTest is PoolFixture {
    /// The batch a single pending deposit must be flushed with: two adjacent
    /// leaves, the principal then the note paying the flusher, aligned to an
    /// empty tree.
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
    /// leaf values in `tpi`, none of it authenticated by anything except this
    /// equality. Without it a relayer could flush a deposit under an inflated
    /// `leafPublicIn`, or mint itself a larger fee note than the depositor
    /// agreed to — the fee leaf is bound exactly because `flushBatch` supplies
    /// both leaves from calldata.
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
        // Widths that would trip the earlier bound checks are covered by
        // `check_flush_rejectsOutOfRangeLeafAmount`; here the subject is the
        // digest.
        vm.assume(leafPublicIn <= type(uint48).max && leafFeeIn <= type(uint48).max);

        PubInputs.TreeUpdateBatch memory tpi = _batchFor(cm);
        tpi.leafPublicIn[0] = leafPublicIn;
        tpi.leafPublicIn[1] = leafFeeIn;
        tpi.cms[1] = feeCm;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(payer, subAt, fbps)), tpi);

        _assertRejected(ok, ret, MASP.DigestMismatch.selector, "rejected by the digest check");
        assertTrue(masp.escrowed(id) != bytes32(0), "escrow survives a rejected flush");
    }

    /// Both leaf amounts are narrowed to `uint48` before they enter the digest,
    /// so anything wider is rejected outright rather than silently truncated
    /// into a matching hash.
    function check_flush_rejectsOutOfRangeLeafAmount(bytes32 submittedCm, uint64 leafPublicIn) public {
        vm.assume(leafPublicIn > type(uint48).max);

        uint256 id = _submit(submittedCm);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedCm);
        tpi.leafPublicIn[0] = leafPublicIn;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), tpi);

        _assertRejected(ok, ret, MASP.PublicInTooLarge.selector);
    }

    /// The fee note is charged in the deposit's own asset. A fee leaf declaring
    /// a different one would be paid out of an asset the depositor never funded.
    function check_flush_rejectsMismatchedFeeAsset(bytes32 submittedCm, uint64 feeAsset) public {
        vm.assume(feeAsset != ASSET_ID);

        uint256 id = _submit(submittedCm);
        PubInputs.TreeUpdateBatch memory tpi = _batchFor(submittedCm);
        tpi.leafAsset[1] = feeAsset;

        (bool ok, bytes memory ret) = _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), tpi);

        _assertRejected(ok, ret, MASP.DigestMismatch.selector);
    }

    /// Both of a deposit's leaves must be flagged as deposit leaves, for every
    /// flag pair. The circuit does not force it, so the contract does.
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
    /// Cancel and flush are the two ways an escrow is consumed, and both clear
    /// the record; the zero sentinel is what makes them mutually exclusive.
    /// Without it a depositor could take the refund and still have the note
    /// inserted.
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
                        PubInputs.FeeNote({ feeIn: FEE_IN, feeCm: FEE_CM, feeCvDep: [FEE_CV_DEP_X, FEE_CV_DEP_Y] })
                    )
                )
            );
        assertTrue(cancelled, "cancel settles");

        (bool ok, bytes memory ret) =
            _flush(_one(id), _oneMeta(_meta(address(this), submittedAt, FEE_BPS)), _batchFor(submittedCm));

        _assertRejected(ok, ret, MASP.DepositNotPending.selector);
    }

    /// The same deposit cannot be drained twice inside one batch. `_drainDeposit`
    /// deletes the record as it goes, restoring the sentinel, so the second slot
    /// finds nothing pending — the batch is rejected rather than paying the
    /// relayer's note twice.
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

    /// A batch must extend the live root and start where the tree is committed
    /// to, so a flush cannot insert leaves at a gap or over existing ones.
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
