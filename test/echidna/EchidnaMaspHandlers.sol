// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { EchidnaRoots } from "./EchidnaRoots.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { EchidnaMaspBase } from "./EchidnaMaspBase.sol";

/// Honest handlers for `EchidnaMasp`: escrow (submit, flush, cancel, sweep),
/// the withdraw leg, the root ring, and the guardian pause.
abstract contract EchidnaMaspHandlers is EchidnaMaspBase {
    // -----------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------

    /// Submit a fresh deposit.
    ///
    /// `feeIn` is forced non-zero: a zero-value relayer note has no tokens
    /// behind it, so solvency would hold under any accounting of the split.
    function submit(uint64 publicInSeed, uint64 feeInSeed) public {
        uint64 publicIn = uint64(1 + (publicInSeed % 1_000));
        uint64 feeIn = uint64(1 + (feeInSeed % 100));

        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;
        uint256 relayerFee = uint256(feeIn) * SCALE;
        token.mint(address(payer), inAmt + fee + relayerFee);

        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = address(payer);
        d.recipient = address(0xb0b);
        d.outCm = bytes32(uint256(0x1000 + nonce));
        d.feeCm = bytes32(uint256(0xfee));
        d.feeIn = feeIn;
        d.feeAssetId = ASSET_ID;

        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: nonce++, deadline: type(uint256).max, maxTotal: type(uint256).max, maxFee: 0, signature: hex"00"
        });

        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        uint256 id = masp.deposit(d, sig, aux[0], aux[1]);

        allIds.push(id);
        status[id] = Status.Pending;
        principalAt[id] = inAmt;
        feeAt[id] = fee;
        relayerFeeAt[id] = relayerFee;
        relayerFeeIn[id] = feeIn;
        preimagePublicIn[id] = uint48(publicIn);
        preimageCm0[id] = d.outCm;
        preimageSubmittedAt[id] = uint32(block.number);
        ghostPendingTotal += inAmt + fee + relayerFee;
        submitCount += 1;
    }

    /// Flush one pending deposit through `flushBatch`.
    function flushOne(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        // Unconstrained (the SNARK is stubbed) but derived from live state, so
        // each flush publishes a distinct root. `EchidnaRoots.fresh` documents
        // the required field reduction.
        tpi.newRoot = EchidnaRoots.fresh(abi.encode("flushed", id, block.number));
        tpi.startIndex = masp.committedCount();
        // A deposit occupies LEAVES_PER_DEPOSIT (= 2) adjacent leaves: the
        // principal, then the note paying the flusher. `_validateBatchHeader`
        // requires `actualCount == n * LEAVES_PER_DEPOSIT` (else
        // `BatchMisaligned`) and `_drainDeposit` rebuilds the escrow digest
        // from leaf `p + 1`, so both leaves must be populated.
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        _fillDepositLeaves(tpi, 0, id);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: address(payer), submittedAt: preimageSubmittedAt[id], fbps: FEE_BPS });

        MASP.Proof memory proof;
        bytes32 willEvict = _pendingEviction();
        masp.flushBatch(ids, meta, proof, tpi);

        _recordEviction(willEvict, tpi.newRoot);
        _recordFlushed(id);
        ghostLastRoot = tpi.newRoot;
        ghostInserted += uint64(PubInputs.LEAVES_PER_DEPOSIT);
        flushCount += 1;
    }

    /// Cancel one pending deposit, refunding the payer.
    ///
    /// Does not roll past `cancelDelay`: the timing guard stays live, so an
    /// early call reverts and only cancels after the delay are counted.
    function cancelOne(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;
        _cancel(id);
    }

    /// The cancel itself, shared by `cancelOne` and `cancelAt` so the two
    /// cannot drift.
    function _cancel(uint256 id) internal {
        uint256[2] memory zCv;
        payer.exec(
            address(masp),
            abi.encodeCall(
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
            )
        );

        status[id] = Status.Cancelled;
        ghostPendingTotal -= principalAt[id] + feeAt[id] + relayerFeeAt[id];
        cancelCount += 1;
    }

    /// `cancelOne` for a caller that has already chosen the deposit.
    ///
    /// Public so `pausedCancelHonoured` can wrap it in try/catch, and by id so
    /// the deposit that caller verified is the one cancelled. `cancelOne`'s
    /// scan could select a different deposit and turn an unrelated rejection
    /// into a false trapped-refund report.
    function cancelAt(uint256 id) public {
        if (status[id] != Status.Pending) return;
        _cancel(id);
    }

    /// Drain accrued fees to the treasury.
    function sweep() public {
        uint256 before = masp.accruedFee(IERC20(address(token)));
        masp.sweep(IERC20(address(token)));
        ghostAccrued = 0;
        ghostSwept += before;
    }

    /// Write deposit `id`'s pair of leaves into batch slot `slot`.
    ///
    /// Deposit `i` owns leaves `2i` (principal) and `2i + 1` (the note paying
    /// the flusher), and `_drainDeposit` rebuilds the escrow digest from both.
    /// Shared so single- and multi-deposit batches are assembled identically.
    function _fillDepositLeaves(PubInputs.TreeUpdateBatch memory tpi, uint256 slot, uint256 id) internal view {
        uint256 pIdx = slot * PubInputs.LEAVES_PER_DEPOSIT;
        tpi.cms[pIdx] = preimageCm0[id];
        tpi.leafAsset[pIdx] = ASSET_ID;
        tpi.leafPublicIn[pIdx] = uint64(preimagePublicIn[id]);
        tpi.isDeposit[pIdx] = 1;
        tpi.cms[pIdx + 1] = bytes32(uint256(0xfee));
        // Zero-value leaves declare asset 0: `tree_update_batch.circom` step 6a
        // canonicalises the asset of a leaf whose Pedersen binding cannot see
        // it, and `_drainDeposit` requires the match.
        tpi.leafAsset[pIdx + 1] = relayerFeeIn[id] == 0 ? 0 : ASSET_ID;
        tpi.leafPublicIn[pIdx + 1] = relayerFeeIn[id];
        tpi.isDeposit[pIdx + 1] = 1;
    }

    /// Header shared by the multi-deposit flush handlers.
    function _batchHeader(uint256 nDeposits, uint256 salt)
        internal
        view
        returns (PubInputs.TreeUpdateBatch memory tpi)
    {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = EchidnaRoots.fresh(abi.encode("batch", salt, block.number));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(nDeposits * PubInputs.LEAVES_PER_DEPOSIT);
    }

    /// Flush two distinct pending deposits in one batch.
    ///
    /// Exercises the `flushBatch` loop at n > 1. Accrual is summed across the
    /// batch and settled once per token, a different code path from two
    /// single-deposit flushes.
    function flushMany(uint256 idxSeed) public {
        uint256 first = _firstWithStatus(idxSeed, Status.Pending);
        if (status[first] != Status.Pending) return;
        uint256 second = _nextPendingAfter(first, idxSeed);
        if (second == first || status[second] != Status.Pending) return;

        PubInputs.TreeUpdateBatch memory tpi = _batchHeader(2, first);
        _fillDepositLeaves(tpi, 0, first);
        _fillDepositLeaves(tpi, 1, second);

        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](2);
        meta[0] = MASP.DepositMeta({ payer: address(payer), submittedAt: preimageSubmittedAt[first], fbps: FEE_BPS });
        meta[1] = MASP.DepositMeta({ payer: address(payer), submittedAt: preimageSubmittedAt[second], fbps: FEE_BPS });

        MASP.Proof memory proof;
        bytes32 willEvict = _pendingEviction();
        masp.flushBatch(ids, meta, proof, tpi);

        _recordEviction(willEvict, tpi.newRoot);
        _recordFlushed(first);
        _recordFlushed(second);
        ghostLastRoot = tpi.newRoot;
        ghostInserted += uint64(2 * PubInputs.LEAVES_PER_DEPOSIT);
        flushCount += 2;
        batchFlushCount += 1;
    }

    /// Attempt a batch that names the same pending deposit twice.
    ///
    /// `_drainDeposit` clears `escrowed[id]` as it goes, and zero means
    /// "nothing pending", so the second slot must find the entry gone.
    /// Accepting it would mint two commitments and pay two relayer notes
    /// against one deposit. This is the drain-once rule within a single
    /// transaction; `drainTwice` covers it across transactions.
    function flushDuplicateId(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;

        PubInputs.TreeUpdateBatch memory tpi = _batchHeader(2, id);
        _fillDepositLeaves(tpi, 0, id);
        _fillDepositLeaves(tpi, 1, id);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](2);
        meta[0] = MASP.DepositMeta({ payer: address(payer), submittedAt: preimageSubmittedAt[id], fbps: FEE_BPS });
        meta[1] = meta[0];

        MASP.Proof memory proof;
        duplicateIdAttempts += 1;
        try masp.flushBatch(ids, meta, proof, tpi) {
            duplicateIdAccepted = true;
            // Keep the ghosts in step with the landed batch so the bookkeeping
            // properties do not fail for an unrelated reason.
            _recordFlushed(id);
            ghostLastRoot = tpi.newRoot;
            ghostInserted += uint64(2 * PubInputs.LEAVES_PER_DEPOSIT);
        } catch { }
    }

    /// Ghost updates for one deposit moving Pending -> Flushed.
    ///
    /// The relayer's note is principal, not an accrual: the pool must keep
    /// holding the tokens behind it or the note is unspendable. Only the
    /// protocol fee moves into `accruedFee`.
    function _recordFlushed(uint256 id) internal {
        status[id] = Status.Flushed;
        ghostPendingTotal -= principalAt[id] + feeAt[id] + relayerFeeAt[id];
        ghostShieldedPrincipal += principalAt[id] + relayerFeeAt[id];
        ghostAccrued += feeAt[id];
    }

    /// First pending id that is not `exclude`.
    function _nextPendingAfter(uint256 exclude, uint256 seed) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return type(uint256).max;
        uint256 start = seed % n;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = allIds[(start + k) % n];
            if (id != exclude && status[id] == Status.Pending) return id;
        }
        return exclude;
    }

    // -----------------------------------------------------------------------
    // Withdraw leg
    //
    // Fuzzes the real spend path (`withdraw`, `transfer`) against a pool whose
    // deposit history is itself fuzzed. The Foundry nullifier invariants drive
    // `MASPHarness.consumeNullifierExternal`, i.e. `NullifierSet` in isolation.
    // -----------------------------------------------------------------------

    /// Build the spend/tree-update pair for a withdrawal of `publicOut`.
    ///
    /// Shared so the spend handlers differ in exactly one field each, making a
    /// rejection attributable to the guard under test.
    function _spendRequest(uint64 publicOut, uint256 nfSeed, uint256 cmSeed)
        internal
        view
        returns (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi)
    {
        pi.merkleRoot = masp.currentRoot();
        pi.publicAssetId = ASSET_ID;
        pi.publicIn = 0; // `withdraw` reverts MustNotHaveDeposit otherwise
        pi.publicOut = publicOut;
        pi.recipient = RECIPIENT;
        pi.chainId = block.chainid;
        pi.payer = address(payer);
        pi.relayer = address(this); // _validateRequest pins relayer == msg.sender
        SpendFixture.fillOutputs(pi, nfSeed, cmSeed);

        tpi = SpendFixture.spendTree(
            EchidnaRoots.fresh(abi.encode("spent", nfSeed, block.number)),
            masp.committedCount(),
            uint8(masp.rootIndex())
        );
    }

    /// Shielded principal still available to withdraw.
    function _shieldedAvailable() internal view returns (uint256) {
        return ghostShieldedPrincipal - ghostWithdrawnGross;
    }

    /// A `publicOut` the pool can actually pay, or 0 when it can pay nothing.
    ///
    /// With the spend verifier stubbed to accept, an unbounded `publicOut`
    /// would drain escrowed deposits and `echidna_solvency` would report an
    /// insolvency caused by the stub rather than by MASP. Every withdrawing
    /// handler uses this bound.
    ///
    /// Zero signals "nothing to withdraw"; a valid amount is at least 1.
    function _boundedPublicOut(uint64 seed) internal view returns (uint64) {
        uint256 maxOut = _shieldedAvailable() / SCALE;
        if (maxOut == 0) return 0;
        if (maxOut > 1_000) maxOut = 1_000;
        return uint64(1 + (seed % maxOut));
    }

    /// The next block of `TRANSACT_IN` never-before-used nullifiers.
    ///
    /// `_validateRequest` rejects a repeat within one call and
    /// `_consumeNullifier` rejects one across calls, so the happy path uses a
    /// supply that is fresh by construction; fuzzer-chosen nullifiers would
    /// make landed spends rare. `withdrawReplay` drives reuse.
    function _nextNullifierSeed() internal returns (uint256 s) {
        s = nullifierCursor;
        nullifierCursor += PubInputs.TRANSACT_IN;
    }

    /// Withdraw shielded funds to `RECIPIENT`.
    ///
    /// Bounded by the shielded principal the ghost knows was deposited; see
    /// `_boundedPublicOut`.
    function withdrawOne(uint64 outSeed, uint256 cmSeed) public {
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) =
            _spendRequest(publicOut, _nextNullifierSeed(), cmSeed);

        uint256 outAmt = uint256(publicOut) * SCALE;
        uint256 fee = (outAmt * FEE_BPS) / 10_000;

        MASP.Proof memory p;
        MASP.Proof memory tp;
        bytes32 willEvict = _pendingEviction();
        masp.withdraw(p, pi, tp, tpi, SpendFixture.validAux());

        _recordEviction(willEvict, tpi.newRoot);

        for (uint256 k = 0; k < PubInputs.TRANSACT_IN; k++) {
            ghostSpent[pi.nullifier[k]] = true;
            spentNullifiers.push(pi.nullifier[k]);
        }
        ghostWithdrawnGross += outAmt;
        ghostWithdrawnNet += outAmt - fee;
        ghostWithdrawFees += fee;
        ghostAccrued += fee;
        ghostLastRoot = tpi.newRoot;
        ghostInserted += uint64(PubInputs.TRANSACT_OUT);
        withdrawCount += 1;
    }

    /// Shielded transfer: consume notes, mint notes, move no tokens.
    ///
    /// `transfer` takes the same proofs and tree update as `withdraw`, runs the
    /// same nullifier consumption and root advance, and must leave
    /// `balanceOf(masp)` unchanged. A per-call balance check attributes any
    /// token movement to this path, which a balance-sum property cannot.
    function transferShielded(uint256 cmSeed) public {
        // publicOut = 0 makes this a transfer; `_spendRequest` sets publicIn
        // to 0.
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _spendRequest(0, _nextNullifierSeed(), cmSeed);

        uint256 balanceBefore = token.balanceOf(address(masp));

        MASP.Proof memory p;
        MASP.Proof memory tp;
        bytes32 willEvict = _pendingEviction();
        masp.transfer(p, pi, tp, tpi, SpendFixture.validAux());

        _recordEviction(willEvict, tpi.newRoot);
        if (token.balanceOf(address(masp)) != balanceBefore) transferMovedTokens = true;

        for (uint256 k = 0; k < PubInputs.TRANSACT_IN; k++) {
            ghostSpent[pi.nullifier[k]] = true;
            spentNullifiers.push(pi.nullifier[k]);
        }
        ghostLastRoot = tpi.newRoot;
        ghostInserted += uint64(PubInputs.TRANSACT_OUT);
        transferCount += 1;
    }

    /// Attempt a withdrawal that reuses a nullifier already consumed.
    ///
    /// Checks the double-spend guard on the real entrypoint, including
    /// everything `withdraw` does before reaching `_consumeNullifier`.
    function withdrawReplay(uint256 nfIdxSeed, uint64 outSeed, uint256 cmSeed) public {
        if (spentNullifiers.length == 0) return;
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) =
            _spendRequest(publicOut, _nextNullifierSeed(), cmSeed);

        // Exactly one slot is swapped for a spent nullifier and the rest stay
        // fresh, so only `DoubleSpend` can reject this, not the within-call
        // `DuplicateNullifier` check.
        pi.nullifier[nfIdxSeed % PubInputs.TRANSACT_IN] = spentNullifiers[nfIdxSeed % spentNullifiers.length];

        MASP.Proof memory p;
        MASP.Proof memory tp;
        nullifierReuseAttempts += 1;
        try masp.withdraw(p, pi, tp, tpi, SpendFixture.validAux()) {
            nullifierReuseAccepted = true;
        } catch { }
    }

    /// Attempt a withdrawal against a Merkle root the pool never committed.
    ///
    /// Root membership ties a spend to state the tree-update circuit produced.
    /// Accepting an unknown root would let a spend prove inclusion in a tree of
    /// the caller's own construction.
    function withdrawUnknownRoot(uint64 outSeed, uint256 cmSeed, uint256 rootSeed) public {
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) =
            _spendRequest(publicOut, _nextNullifierSeed(), cmSeed);

        bytes32 bogus = EchidnaRoots.fresh(abi.encode("unknown-root", rootSeed));
        if (masp.isKnownRoot(bogus)) return; // collision; skip rather than misreport
        pi.merkleRoot = bogus;
        // Any slot, in range or not: none holds the bogus root.
        tpi.anchorIndex = uint8(rootSeed >> 8);

        MASP.Proof memory p;
        MASP.Proof memory tp;
        unknownRootAttempts += 1;
        try masp.withdraw(p, pi, tp, tpi, SpendFixture.validAux()) {
            unknownRootAccepted = true;
        } catch { }
    }

    // -----------------------------------------------------------------------
    // Root ring
    // -----------------------------------------------------------------------

    /// The root the next push will displace, or zero if that slot is empty.
    ///
    /// Read before a root-advancing call so the eviction can be recorded
    /// afterwards. If the displaced entry equals the incoming root, the slot
    /// still holds that root after `CommitmentTree._advanceRoot` overwrites it,
    /// so callers compare against `newRoot` before recording.
    function _pendingEviction() internal view returns (bytes32) {
        uint32 next = uint32((uint256(masp.rootIndex()) + 1) & (ROOT_HISTORY - 1));
        return masp.roots(next);
    }

    /// Record a root the pool has just forgotten.
    ///
    /// Called from every root-advancing handler: both flush paths, withdraw
    /// and transfer. A missed call leaves the property sound but gives
    /// `withdrawEvictedRoot` fewer targets.
    ///
    /// Roots are keccak images reduced into the scalar field, so a root
    /// re-entering the ring after eviction is not handled; if it occurred, the
    /// result would be a false breach rather than a missed one.
    function _recordEviction(bytes32 evicted, bytes32 newRoot) internal {
        if (evicted == bytes32(0) || evicted == newRoot) return;
        evictedRoots[evictedCount % EVICTED_TRACKED] = evicted;
        evictedCount += 1;
    }

    /// Advance the root many times in one call.
    ///
    /// Reachability device. The ring holds 64 roots and evicts nothing until
    /// full, so the eviction properties need 64+ landed root advances within a
    /// single sequence (Echidna resets state between sequences). Spread across
    /// the handler set at `seqLen: 400`, individual advances rarely reach the
    /// wrap; looping brings it within a few calls.
    ///
    /// Uses transfers because they need neither a pending deposit nor shielded
    /// funds, so they do not early-return for reasons unrelated to the ring.
    function churnRoots(uint8 nSeed, uint256 cmSeed) public {
        uint256 n = 1 + (uint256(nSeed) % 16);
        for (uint256 i = 0; i < n; i++) {
            transferShielded(cmSeed + i);
        }
    }

    /// Attempt a withdrawal proving inclusion in a root the ring has evicted.
    ///
    /// Distinct from `withdrawUnknownRoot`, which uses a root that was never
    /// committed. An evicted root was valid pool state, which makes it the
    /// harder case for a stale-root check.
    function withdrawEvictedRoot(uint64 outSeed, uint256 cmSeed, uint256 pickSeed) public {
        if (evictedCount == 0) return;
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        uint256 tracked = evictedCount < EVICTED_TRACKED ? evictedCount : EVICTED_TRACKED;
        bytes32 stale = evictedRoots[pickSeed % tracked];

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) =
            _spendRequest(publicOut, _nextNullifierSeed(), cmSeed);
        pi.merkleRoot = stale;
        // Any slot, including the one the root was evicted from.
        tpi.anchorIndex = uint8(pickSeed >> 8);

        MASP.Proof memory p;
        MASP.Proof memory tp;
        evictedRootAttempts += 1;
        try masp.withdraw(p, pi, tp, tpi, SpendFixture.validAux()) {
            evictedRootAccepted = true;
        } catch { }
    }

    // -----------------------------------------------------------------------
    // Guardian pause
    //
    // `whenNotPaused` guards five entry points (withdraw, transfer, deposit,
    // depositAuthorized, flushBatch) and not `cancelDeposit` or `sweep`, so
    // escrowed funds stay recoverable. Property: a pause stops the pool taking
    // on or settling obligations without trapping funds already in escrow.
    // -----------------------------------------------------------------------

    /// Trip the pause. The proxy itself allows repeats; this handler takes one
    /// per sequence (`pausedUntil != 0` returns early) so a live pause is never
    /// extended mid-sequence and the window below stays the one it sized.
    ///
    /// The duration (60_000s to 199_999s) is sized against `maxTimeDelay`
    /// (15_000s) in `echidna.yaml`: the pause spans several calls, so a block
    /// delay can cross the 7_200-block cancel delay while it is live, as
    /// `pausedCancelHonoured` requires. It stays well under `MAX_PAUSE`
    /// (7 days), which would outlast the sequence and freeze other handlers.
    function pauseSpends(uint32 durSeed) public {
        if (pausedUntil != 0) return;
        // Requires at least two pending deposits. `pausedCancelHonoured` needs
        // a deposit still pending during the pause, but cancels are not
        // blocked, so `cancelOne` and the cancel negative handlers keep
        // draining escrow while `submit` is frozen and cannot replace it.
        if (_countPending() < 2) return;
        uint256 duration = 60_000 + (uint256(durSeed) % 140_000);
        proxy.pauseSpends(duration);
        pausedUntil = block.timestamp + duration;
    }

    /// While paused, a deposit must be refused.
    function pausedDepositRejected(uint64 publicInSeed) public {
        if (block.timestamp >= pausedUntil) return;
        pausedDepositAttempts += 1;
        try this.submit(publicInSeed, 1) {
            pausedDepositAccepted = true;
        } catch { }
    }

    /// While paused, a spend must be refused.
    function pausedSpendRejected(uint256 cmSeed) public {
        if (block.timestamp >= pausedUntil) return;
        if (_shieldedAvailable() < SCALE) return;
        pausedSpendAttempts += 1;
        try this.withdrawOne(1, cmSeed) {
            pausedSpendAccepted = true;
        } catch { }
    }

    /// While paused, a cancel whose delay has elapsed must still be honoured.
    ///
    /// If a pause could block refunds, an admin could hold depositors' escrow
    /// for the length of the pause.
    function pausedCancelHonoured(uint256 idxSeed) public {
        if (block.timestamp >= pausedUntil) return;
        // Scans for a pending deposit that is also past its delay. The first
        // pending deposit is often the newest and still inside its window, so
        // taking it would make this handler rarely reach the pool.
        uint256 id = _firstCancellablePending(idxSeed);
        if (id == type(uint256).max) return;

        pausedCancelAttempts += 1;
        try this.cancelAt(id) { }
        catch {
            pausedCancelRejected = true;
        }
    }

    /// Number of ids still escrowed.
    function _countPending() internal view returns (uint256 n) {
        for (uint256 i = 0; i < allIds.length; i++) {
            if (status[allIds[i]] == Status.Pending) n++;
        }
    }

    /// First pending id whose cancel delay has already elapsed, or
    /// `type(uint256).max` if there is none.
    function _firstCancellablePending(uint256 seed) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return type(uint256).max;
        uint256 delay = masp.cancelDelay();
        uint256 start = seed % n;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = allIds[(start + k) % n];
            if (status[id] == Status.Pending && block.number >= uint256(preimageSubmittedAt[id]) + delay) {
                return id;
            }
        }
        return type(uint256).max;
    }
}
