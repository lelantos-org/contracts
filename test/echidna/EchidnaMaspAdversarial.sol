// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { EchidnaRoots } from "./EchidnaRoots.sol";
import { EchidnaMaspHandlers } from "./EchidnaMaspHandlers.sol";

/// Negative-space handlers for `EchidnaMasp`: calls the pool must reject.
abstract contract EchidnaMaspAdversarial is EchidnaMaspHandlers {
    // -----------------------------------------------------------------------
    // Negative-space handlers
    //
    // The handlers in `EchidnaMaspHandlers` drive the pool as an honest caller
    // and so only confirm that correct input is accepted. These make calls the
    // pool must reject and record any that succeed. The Foundry handlers always
    // supply a correct preimage, so across sequences the digest binding, the
    // payer restriction and the drain-once rule are covered only here.
    //
    // Each handler swallows the revert it expects. This is safe because the
    // calls must have no effect: if one succeeds, its state change lands, the
    // ghosts go stale, and the bookkeeping properties fail alongside the
    // specific flag.
    // -----------------------------------------------------------------------

    /// Derive a non-zero XOR mask, so the corrupted digest field is guaranteed
    /// to differ from the original.
    ///
    /// A fuzzer-chosen replacement could equal the original and be correctly
    /// accepted, then recorded as a breach. `| 1` keeps the mask non-zero under
    /// truncation to any width, so the difference survives the cast to
    /// uint16/uint32/uint48.
    function _mask(uint256 mutation) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(mutation))) | 1;
    }

    /// Attempt `cancelDeposit` with exactly one digest field corrupted.
    ///
    /// Every field folded into `_depositDigest` is reachable through
    /// `fieldSeed`, so this checks the whole binding. A success means a caller
    /// can cancel a deposit on terms other than those it was escrowed under:
    /// a different amount, asset, payer, or note (`inner`, `feeInner`).
    ///
    /// Skipped while the deposit is inside its cancel window, where
    /// `CancelTooEarly` rejects the call even if the digest check passes, so a
    /// rejection could not be attributed to the digest. `cancelTooEarly` covers
    /// that guard.
    function cancelTampered(uint256 idxSeed, uint8 fieldSeed, uint256 mutation) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;
        if (block.number < uint256(preimageSubmittedAt[id]) + masp.cancelDelay()) return;

        uint256 m = _mask(mutation);

        // Honest values; exactly one is overwritten below.
        uint48 publicIn = preimagePublicIn[id];
        bytes32 inner = preimageInner[id];
        uint64 assetId = ASSET_ID;
        uint16 fbps = FEE_BPS;
        address who = address(payer);
        uint32 submittedAt = preimageSubmittedAt[id];
        uint48 feeIn = uint48(relayerFeeIn[id]);
        bytes32 feeInner = FEE_INNER;
        uint64 feeAssetId = feeIn == 0 ? 0 : ASSET_ID;
        // The refund cap: zero, as the asset is plain.
        uint256 pulled;

        // One arm per caller-supplied word of the digest preimage: ten.
        uint8 field = uint8(fieldSeed % 10);
        if (field == 0) inner = bytes32(uint256(inner) ^ m);
        else if (field == 1) assetId = uint64(uint64(assetId) ^ uint64(m));
        else if (field == 2) publicIn = uint48(uint48(publicIn) ^ uint48(m));
        else if (field == 3) fbps = uint16(uint16(fbps) ^ uint16(m));
        else if (field == 4) who = address(uint160(uint160(who) ^ uint160(m)));
        else if (field == 5) submittedAt = uint32(uint32(submittedAt) ^ uint32(m));
        else if (field == 6) feeIn = uint48(uint48(feeIn) ^ uint48(m));
        else if (field == 7) feeInner = bytes32(uint256(feeInner) ^ m);
        else if (field == 8) feeAssetId = uint64(feeAssetId ^ uint64(m));
        else pulled ^= m;

        cancelTamperAttempts += 1;
        try payer.exec(
            address(masp),
            abi.encodeCall(
                MASP.cancelDeposit,
                (
                    id,
                    publicIn,
                    inner,
                    assetId,
                    fbps,
                    who,
                    submittedAt,
                    PubInputs.FeeNote({ feeIn: feeIn, feeAssetId: feeAssetId, feeInner: feeInner }),
                    pulled
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
    /// success means a flusher can mint a leaf for a deposit escrowed on
    /// different terms: the circuit builds each deposit leaf from the slot's
    /// `(leafAsset, leafPublicIn, cms)`, so a tampered word that got through
    /// would be hashed into the tree.
    function flushTampered(uint256 idxSeed, uint8 fieldSeed, uint256 mutation) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;

        uint256 m = _mask(mutation);
        uint8 field = uint8(fieldSeed % 9);

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = EchidnaRoots.fresh(abi.encode("tampered", id, block.number));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        // The honest leaves; exactly one field is overwritten below.
        _fillDepositLeaves(tpi, 0, id);

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = _meta(id);

        if (field == 0) tpi.cms[0] = bytes32(uint256(tpi.cms[0]) ^ m);
        else if (field == 1) tpi.leafPublicIn[0] = uint64(uint48(uint48(tpi.leafPublicIn[0]) ^ uint48(m)));
        else if (field == 2) tpi.leafAsset[0] = uint64(tpi.leafAsset[0] ^ uint64(m));
        else if (field == 3) tpi.cms[1] = bytes32(uint256(tpi.cms[1]) ^ m);
        else if (field == 4) tpi.leafPublicIn[1] = uint64(uint48(uint48(tpi.leafPublicIn[1]) ^ uint48(m)));
        else if (field == 5) meta[0].payer = address(uint160(uint160(meta[0].payer) ^ uint160(m)));
        // The fee leaf's asset: bound only through the digest's `feeAssetId`.
        else if (field == 6) tpi.leafAsset[1] = uint64(tpi.leafAsset[1] ^ uint64(m));
        else if (field == 7) meta[0].fbps = uint16(uint16(meta[0].fbps) ^ uint16(m));
        // The refund cap: a flush never applies it, but the digest binds it.
        else meta[0].pulled ^= m;

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

        earlyCancelAttempts += 1;
        try payer.exec(address(masp), _honestCancelCalldata(id)) returns (bytes memory) {
            earlyCancelAccepted = true;
        } catch { }
    }

    /// Attempt to cancel a deposit that has already been flushed or cancelled.
    ///
    /// Both paths clear `escrowed[id]`, and zero means "nothing pending", so
    /// this checks the replay guard against a double refund or a refund of a
    /// deposit already committed.
    function drainTwice(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Flushed);
        if (status[id] != Status.Flushed) {
            id = _firstWithStatus(idxSeed, Status.Cancelled);
            if (status[id] != Status.Cancelled) return;
        }

        doubleDrainAttempts += 1;
        try payer.exec(address(masp), _honestCancelCalldata(id)) returns (bytes memory) {
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

        strangerCancelAttempts += 1;
        (bool ok,) = address(masp).call(_honestCancelCalldata(id));
        if (ok) payerGuardBreached = true;
    }

    /// Attempt a `transfer` whose request names an asset.
    ///
    /// The request is `transferShielded`'s, which lands, with `publicAssetId`
    /// alone changed, so only `MustNotNameAsset` can reject it. Both a
    /// registered id and an unregistered one are tried: the guard is on the
    /// word being non-zero, not on the registry, which a transfer never reads.
    /// The spend verifier is stubbed to accept, so nothing after the guard
    /// would stop the call.
    function transferNamingAsset(uint64 assetSeed, uint256 cmSeed) public {
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _spendRequest(0, _nextNullifierSeed(), cmSeed);
        // Even seeds name the registered asset; odd ones are already non-zero.
        pi.publicAssetId = assetSeed % 2 == 0 ? ASSET_ID : assetSeed;

        MASP.Proof memory p;
        MASP.Proof memory tp;
        namedAssetTransferAttempts += 1;
        try masp.transfer(p, pi, tp, tpi, SpendFixture.validAux()) {
            namedAssetTransferAccepted = true;
        } catch { }
    }
}
