// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { PoolFixture } from "./PoolFixture.sol";

/// Symbolic proofs for the deposit escrow: what the digest binds, and what can
/// consume an escrow.
///
/// A pending deposit is stored as a single `bytes32` — `keccak256` over
/// `(address(this), chainid, id, cm, cvDep, assetId, publicIn, fbps, payer,
/// submittedAt, feeNote)`. Nothing else about the deposit is kept. Flush and
/// cancel both resupply that preimage from calldata and re-derive the hash, so
/// every guarantee about a pending deposit — that its amount cannot be
/// inflated, its payer swapped, its fee rate re-rated, or its asset changed —
/// reduces to that one equality holding only for the original preimage.
///
/// This is the cluster symbolic execution is best at here. Halmos models
/// `keccak256` as an uninterpreted function with an injectivity axiom, so a
/// proof over *all* preimages costs about what a single concrete hash does,
/// while a fuzzer can only ever sample forgeries and will never find one.
///
/// The pool, its mocks and the escrow this starts from come from `PoolFixture`.
contract MASPEscrowSymbolicTest is PoolFixture {
    function _feeNote(uint48 feeIn, bytes32 feeCm, uint256 x, uint256 y)
        internal
        pure
        returns (PubInputs.FeeNote memory)
    {
        return PubInputs.FeeNote({ feeIn: feeIn, feeCm: feeCm, feeCvDep: [x, y] });
    }

    function _cancel(
        uint256 id,
        uint48 publicIn,
        bytes32 cm,
        uint256 cvX,
        uint256 cvY,
        uint64 assetId,
        uint16 fbps,
        address payer,
        uint32 subAt,
        PubInputs.FeeNote memory feeNote
    ) internal returns (bool ok) {
        (ok,) = address(masp)
            .call(
                abi.encodeCall(MASP.cancelDeposit, (id, publicIn, cm, [cvX, cvY], assetId, fbps, payer, subAt, feeNote))
            );
    }

    // --- digest binding ----------------------------------------------------

    /// No preimage other than the submitted one cancels the escrow.
    ///
    /// Every field of the record is symbolic at once, so this is the whole
    /// anti-forgery property in one statement rather than a field-by-field
    /// enumeration: inflate `publicIn`, swap `payer`, re-point `publicAssetId`,
    /// back-date `submittedAt`, mint yourself a fee note — all of it fails on
    /// the same equality.
    ///
    /// Only the mismatching preimages are explored. That is not a weakening:
    /// the matching one is a single concrete point, exercised by
    /// `check_cancel_cannotBeReplayed` below, which is also what keeps this
    /// proof from holding vacuously. It is a deliberate cost choice — a cancel
    /// that gets *past* the digest goes on to compute a refund, and that
    /// arithmetic (`publicIn * scale * fbps / BPS`) is a symbolic-times-
    /// symbolic product under a division, which no solver here finishes.
    function check_cancel_digestBindsEveryField(
        bytes32 submittedCm,
        uint256 id,
        uint48 publicIn,
        bytes32 cm,
        uint256 cvX,
        uint256 cvY,
        uint64 assetId,
        uint16 fbps,
        address payer,
        uint32 subAt,
        uint48 feeIn,
        bytes32 feeCm,
        uint256 feeCvX,
        uint256 feeCvY
    ) public {
        uint256 escrowId = _submit(submittedCm);

        bool matchesSubmitted = id == escrowId && publicIn == uint48(PUBLIC_IN) && cm == submittedCm && cvX == CV_DEP_X
            && cvY == CV_DEP_Y && assetId == ASSET_ID && fbps == FEE_BPS && payer == address(this)
            && subAt == submittedAt && feeIn == FEE_IN && feeCm == FEE_CM && feeCvX == FEE_CV_DEP_X
            && feeCvY == FEE_CV_DEP_Y;
        vm.assume(!matchesSubmitted);

        vm.roll(block.number + masp.cancelDelay());
        bool ok =
            _cancel(id, publicIn, cm, cvX, cvY, assetId, fbps, payer, subAt, _feeNote(feeIn, feeCm, feeCvX, feeCvY));

        assertFalse(ok);
        assertTrue(masp.escrowed(escrowId) != bytes32(0), "escrow survives a rejected cancel");
    }

    /// An escrow is consumed once. The second cancel finds the sentinel back in
    /// place and reverts, so a refund cannot be drawn twice.
    ///
    /// This is also the non-vacuity anchor for the proof above: it shows the
    /// submitted preimage does cancel.
    function check_cancel_cannotBeReplayed(bytes32 submittedCm) public {
        uint256 escrowId = _submit(submittedCm);
        vm.roll(block.number + masp.cancelDelay());

        assertTrue(
            _cancel(
                escrowId,
                uint48(PUBLIC_IN),
                submittedCm,
                CV_DEP_X,
                CV_DEP_Y,
                ASSET_ID,
                FEE_BPS,
                address(this),
                submittedAt,
                _feeNote(FEE_IN, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
            ),
            "first cancel settles"
        );
        assertEq(masp.escrowed(escrowId), bytes32(0));

        assertFalse(
            _cancel(
                escrowId,
                uint48(PUBLIC_IN),
                submittedCm,
                CV_DEP_X,
                CV_DEP_Y,
                ASSET_ID,
                FEE_BPS,
                address(this),
                submittedAt,
                _feeNote(FEE_IN, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
            ),
            "replay rejected"
        );
    }

    /// The cancel delay holds for every block height, and is measured from the
    /// digest-bound `submittedAt` rather than anything the caller supplies
    /// freely — a back-dated `submittedAt` fails the digest instead.
    function check_cancel_delayHoldsAtEveryBlock(bytes32 submittedCm, uint32 height) public {
        uint256 escrowId = _submit(submittedCm);
        vm.assume(height >= submittedAt);
        vm.roll(height);

        bool ok = _cancel(
            escrowId,
            uint48(PUBLIC_IN),
            submittedCm,
            CV_DEP_X,
            CV_DEP_Y,
            ASSET_ID,
            FEE_BPS,
            address(this),
            submittedAt,
            _feeNote(FEE_IN, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
        );

        assertEq(ok, uint256(height) >= uint256(submittedAt) + uint256(masp.cancelDelay()));
    }

    /// A contract payer's deposit can only be cancelled by that payer.
    ///
    /// The refund goes to the digest-bound payer, not to whoever funded it, so
    /// a satellite must observe the refund arriving; a third-party cancel is
    /// indistinguishable on-chain from a flush and would strand the funder's
    /// claim. This contract is the payer, so every other caller must be
    /// rejected — for every address, not a sampled few.
    function check_cancel_contractPayerIsSelfServiceOnly(bytes32 submittedCm, address caller) public {
        uint256 escrowId = _submit(submittedCm);
        vm.assume(caller != address(this));
        vm.roll(block.number + masp.cancelDelay());

        vm.prank(caller);
        bool ok = _cancel(
            escrowId,
            uint48(PUBLIC_IN),
            submittedCm,
            CV_DEP_X,
            CV_DEP_Y,
            ASSET_ID,
            FEE_BPS,
            address(this),
            submittedAt,
            _feeNote(FEE_IN, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
        );

        assertFalse(ok);
        assertTrue(masp.escrowed(escrowId) != bytes32(0));
    }

    /// The cancel delay is accepted for exactly its documented range, and only
    /// from the owner.
    ///
    /// It is the one parameter that decides how long escrowed funds are locked
    /// before their depositor can take them back, so it is bounded on both
    /// sides: too short and a flush racing a cancel becomes a live conflict,
    /// too long and a deposit is held indefinitely by a parameter change.
    function check_cancelDelay_acceptsExactlyItsDocumentedRange(uint32 newDelay) public {
        uint32 before = masp.cancelDelay();

        vm.prank(OWNER);
        (bool ok,) = address(masp).call(abi.encodeCall(MASP.setCancelDelay, (newDelay)));

        bool inRange = newDelay >= 3_600 && newDelay <= 50_400;
        assertEq(ok, inRange);
        assertEq(masp.cancelDelay(), inRange ? newDelay : before);
    }

    /// And no one else can move it: lengthening it is a way to hold a pending
    /// deposit, so it is owner-only for every other caller.
    function check_cancelDelay_isOwnerOnly(address caller, uint32 newDelay) public {
        vm.assume(caller != OWNER);
        uint32 before = masp.cancelDelay();

        vm.prank(caller);
        (bool ok,) = address(masp).call(abi.encodeCall(MASP.setCancelDelay, (newDelay)));

        assertFalse(ok);
        assertEq(masp.cancelDelay(), before);
    }

    /// A rate change cannot re-rate a deposit already in escrow, for any new
    /// rate the owner can set.
    ///
    /// `fbps` is folded into the digest at submit, so the only rate that
    /// cancels the escrow is the one it was quoted at. The registry's own rate
    /// has moved; the escrow's has not.
    function check_feeChangeCannotRerateAPendingDeposit(bytes32 submittedCm, uint16 newBps) public {
        uint256 escrowId = _submit(submittedCm);
        vm.assume(newBps <= 2000 && newBps != FEE_BPS);

        vm.prank(OWNER);
        masp.setAssetFee(ASSET_ID, newBps, newBps);

        vm.roll(block.number + masp.cancelDelay());

        // The new rate does not open the escrow...
        assertFalse(
            _cancel(
                escrowId,
                uint48(PUBLIC_IN),
                submittedCm,
                CV_DEP_X,
                CV_DEP_Y,
                ASSET_ID,
                newBps,
                address(this),
                submittedAt,
                _feeNote(FEE_IN, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
            ),
            "re-rated cancel rejected"
        );

        // ...and the rate quoted at submit still does.
        assertTrue(
            _cancel(
                escrowId,
                uint48(PUBLIC_IN),
                submittedCm,
                CV_DEP_X,
                CV_DEP_Y,
                ASSET_ID,
                FEE_BPS,
                address(this),
                submittedAt,
                _feeNote(FEE_IN, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
            ),
            "submit-time rate still settles"
        );
    }
}
