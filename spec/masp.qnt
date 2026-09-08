// Model of the MASP deposit escrow state machine (src/MASP.sol).
//
// Replayed against a real pool by test/quint/MaspReplay.t.sol.
//
// WHAT THIS MODELS
//
// The lifecycle of one escrowed deposit: `deposit` escrows it, `flushBatch`
// shields it, `cancelDeposit` refunds it after a delay, `sweep` moves accrued
// fees to the treasury. It is the same machine
// `test/invariant/MASP.flow.invariant.t.sol` drives with a fuzzer, written down
// so it can be checked rather than assumed.
//
// That matters here more than usual. The flush half of that invariant suite
// never ran: `flushOne` built a one-leaf batch where `_validateBatchHeader`
// demands two, so every call reverted and `fail_on_revert = false` rolled the
// ghost updates back in silence. A model asserted after *every* step cannot
// have that failure mode - a step that does nothing is a step whose post-state
// does not match.
//
// ABSTRACTED, and why
//
//   - Groth16 validity. The driver `vm.mockCall`-stubs the tree-update verifier,
//     exactly as the invariant suite does. Foundry cannot synthesise a valid
//     depth-11 proof, and what is interesting here is the escrow bookkeeping
//     around a proof, not the proof.
//   - Permit2 and ERC-1271. The driver etches a MockERC1271 onto the payer so
//     any signature passes.
//   - Merkle roots. `committedCount` is modelled because it is the leaf
//     accounting; the root ring is not, because spec/commitment_tree.qnt
//     already models it in isolation and does it properly.
//   - Value commitments, ciphertexts, clue keys. Not state-machine relevant.
//   - Yield assets, the spend path, upgrades, pausing, multi-asset batches and
//     multi-deposit batches. One plain asset, one deposit per flush.
//   - Fee rounding. `_computeAmounts` floors `inAmt * fbps / BPS`, and this
//     model cannot tell that from a ceiling: the asset's scale is 1e10, which
//     divides BPS, so the division is exact for every `publicIn` the model can
//     draw - and for any fee rate, not just this one. Flipping the contract to
//     ceil-div would be invisible here, and equally invisible to
//     test/invariant/, which registers the same scale.
//
//     `test/masp/MASP.fee.t.sol` is where rounding is covered: it registers an
//     asset with `scale = 1`, where the division has a remainder. Left there
//     rather than duplicated here - but stated, because "the model checks the
//     fee arithmetic" would otherwise be a fair and wrong reading of the
//     balance invariants below.
//
//   - Every rejection `_validateDeposit` performs: zero `publicIn`, zero payer,
//     recipient or commitment, wrong chain id, unknown or disabled asset,
//     malformed aux. The driver only ever submits well-formed deposits, so the
//     model has no notion of a rejected submit. The unit suite covers them.
module masp {
  // Must match the driver's constants. `MaspReplay.setUp` asserts the pool
  // agrees on CANCEL_DELAY, so a change to either side fails loudly.
  pure val SCALE = 10000000000        // 1e10
  pure val FEE_BPS = 25
  pure val BPS = 10000
  pure val CANCEL_DELAY_DEFAULT = 7200   // MASP.CANCEL_DELAY_DEFAULT
  pure val CANCEL_DELAY_MIN = 3600       // MASP.CANCEL_DELAY_MIN
  pure val CANCEL_DELAY_MAX = 50400      // MASP.CANCEL_DELAY_MAX

  /// The delays `setCancelDelay` may be moved to. Both ends of the permitted
  /// range plus the default, which is enough to shorten and lengthen.
  pure val DELAY_CHOICES = Set(CANCEL_DELAY_MIN, CANCEL_DELAY_DEFAULT, CANCEL_DELAY_MAX)
  pure val LEAVES_PER_DEP = 2         // PubInputs.LEAVES_PER_DEPOSIT

  /// Bounds the nondet id domain. Ids are dense from 0, so this also bounds how
  /// many deposits a trace can create.
  pure val MAX_DEPOSITS = 6
  pure val MAX_PUBLIC_IN = 1000

  /// Block jumps. A constant set rather than a range because `CANCEL_DELAY`
  /// itself has to be drawable: submitting at `b` and advancing by exactly
  /// `CANCEL_DELAY` puts the clock on the unlock block, which is the boundary
  /// `cancel` and `cancelTooEarly` divide. Drawing from `1.to(7400)` would
  /// reach it with probability 1/7400 and the boundary would go untested.
  /// One jump per delay that can be in force, so the unlock block is reachable
  /// exactly whichever delay `setCancelDelay` last chose, plus small jumps to
  /// land just short of it.
  pure val BLOCK_JUMPS = Set(1, 10, 200, CANCEL_DELAY_MIN, CANCEL_DELAY_DEFAULT, CANCEL_DELAY_MAX)

  type Status = Pending | Flushed | Cancelled

  type Deposit = {
    principal: int,
    fee: int,
    submittedAt: int,
    status: Status,
  }

  var blockNo: int
  var nextId: int
  var deposits: int -> Deposit
  /// token.balanceOf(pool)
  var poolBalance: int
  /// FeeConfig.accruedFee[token] - the treasury's cut, still held by the pool.
  var accruedFee: int
  var treasuryBalance: int
  /// What the payer has been refunded. Every submit mints exactly what the
  /// deposit costs and the pool pulls all of it, so this only ever moves on a
  /// cancel - which makes it a direct check on refund arithmetic.
  var payerBalance: int
  var committedCount: int
  /// MASP.cancelDelay. A live storage value, not a per-deposit one - see
  /// `setCancelDelay` below for why that distinction is the point.
  var cancelDelay: int
  /// AssetRegistry entry's `disabled` flag for the one asset this models.
  var assetDisabled: bool

  /// Ghost. Not compared against the chain - `ignoreState` in the config says
  /// so and why. Incremented whenever a cancel action fires on the wrong side
  /// of the delay, which the guards are supposed to make impossible. Without
  /// it the delay is unconstrained by any invariant: mutation testing showed
  /// that deleting either guard left every invariant satisfied, leaving the
  /// timing rule resting entirely on the replay.
  var guardViolations: int

  /// Ghost. Latches when a deposit is flushed or cancelled while its asset is
  /// disabled. Witnessed below: the property is that disabling stops new
  /// inflow without stranding what is already escrowed, and a witness is what
  /// distinguishes "the traces showed that works" from "the traces never
  /// tried".
  var settledWhileDisabled: bool

  /// Ghost. Latches when a deposit is cancelled at a block the *default* delay
  /// would still have forbidden - only possible if `setCancelDelay` shortened
  /// the window under an escrow already in flight. Witnessed below.
  var cancelledEarlierThanDefault: bool

  pure def feeOf(principal: int): int = (principal * FEE_BPS) / BPS

  def withStatus(s: Status): Set[int] =
    deposits.keys().filter(i => deposits.get(i).status == s)

  def sumOver(ids: Set[int], f: (Deposit) => int): int =
    ids.fold(0, (acc, i) => acc + f(deposits.get(i)))

  def pendingPrincipal = sumOver(withStatus(Pending), d => d.principal)
  def pendingFee = sumOver(withStatus(Pending), d => d.fee)
  def shieldedPrincipal = sumOver(withStatus(Flushed), d => d.principal)
  def cancelledTotal = sumOver(withStatus(Cancelled), d => d.principal + d.fee)

  action init = all {
    blockNo' = 1,
    nextId' = 0,
    deposits' = Map(),
    poolBalance' = 0,
    accruedFee' = 0,
    treasuryBalance' = 0,
    payerBalance' = 0,
    committedCount' = 0,
    cancelDelay' = CANCEL_DELAY_DEFAULT,
    assetDisabled' = false,
    guardViolations' = 0,
    settledWhileDisabled' = false,
    cancelledEarlierThanDefault' = false,
  }

  // --- frames -----------------------------------------------------------
  //
  // Quint has no `UNCHANGED`, so every action assigns all thirteen variables
  // and eighty-odd of those lines said only `x' = x`. Grouped by what they
  // describe: a strict writer-partition is useless here, because almost every
  // variable has a write-set of its own - twelve groups for thirteen variables.
  //
  // An action writing *part* of a group cannot also frame it and spells out the
  // rest by hand; `flush` below is the shape. The four administrative actions,
  // which write one variable each, are where this pays: twelve noise lines
  // become five names.

  /// The escrow book.
  action unchangedEscrows = all {
    deposits' = deposits,
    nextId' = nextId,
  }

  /// Where the tokens are. `accruedFee` is a claim on `poolBalance` rather than
  /// a separate pot, which is why it has to be modelled beside it.
  action unchangedLedger = all {
    poolBalance' = poolBalance,
    accruedFee' = accruedFee,
    treasuryBalance' = treasuryBalance,
    payerBalance' = payerBalance,
  }

  /// Leaves committed to the commitment tree.
  action unchangedTree = committedCount' = committedCount

  /// Live protocol parameters, both owner-set.
  action unchangedParams = all {
    cancelDelay' = cancelDelay,
    assetDisabled' = assetDisabled,
  }

  action unchangedClock = blockNo' = blockNo

  /// The three ghosts. Nothing on chain corresponds to them; they exist so the
  /// invariants can be stated against something other than themselves.
  action unchangedGhosts = all {
    guardViolations' = guardViolations,
    settledWhileDisabled' = settledWhileDisabled,
    cancelledEarlierThanDefault' = cancelledEarlierThanDefault,
  }

  /// `deposit`: escrow principal plus the treasury's fee.
  action submit = {
    nondet publicIn = 1.to(MAX_PUBLIC_IN).oneOf()
    val principal = publicIn * SCALE
    val fee = feeOf(principal)
    all {
      nextId < MAX_DEPOSITS,
      // `_validateDeposit` rejects a disabled asset. This is the only place the
      // flag is read - flush and cancel deliberately do not gate on it.
      not(assetDisabled),
      deposits' = deposits.put(nextId, {
        principal: principal,
        fee: fee,
        submittedAt: blockNo,
        status: Pending,
      }),
      nextId' = nextId + 1,
      // Principal and fee both land in the pool; the rest of the ledger by hand.
      poolBalance' = poolBalance + principal + fee,
      accruedFee' = accruedFee,
      treasuryBalance' = treasuryBalance,
      payerBalance' = payerBalance,
      unchangedTree,
      unchangedParams,
      unchangedClock,
      unchangedGhosts,
    }
  }

  /// `flushBatch` with one deposit: shields it and accrues the treasury's fee.
  /// The tokens do not move - the fee was already in the pool - so this is a
  /// reclassification, which is exactly why `accruedFee` has to be modelled
  /// separately from `poolBalance`.
  action flush = {
    nondet id = 0.to(MAX_DEPOSITS - 1).oneOf()
    all {
      deposits.keys().contains(id),
      deposits.get(id).status == Pending,
      deposits' = deposits.setBy(id, d => { ...d, status: Flushed }),
      nextId' = nextId,
      // A reclassification, not a transfer: the fee was already in the pool.
      accruedFee' = accruedFee + deposits.get(id).fee,
      poolBalance' = poolBalance,
      treasuryBalance' = treasuryBalance,
      payerBalance' = payerBalance,
      // One deposit owns two adjacent leaves: its principal and the note paying
      // the flusher. A batch of n advances the tree by 2n.
      committedCount' = committedCount + LEAVES_PER_DEP,
      settledWhileDisabled' = (settledWhileDisabled or assetDisabled),
      guardViolations' = guardViolations,
      cancelledEarlierThanDefault' = cancelledEarlierThanDefault,
      unchangedParams,
      unchangedClock,
    }
  }

  /// `cancelDeposit` past the delay: refunds principal and fee to the payer.
  action cancel = {
    nondet id = 0.to(MAX_DEPOSITS - 1).oneOf()
    all {
      deposits.keys().contains(id),
      deposits.get(id).status == Pending,
      blockNo >= deposits.get(id).submittedAt + cancelDelay,
      deposits' = deposits.setBy(id, d => { ...d, status: Cancelled }),
      nextId' = nextId,
      poolBalance' = poolBalance - deposits.get(id).principal - deposits.get(id).fee,
      payerBalance' = payerBalance + deposits.get(id).principal + deposits.get(id).fee,
      accruedFee' = accruedFee,
      treasuryBalance' = treasuryBalance,
      settledWhileDisabled' = (settledWhileDisabled or assetDisabled),
      // Parenthesised deliberately: `x' = a or b` parses as `(x' = a) or b`,
      // an action-level disjunction whose first branch just carries the old
      // value, so the latch silently never fires.
      cancelledEarlierThanDefault' =
        (cancelledEarlierThanDefault
          or blockNo < deposits.get(id).submittedAt + CANCEL_DELAY_DEFAULT),
      guardViolations' =
        if (blockNo < deposits.get(id).submittedAt + cancelDelay) guardViolations + 1
        else guardViolations,
      unchangedTree,
      unchangedParams,
      unchangedClock,
    }
  }

  /// Negative path: `cancelDeposit` before the delay must be rejected.
  ///
  /// The model asserts a rejection - every variable unchanged - and the driver
  /// wraps the call in `vm.expectRevert(CancelTooEarly.selector, id, unlock)`.
  /// The invariant suite cannot express this: `cancelOne` rolls past the delay
  /// first, so the guard it depends on is never actually exercised.
  action cancelTooEarly = {
    nondet id = 0.to(MAX_DEPOSITS - 1).oneOf()
    all {
      deposits.keys().contains(id),
      deposits.get(id).status == Pending,
      blockNo < deposits.get(id).submittedAt + cancelDelay,
      guardViolations' =
        if (blockNo >= deposits.get(id).submittedAt + cancelDelay) guardViolations + 1
        else guardViolations,
      settledWhileDisabled' = settledWhileDisabled,
      cancelledEarlierThanDefault' = cancelledEarlierThanDefault,
      // Everything else: a rejected cancel must leave the state exactly as it
      // found it, which is the whole content of this action.
      unchangedEscrows,
      unchangedLedger,
      unchangedTree,
      unchangedParams,
      unchangedClock,
    }
  }

  /// `sweep`: move the accrued fee out to the treasury. Permissionless caller,
  /// owner-pinned destination.
  action sweep = all {
    treasuryBalance' = treasuryBalance + accruedFee,
    poolBalance' = poolBalance - accruedFee,
    accruedFee' = 0,
    payerBalance' = payerBalance,
    unchangedEscrows,
    unchangedTree,
    unchangedParams,
    unchangedClock,
    unchangedGhosts,
  }

  action advanceBlocks = {
    nondet n = BLOCK_JUMPS.oneOf()
    all {
      blockNo' = blockNo + n,
      unchangedEscrows,
      unchangedLedger,
      unchangedTree,
      unchangedParams,
      unchangedGhosts,
    }
  }

  /// `setCancelDelay`, owner-only, bounded to [MIN, MAX].
  ///
  /// The reason this is worth an action of its own: `cancelDeposit` computes
  /// `unlockBlock = submittedAt + cancelDelay` from *storage*, and the escrow
  /// digest binds `submittedAt` but not the delay. So moving the delay moves
  /// the unlock block of every deposit already in flight - shortening it can
  /// make an escrow cancellable immediately, and lengthening it extends a lock
  /// the payer accepted under different terms.
  ///
  /// That is a design decision rather than a defect - the delay is a live
  /// protocol parameter, not a term of each escrow.
  ///
  /// `cancelDelay` is live state, compared against `masp.cancelDelay()` after
  /// every step, and both cancel guards read it rather than a constant. So a
  /// contract change to the setter's bounds, or to reading the delay from
  /// storage at cancel time, diverges here.
  ///
  /// `wit_cancelledEarlierThanDefault` witnesses the consequence: a deposit
  /// cancelled in the window that opens when the delay is shortened beneath it.
  ///
  action setCancelDelay = {
    nondet newDelay = DELAY_CHOICES.oneOf()
    all {
      cancelDelay' = newDelay,
      assetDisabled' = assetDisabled,
      unchangedEscrows,
      unchangedLedger,
      unchangedTree,
      unchangedClock,
      unchangedGhosts,
    }
  }

  /// `setAssetDisabled`, owner-only.
  ///
  /// The flag is read in exactly one place - `_validateDeposit` - so it stops
  /// new deposits and nothing else. `flushBatch` and `cancelDeposit` do not
  /// consult it, which is what keeps a disable from stranding funds already
  /// escrowed in that asset.
  ///
  /// That is an absence of a check, which is precisely the kind of thing a
  /// later refactor breaks by adding one. Here the model keeps flush and cancel
  /// enabled while disabled, so gating either of them on the flag would surface
  /// as an enabledness divergence rather than as silently stranded escrows.
  action setAssetDisabled = {
    nondet disabled = Set(false, true).oneOf()
    all {
      assetDisabled' = disabled,
      cancelDelay' = cancelDelay,
      unchangedEscrows,
      unchangedLedger,
      unchangedTree,
      unchangedClock,
      unchangedGhosts,
    }
  }

  action step = any { submit, flush, cancel, cancelTooEarly, sweep, advanceBlocks, setCancelDelay, setAssetDisabled }

  // --- invariants -------------------------------------------------------

  /// Every token the pool holds is accounted for by exactly one claim on it.
  /// Mirrors `invariant_balanceConservation`, but checked after every step
  /// rather than at the end of a run.
  val inv_balanceConservation =
    poolBalance == pendingPrincipal + pendingFee + shieldedPrincipal + accruedFee

  /// Ids are dense from zero, and the sum type makes a deposit in two states
  /// unrepresentable rather than merely uncounted.
  val inv_lifecycleDense = deposits.keys() == 0.to(nextId - 1)

  /// Two leaves per flushed deposit.
  ///
  /// `invariant_rootCoherence` documents this in its NatSpec and then asserts
  /// `committedCount == ghostInserted` against a ghost that counted one. Both
  /// halves were wrong and cancelled out at 0 == 0, because no flush ever
  /// landed. Stated here as the arithmetic it actually is.
  val inv_committedCountMatchesFlushed =
    committedCount == LEAVES_PER_DEP * withStatus(Flushed).size()

  /// The treasury is only ever paid out of accrued fees, and only fees from
  /// deposits that were actually shielded. A pending deposit's fee is escrowed,
  /// never accrued - `FeeConfig` documents that and nothing checked it.
  val inv_feeNeverEscrowed =
    accruedFee + treasuryBalance == sumOver(withStatus(Flushed), d => d.fee)

  /// A refund is exactly what was escrowed: principal plus fee, no more.
  val inv_refundsAreExact = payerBalance == cancelledTotal

  /// Nothing goes negative. Solidity would revert on underflow, so a model that
  /// allowed it would diverge rather than mislead - but it is cheap to rule out
  /// at the model level, where the counterexample is readable.
  val inv_noNegativeBalances = and {
    poolBalance >= 0,
    accruedFee >= 0,
    treasuryBalance >= 0,
    payerBalance >= 0,
  }

  /// Neither cancel action ever fired on the wrong side of the delay. The
  /// delay is the whole point of the cancel window, and this is the only
  /// invariant that constrains it - the value-flow invariants above are
  /// indifferent to *when* a refund happened.
  val inv_cancelGuardsRespected = guardViolations == 0

  /// The setter's bounds hold for every reachable delay. `cancelDeposit`
  /// trusts this: an unbounded delay would either strand escrows forever or
  /// remove the window entirely.
  val inv_cancelDelayInBounds =
    cancelDelay >= CANCEL_DELAY_MIN and cancelDelay <= CANCEL_DELAY_MAX

  val allInvariants = and {
    inv_cancelGuardsRespected,
    inv_cancelDelayInBounds,
    inv_balanceConservation,
    inv_lifecycleDense,
    inv_committedCountMatchesFlushed,
    inv_feeNeverEscrowed,
    inv_refundsAreExact,
    inv_noNegativeBalances,
  }

  // --- witnesses --------------------------------------------------------

  /// A cancel that happened exactly on the unlock block. The boundary between
  /// `cancel` and `cancelTooEarly` is the whole point of the delay, and a run
  /// that never lands on it has tested the two sides but not the edge.
  val wit_cancelledAtBoundary =
    withStatus(Cancelled).exists(i => blockNo == deposits.get(i).submittedAt + cancelDelay)

  /// A flush and a cancel both happened. Traces that only ever do one leave
  /// half the lifecycle untouched.
  val wit_bothTerminalStates =
    withStatus(Flushed).size() > 0 and withStatus(Cancelled).size() > 0

  /// Fees were accrued and then swept, so the treasury path ran end to end.
  val wit_sweptAfterFlush = treasuryBalance > 0

  /// A deposit was flushed or cancelled while its asset was disabled - the
  /// property that a disable stops new inflow without stranding escrows.
  val wit_settledWhileDisabled = settledWhileDisabled

  /// A deposit cancelled in the window that opens when the delay is shortened
  /// beneath it - the consequence of the delay being live state rather than a
  /// term of each escrow.
  val wit_cancelledEarlierThanDefault = cancelledEarlierThanDefault

}
