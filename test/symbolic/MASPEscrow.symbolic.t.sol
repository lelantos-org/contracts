// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { PoolFixture } from "./PoolFixture.sol";

/// Symbolic proofs for the deposit escrow: what the digest binds, and what can
/// consume an escrow.
///
/// A pending deposit is stored only as a `bytes32`: `keccak256` over
/// `(address(this), chainid, id, cm, cvDep, assetId, publicIn, fbps, payer,
/// submittedAt, feeNote)`. Flush and cancel both resupply that preimage from
/// calldata and re-derive the hash, so every guarantee about a pending deposit
/// (amount not inflated, payer not swapped, fee rate not changed, asset not
/// changed) reduces to that equality holding only for the original preimage.
///
/// Halmos models `keccak256` as an uninterpreted function with an injectivity
/// axiom, so a proof over all preimages costs roughly as much as one concrete
/// hash, whereas a fuzzer can only sample candidate forgeries.
///
/// The pool, its mocks and the starting escrow come from `PoolFixture`.
contract MASPEscrowSymbolicTest is PoolFixture {
    function _feeNote(uint48 feeIn, uint64 feeAssetId, bytes32 feeCm, uint256 x, uint256 y)
        internal
        pure
        returns (PubInputs.FeeNote memory)
    {
        return PubInputs.FeeNote({ feeIn: feeIn, feeAssetId: feeAssetId, feeCm: feeCm, feeCvDep: [x, y] });
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
    /// Every field of the record is symbolic simultaneously, so this states the
    /// full anti-forgery property in one proof: an inflated `publicIn`, swapped
    /// `payer`, different `publicAssetId`, back-dated `submittedAt` or altered fee
    /// note all fail the same equality.
    ///
    /// Only mismatching preimages are explored. The matching preimage is a single
    /// concrete point covered by `check_cancel_cannotBeReplayed`, which also shows
    /// this proof is not vacuous. A cancel past the digest check computes a refund
    /// (`publicIn * scale * fbps / BPS`), a product of symbolic values under a
    /// division that the solvers do not finish.
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
        uint64 feeAssetId,
        bytes32 feeCm,
        uint256 feeCvX,
        uint256 feeCvY
    ) public {
        uint256 escrowId = _submit(submittedCm);

        bool matchesSubmitted = id == escrowId && publicIn == uint48(PUBLIC_IN) && cm == submittedCm && cvX == CV_DEP_X
            && cvY == CV_DEP_Y && assetId == ASSET_ID && fbps == FEE_BPS && payer == address(this)
            && subAt == submittedAt && feeIn == FEE_IN && feeAssetId == ASSET_ID && feeCm == FEE_CM
            && feeCvX == FEE_CV_DEP_X && feeCvY == FEE_CV_DEP_Y;
        vm.assume(!matchesSubmitted);

        vm.roll(block.number + masp.cancelDelay());
        bool ok = _cancel(
            id, publicIn, cm, cvX, cvY, assetId, fbps, payer, subAt, _feeNote(feeIn, feeAssetId, feeCm, feeCvX, feeCvY)
        );

        assertFalse(ok);
        assertTrue(masp.escrowed(escrowId) != bytes32(0), "escrow survives a rejected cancel");
    }

    /// An escrow is consumed once: the second cancel finds the zero sentinel and
    /// reverts, so a refund cannot be drawn twice.
    ///
    /// Also shows the submitted preimage cancels, which makes the proof above
    /// non-vacuous.
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
                _feeNote(FEE_IN, ASSET_ID, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
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
                _feeNote(FEE_IN, ASSET_ID, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
            ),
            "replay rejected"
        );
    }

    /// The cancel delay holds at every block height and is measured from the
    /// digest-bound `submittedAt`; a back-dated `submittedAt` fails the digest.
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
            _feeNote(FEE_IN, ASSET_ID, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
        );

        assertEq(ok, uint256(height) >= uint256(submittedAt) + uint256(masp.cancelDelay()));
    }

    /// A contract payer's deposit can only be cancelled by that payer.
    ///
    /// The refund goes to the digest-bound payer, not to whoever funded it, so a
    /// contract payer must observe the refund arriving; a third-party cancel is
    /// indistinguishable on-chain from a flush and would strand the funder's
    /// claim. This contract is the payer, so every other caller is rejected.
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
            _feeNote(FEE_IN, ASSET_ID, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
        );

        assertFalse(ok);
        assertTrue(masp.escrowed(escrowId) != bytes32(0));
    }

    /// The cancel delay is accepted for exactly its documented range, and only
    /// from the owner; within the range only a shortening applies at once.
    ///
    /// It sets how long escrowed funds are locked before the depositor can
    /// reclaim them, so it is bounded on both sides: too short and a flush can
    /// race a cancel, too long and a parameter change can hold deposits
    /// indefinitely. It is read live by every escrow in flight, so a
    /// lengthening is queued behind `ExitTerms.DELAY` rather than applied.
    function check_cancelDelay_acceptsExactlyItsDocumentedRange(uint32 newDelay) public {
        uint32 before = masp.cancelDelay();

        vm.prank(OWNER);
        (bool ok,) = address(masp).call(abi.encodeCall(MASP.setCancelDelay, (newDelay)));

        bool inRange = newDelay >= 3_600 && newDelay <= 50_400;
        assertEq(ok, inRange);
        assertEq(masp.cancelDelay(), inRange && newDelay <= before ? newDelay : before);
    }

    /// Every non-owner caller is rejected, since lengthening the delay holds
    /// pending deposits.
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
    /// `fbps` is part of the digest at submit, so only the quoted rate cancels
    /// the escrow, regardless of the registry's current rate.
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
                _feeNote(FEE_IN, ASSET_ID, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
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
                _feeNote(FEE_IN, ASSET_ID, FEE_CM, FEE_CV_DEP_X, FEE_CV_DEP_Y)
            ),
            "submit-time rate still settles"
        );
    }
}
