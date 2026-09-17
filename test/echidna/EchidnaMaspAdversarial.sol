// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { EchidnaRoots } from "./EchidnaRoots.sol";
import { EchidnaMaspHandlers } from "./EchidnaMaspHandlers.sol";

/// Negative-space handlers for `EchidnaMasp`: calls the pool must reject.
abstract contract EchidnaMaspAdversarial is EchidnaMaspHandlers {
    // -----------------------------------------------------------------------
    // Negative-space handlers
    //
    // The handlers above drive the pool as an honest caller and so only
    // confirm that correct input is accepted. These make calls the pool must
    // reject and record any that succeed. The Foundry handlers always supply a
    // correct preimage, so across sequences the digest binding, the payer
    // restriction and the drain-once rule are covered only here.
    //
    // Each handler swallows the revert it expects. This is safe because the
    // calls must have no effect: if one succeeds, its state change lands, the
    // ghosts go stale, and the bookkeeping properties fail alongside the
    // specific flag.
    // -----------------------------------------------------------------------

    /// Derive a guaranteed-different value for one digest field.
    ///
    /// XOR with a non-zero mask rather than a fuzzer-chosen replacement, which
    /// could equal the original and be correctly accepted, then recorded as a
    /// breach. `| 1` keeps the mask non-zero under truncation to any width, so
    /// the difference survives the cast to uint16/uint32/uint48.
    function _mask(uint256 mutation) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(mutation))) | 1;
    }

    /// Attempt `cancelDeposit` with exactly one digest field corrupted.
    ///
    /// Every field folded into `_depositDigest` is reachable through
    /// `fieldSeed`, so this checks the whole binding. A success means a caller
    /// can cancel a deposit on terms other than those it was escrowed under:
    /// a different amount, asset, or payer.
    ///
    /// Skipped while the deposit is inside its cancel window, where the call
    /// reverts `CancelTooEarly` before the digest is compared. `cancelTooEarly`
    /// covers that guard.
    function cancelTampered(uint256 idxSeed, uint8 fieldSeed, uint256 mutation) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;
        if (block.number < uint256(preimageSubmittedAt[id]) + masp.cancelDelay()) return;

        uint256 m = _mask(mutation);
        uint256[2] memory cv;
        uint256[2] memory feeCv;

        // Honest values; exactly one is overwritten below.
        uint48 publicIn = preimagePublicIn[id];
        bytes32 cm = preimageCm0[id];
        uint64 assetId = ASSET_ID;
        uint16 fbps = FEE_BPS;
        address who = address(payer);
        uint32 submittedAt = preimageSubmittedAt[id];
        uint48 feeIn = uint48(relayerFeeIn[id]);
        bytes32 feeCm = bytes32(uint256(0xfee));
        uint64 feeAssetId = feeIn == 0 ? 0 : ASSET_ID;

        uint8 field = uint8(fieldSeed % 11);
        if (field == 0) cm = bytes32(uint256(cm) ^ m);
        else if (field == 1) cv[0] ^= m;
        else if (field == 2) assetId = uint64(uint64(assetId) ^ uint64(m));
        else if (field == 3) publicIn = uint48(uint48(publicIn) ^ uint48(m));
        else if (field == 4) fbps = uint16(uint16(fbps) ^ uint16(m));
        else if (field == 5) who = address(uint160(uint160(who) ^ uint160(m)));
        else if (field == 6) submittedAt = uint32(uint32(submittedAt) ^ uint32(m));
        else if (field == 7) feeIn = uint48(uint48(feeIn) ^ uint48(m));
        else if (field == 8) feeCm = bytes32(uint256(feeCm) ^ m);
        else if (field == 9) feeAssetId = uint64(feeAssetId ^ uint64(m));
        else feeCv[0] ^= m;

        cancelTamperAttempts += 1;
        try payer.exec(
            address(masp),
            abi.encodeCall(
                MASP.cancelDeposit,
                (
                    id,
                    publicIn,
                    cm,
                    cv,
                    assetId,
                    fbps,
                    who,
                    submittedAt,
                    PubInputs.FeeNote({ feeIn: feeIn, feeAssetId: feeAssetId, feeCm: feeCm, feeCvDep: feeCv })
                )
            )
        ) returns (
            bytes memory
        ) {
            cancelDigestBreached = true;
        } catch { }
    }

    /// Attempt `flushBatch` with one field of the escrow preimage corrupted.
    ///
    /// The flush leg rebuilds the same digest from `tpi` plus `DepositMeta`
    /// rather than from call arguments, an independent reconstruction. A
    /// success means a flusher can mint a commitment for a deposit escrowed on
    /// different terms.
    function flushTampered(uint256 idxSeed, uint8 fieldSeed, uint256 mutation) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;

        uint256 m = _mask(mutation);
        uint8 field = uint8(fieldSeed % 8);

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = EchidnaRoots.fresh(abi.encode("tampered", id, block.number));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        tpi.cms[0] = preimageCm0[id];
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafPublicIn[0] = uint64(preimagePublicIn[id]);
        tpi.isDeposit[0] = 1;
        tpi.cms[1] = bytes32(uint256(0xfee));
        // Zero-value leaves declare asset 0: `tree_update_batch.circom` step 6a
        // canonicalises the asset of a leaf whose Pedersen binding cannot see
        // it, and `_drainDeposit` requires the match.
        tpi.leafAsset[1] = relayerFeeIn[id] == 0 ? 0 : ASSET_ID;
        tpi.leafPublicIn[1] = relayerFeeIn[id];
        tpi.isDeposit[1] = 1;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: address(payer), submittedAt: preimageSubmittedAt[id], fbps: FEE_BPS });

        if (field == 0) tpi.cms[0] = bytes32(uint256(tpi.cms[0]) ^ m);
        else if (field == 1) tpi.leafPublicIn[0] = uint64(uint48(uint48(tpi.leafPublicIn[0]) ^ uint48(m)));
        else if (field == 2) tpi.leafAsset[0] = uint64(tpi.leafAsset[0] ^ uint64(m));
        else if (field == 3) tpi.cms[1] = bytes32(uint256(tpi.cms[1]) ^ m);
        else if (field == 4) tpi.leafPublicIn[1] = uint64(uint48(uint48(tpi.leafPublicIn[1]) ^ uint48(m)));
        else if (field == 5) meta[0].payer = address(uint160(uint160(meta[0].payer) ^ uint160(m)));
        // The fee leaf's asset: bound only through the digest's `feeAssetId`.
        else if (field == 6) tpi.leafAsset[1] = uint64(tpi.leafAsset[1] ^ uint64(m));
        else meta[0].fbps = uint16(uint16(meta[0].fbps) ^ uint16(m));

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        MASP.Proof memory proof;

        flushTamperAttempts += 1;
        try masp.flushBatch(ids, meta, proof, tpi) {
            flushDigestBreached = true;
        } catch { }
    }

    /// Attempt an honest `cancelDeposit` before the delay has elapsed.
    ///
    /// The preimage is correct, so only the timing guard can reject this.
    /// `cancelOne` shows a cancel eventually succeeds; this shows it cannot
    /// succeed early, which protects the flusher's window.
    function cancelTooEarly(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;
        if (block.number >= uint256(preimageSubmittedAt[id]) + masp.cancelDelay()) return;

        uint256[2] memory zCv;
        earlyCancelAttempts += 1;
        try payer.exec(address(masp), _honestCancelCalldata(id, zCv)) returns (bytes memory) {
            earlyCancelAccepted = true;
        } catch { }
    }

    /// Attempt to drain a deposit that has already been flushed or cancelled.
    ///
    /// Both paths clear `escrowed[id]`, and zero means "nothing pending", so
    /// this checks the replay guard against a double refund or a second
    /// commitment from one deposit.
    function drainTwice(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Flushed);
        if (status[id] != Status.Flushed) {
            id = _firstWithStatus(idxSeed, Status.Cancelled);
            if (status[id] != Status.Cancelled) return;
        }

        uint256[2] memory zCv;
        doubleDrainAttempts += 1;
        try payer.exec(address(masp), _honestCancelCalldata(id, zCv)) returns (bytes memory) {
            doubleDrainAccepted = true;
        } catch { }
    }

    /// Attempt an honest `cancelDeposit` sent by someone other than the payer.
    ///
    /// The payer is a contract, and MASP restricts cancellation to the payer
    /// itself whenever `payer.code.length != 0`: a contract payer must observe
    /// its refund arriving, because a refund delivered by a third-party call is
    /// indistinguishable on-chain from a flush and would strand the funder's
    /// claim. This handler calls the pool directly rather than through
    /// `payer.exec`.
    function cancelAsStranger(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;
        if (block.number < uint256(preimageSubmittedAt[id]) + masp.cancelDelay()) return;

        uint256[2] memory zCv;
        strangerCancelAttempts += 1;
        (bool ok,) = address(masp).call(_honestCancelCalldata(id, zCv));
        if (ok) payerGuardBreached = true;
    }

    /// The correct cancel preimage for `id`. Used by handlers testing a guard
    /// other than the digest, so a rejection can only come from that guard.
    function _honestCancelCalldata(uint256 id, uint256[2] memory zCv) internal view returns (bytes memory) {
        return abi.encodeCall(
            MASP.cancelDeposit,
            (
                id,
                preimagePublicIn[id],
                preimageCm0[id],
                zCv,
                ASSET_ID,
                FEE_BPS,
                address(payer),
                preimageSubmittedAt[id],
                PubInputs.FeeNote({
                    feeIn: uint48(relayerFeeIn[id]),
                    feeAssetId: relayerFeeIn[id] == 0 ? 0 : ASSET_ID,
                    feeCm: bytes32(uint256(0xfee)),
                    feeCvDep: zCv
                })
            )
        );
    }
}
