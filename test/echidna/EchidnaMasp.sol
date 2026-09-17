// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { EchidnaMaspAdversarial } from "./EchidnaMaspAdversarial.sol";

/// Echidna target for the MASP deposit / flush / cancel / sweep state machine.
///
/// Covers the same subject as `test/invariant/MASPPendingFee.invariant.t.sol`
/// and `test/invariant/MASP.flow.invariant.t.sol` with a different engine.
/// Foundry's invariant runner samples fresh call sequences each run; Echidna
/// mutates a corpus it keeps on disk across runs (`corpusDir`, emitted per
/// contract by `just _echidna-config`), so sequences that reached deep states
/// remain available as mutation bases. The properties restate the Foundry
/// ones; the persistent corpus is what this target adds.
///
/// Differences from the Foundry handlers, required by hevm's smaller cheatcode
/// set:
///
///  - The tree-update verifier is `MockTreeUpdateVerifier`, a real contract,
///    where the Foundry suites use `vm.mockCall`. hevm has no `mockCall`.
///  - The payer is `EchidnaMaspPayer`, a deployed contract that originates its
///    own calls, where the Foundry suites `vm.etch` a stub and `vm.prank` it.
///  - Block advancement comes from Echidna's per-call block delay rather than
///    a `vm.roll` past `cancelDelay`. The Foundry handlers roll past the delay
///    unconditionally, so every cancel succeeds and the `cancelDelay` guard is
///    never exercised; here the guard is live and Echidna must find the
///    timing. `maxBlockDelay` in `echidna.yaml` is sized against
///    `CANCEL_DELAY_DEFAULT` (7_200 blocks) to make that reachable.
///
/// Ghost bookkeeping is updated only after the pool call returns. A reverting
/// handler call rolls the whole transaction back, ghosts included, so a
/// rejected deposit or an early cancel cannot desynchronise the shadow state.
///
/// The target is split across an inheritance chain for size; the deployed
/// contract and its ABI are this one:
///
///  - `EchidnaMaspBase` — constants, ghost state, constructor, shared helpers.
///  - `EchidnaMaspHandlers` — escrow, withdraw, root-ring and pause handlers.
///  - `EchidnaMaspAdversarial` — negative-space handlers.
///  - `EchidnaMasp` (this file) — properties and optimization targets.
contract EchidnaMasp is EchidnaMaspAdversarial {
    // -----------------------------------------------------------------------
    // Bookkeeping
    //
    // Mirrors test/invariant/: the pool's ledger checked against a shadow the
    // handlers maintain.
    // -----------------------------------------------------------------------

    /// Solvency: the pool holds every still-escrowed total, every flushed
    /// principal not yet withdrawn (including relayer notes), and the fee
    /// claimable by sweep, and nothing else. Neither sweep nor a withdrawal can
    /// reach escrowed funds.
    ///
    /// A withdrawal removes `outAmt` from shielded principal but only `net`
    /// from the balance; the fee stays in `accruedFee`. Both sides move by
    /// `net`.
    function echidna_solvency() public view returns (bool) {
        return token.balanceOf(address(masp))
            == ghostPendingTotal + _shieldedAvailable() + masp.accruedFee(IERC20(address(token)));
    }

    /// Fee accrual is fully accounted: `accruedFee` moves only where the ghost
    /// says it does — up at flush by the deposit's submit-time fee, up at
    /// withdraw by the unshield fee, and to zero at sweep.
    ///
    /// Submit and cancel never accrue: escrowed fees are not yet earned and
    /// must stay refundable. An accrual on either path appears as ghost
    /// divergence.
    function echidna_feeAccrualAccounted() public view returns (bool) {
        return masp.accruedFee(IERC20(address(token))) == ghostAccrued;
    }

    /// Root coherence: the live root is the last one a root-advancing call
    /// wrote, it is inside the known-roots ring, and the committed leaf count
    /// equals the leaves inserted by flushes (two per deposit) and spends.
    function echidna_rootCoherence() public view returns (bool) {
        return masp.currentRoot() == ghostLastRoot && masp.isKnownRoot(masp.currentRoot())
            && masp.committedCount() == ghostInserted;
    }

    /// Lifecycle exclusivity: every submitted id sits in exactly one of
    /// {Pending, Flushed, Cancelled}, and the terminal buckets match the
    /// counters incremented at the call sites that filled them.
    function echidna_lifecycleExclusivity() public view returns (bool) {
        uint256 n = allIds.length;
        uint256 pending;
        uint256 flushed;
        uint256 cancelled;
        for (uint256 i = 0; i < n; i++) {
            Status s = status[allIds[i]];
            if (s == Status.Pending) pending++;
            else if (s == Status.Flushed) flushed++;
            else if (s == Status.Cancelled) cancelled++;
            else return false; // Unknown after submit
        }
        return pending + flushed + cancelled == n && flushCount == flushed && cancelCount == cancelled;
    }

    /// Escrow storage agrees with the lifecycle ghost: `escrowed[id]` is
    /// non-zero for exactly the ids this handler believes are pending.
    ///
    /// Compares per-deposit storage, not balances, against the ghost. Catches
    /// a drain that moved funds without clearing the slot (leaving it
    /// replayable) or a clear that did not move funds (stranding them);
    /// neither appears as a balance discrepancy on its own.
    function echidna_escrowMatchesLifecycle() public view returns (bool) {
        uint256 n = allIds.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = allIds[i];
            if ((masp.escrowed(id) != bytes32(0)) != (status[id] == Status.Pending)) return false;
        }
        return true;
    }

    /// Conservation across the pool boundary: every token that has left the
    /// pool via `sweep` is sitting in the treasury, and nothing else ever
    /// reached it.
    ///
    /// `echidna_solvency` sees only the pool's side, so a sweep that moved more
    /// than `accruedFee`, or moved it elsewhere, passes it if the pool's
    /// arithmetic is self-consistent. This checks the receiving end.
    function echidna_treasuryConservation() public view returns (bool) {
        return token.balanceOf(address(0xfee)) == ghostSwept;
    }

    // -----------------------------------------------------------------------
    // Guards
    //
    // Negative space: calls the pool must refuse are refused.
    // -----------------------------------------------------------------------

    /// The escrow digest binds every field it commits to: no `cancelDeposit`
    /// with a corrupted preimage is accepted.
    function echidna_cancelDigestBinds() public view returns (bool) {
        return !cancelDigestBreached;
    }

    /// The same binding on the flush leg, which rebuilds the digest from the
    /// batch rather than from call arguments.
    function echidna_flushDigestBinds() public view returns (bool) {
        return !flushDigestBreached;
    }

    /// No deposit is cancelled before `cancelDelay` elapses.
    function echidna_cancelDelayEnforced() public view returns (bool) {
        return !earlyCancelAccepted;
    }

    /// No deposit is drained twice.
    function echidna_noDoubleDrain() public view returns (bool) {
        return !doubleDrainAccepted;
    }

    /// A contract payer's deposit is never cancelled by anyone else.
    function echidna_payerGuardEnforced() public view returns (bool) {
        return !payerGuardBreached;
    }

    /// No `flushBatch` naming the same deposit twice is accepted.
    function echidna_noDuplicateIdInBatch() public view returns (bool) {
        return !duplicateIdAccepted;
    }

    // -----------------------------------------------------------------------
    // Withdraw and transfer
    //
    // The legs that move funds out of the pool, and the one that must not.
    // -----------------------------------------------------------------------

    /// No nullifier is consumed twice through `withdraw`: the double-spend
    /// guard on the real entrypoint rather than on `NullifierSet` in isolation.
    function echidna_noNullifierReuse() public view returns (bool) {
        return !nullifierReuseAccepted;
    }

    /// No withdrawal is accepted against a root the pool never committed.
    function echidna_unknownRootRejected() public view returns (bool) {
        return !unknownRootAccepted;
    }

    /// Every nullifier consumed by a landed spend (withdraw or transfer) still
    /// reads as spent.
    ///
    /// The bitmap packs 256 nullifiers per slot, so a write that clobbered its
    /// neighbours would retire one note and un-retire another. Checking the
    /// whole set on every call detects that.
    function echidna_spentNullifiersStaySpent() public view returns (bool) {
        uint256 n = spentNullifiers.length;
        for (uint256 i = 0; i < n; i++) {
            if (!masp.spent(spentNullifiers[i])) return false;
        }
        return true;
    }

    /// The unshield fee split is exact: net plus fee is the gross, to the wei.
    ///
    /// `_unshieldLeg` computes `fee = outAmt * bps / 10_000` and sends
    /// `outAmt - fee`; any unaccounted wei left shielded principal without
    /// reaching the recipient or the accrued fee. Summed across all
    /// withdrawals, so a residue at particular amounts still appears.
    function echidna_withdrawFeeSplitExact() public view returns (bool) {
        return ghostWithdrawnNet + ghostWithdrawFees == ghostWithdrawnGross;
    }

    /// The recipient holds exactly the net of every withdrawal, and nothing
    /// else.
    ///
    /// The pool-side view cannot distinguish a correctly sized transfer to the
    /// wrong address from a correct one; this checks the receiving end.
    function echidna_recipientCredited() public view returns (bool) {
        return token.balanceOf(RECIPIENT) == ghostWithdrawnNet;
    }

    /// A shielded transfer never changes the pool's token balance.
    ///
    /// Checked inside the handler across the single call rather than as a
    /// standing sum, because other handlers move the balance; only a per-call
    /// comparison attributes a movement to `transfer`.
    function echidna_transferMovesNoTokens() public view returns (bool) {
        return !transferMovedTokens;
    }

    // -----------------------------------------------------------------------
    // Root ring and pause
    //
    // Root eviction and the guardian pause.
    // -----------------------------------------------------------------------

    /// Every root the ring buffer holds reads as known, and `rootIndexOf`
    /// names a slot holding it (the index a relayer passes as `anchorIndex`).
    /// Work is bounded by `ROOT_HISTORY` slots.
    function echidna_rootRingConsistent() public view returns (bool) {
        for (uint256 j = 0; j < ROOT_HISTORY; j++) {
            bytes32 r = masp.roots(j);
            if (r == bytes32(0)) continue;
            (bool found, uint256 index) = masp.rootIndexOf(r);
            if (!found || masp.roots(index) != r || !masp.isKnownRoot(r)) return false;
        }
        return true;
    }

    /// No root the ring has evicted still reads as known.
    ///
    /// A root still found after eviction would let a relayer anchor a spend to
    /// a tree state the pool has forgotten.
    function echidna_evictedRootsUnknown() public view returns (bool) {
        uint256 tracked = evictedCount < EVICTED_TRACKED ? evictedCount : EVICTED_TRACKED;
        for (uint256 i = 0; i < tracked; i++) {
            if (masp.isKnownRoot(evictedRoots[i])) return false;
        }
        return true;
    }

    /// No withdrawal against an evicted root is accepted.
    function echidna_evictedRootRejected() public view returns (bool) {
        return !evictedRootAccepted;
    }

    /// A pause stops the pool taking on new obligations.
    function echidna_pauseBlocksDeposits() public view returns (bool) {
        return !pausedDepositAccepted;
    }

    /// A pause stops the pool settling spends.
    function echidna_pauseBlocksSpends() public view returns (bool) {
        return !pausedSpendAccepted;
    }

    /// A pause never traps escrowed funds: a cancel past its delay is still
    /// honoured while the pool is paused.
    ///
    /// `cancelDeposit` and `sweep` are excluded from `whenNotPaused`. If
    /// `cancelDeposit` were paused, an admin could freeze depositors' funds for
    /// the length of a pause.
    function echidna_pauseCannotTrapFunds() public view returns (bool) {
        return !pausedCancelRejected;
    }

    // -----------------------------------------------------------------------
    // Optimization targets
    //
    // Used only under `testMode: optimization` (`just echidna-optimize`), where
    // Echidna maximises the returned value. The properties above check whether
    // an invariant breaks; these measure how far it drifts, which separates a
    // bounded rounding residue from a leak that grows with volume. Both are
    // expected to report 0.
    // -----------------------------------------------------------------------

    /// Largest shortfall between what the pool owes and what it holds.
    ///
    /// Signed; positive means insolvent (the pool cannot cover escrowed
    /// deposits, shielded principal and claimable fees). `echidna_solvency`
    /// fails on any non-zero deviation; this value measures the magnitude.
    function optimize_solvencyDeficit() public view returns (int256) {
        uint256 owed = ghostPendingTotal + _shieldedAvailable() + masp.accruedFee(IERC20(address(token)));
        return int256(owed) - int256(token.balanceOf(address(masp)));
    }

    /// Largest divergence, either direction, between the pool's `accruedFee`
    /// and the value implied by the flush/withdraw/sweep history.
    ///
    /// Absolute deviation: over-accrual takes fees from funds still refundable
    /// to a depositor and under-accrual strands them in the pool, so neither
    /// direction is benign.
    function optimize_feeAccrualDrift() public view returns (int256) {
        uint256 actual = masp.accruedFee(IERC20(address(token)));
        uint256 delta = actual > ghostAccrued ? actual - ghostAccrued : ghostAccrued - actual;
        return int256(delta);
    }
}
