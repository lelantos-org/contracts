// Model of the MASP deposit escrow state machine (src/MASP.sol).
//
// Replayed against a real pool by test/quint/MaspReplay.t.sol.
//
// SCOPE
//
// The lifecycle of one escrowed deposit: `deposit` escrows it, `flushBatch`
// shields it, `cancelDeposit` refunds it after a delay, `sweep` moves accrued
// fees to the treasury. This is the machine
// `test/invariant/MASP.flow.invariant.t.sol` drives with a fuzzer, stated
// explicitly so it can be checked.
//
// The model is asserted after every step, so a call that has no effect on the
// contract produces a post-state mismatch. An invariant suite running with
// `fail_on_revert = false` lacks this property: a handler whose call always
// reverts rolls back its ghost updates and passes without signal.
//
// ABSTRACTED
//
//   - Groth16 validity. The driver stubs the tree-update verifier with
//     `vm.mockCall`, as the invariant suite does. Foundry cannot synthesise a
//     valid depth-11 proof, and the subject here is the escrow bookkeeping
//     around a proof, not the proof.
//   - Permit2 and ERC-1271. The driver etches a MockERC1271 onto the payer so
//     any signature passes.
//   - Merkle roots. `committedCount` is modelled as leaf accounting; the root
//     ring is modelled separately in spec/commitment_tree.qnt.
//   - Value commitments, ciphertexts, clue keys. Not relevant to the state
//     machine.
//   - Yield assets, the spend path, upgrades, pausing, multi-asset batches and
//     multi-deposit batches. One plain asset, one deposit per flush.
//   - The delayed commit of a cancel-delay raise. `setCancelDelay` models a
//     lengthening as leaving the live delay unchanged, which is what the
//     contract does at the call; the queued value, its 30-day notice and
//     `commitExitTerms` (timestamp-driven, where this model counts blocks)
//     are covered by test/masp/MASP.deposit.t.sol and MASP.upgrade.t.sol.
//     Once the delay is shortened, the model therefore never lengthens it
//     again.
//   - Fee rounding. `_computeAmounts` floors `inAmt * fbps / BPS`. The asset's
//     scale is 1e10, a multiple of BPS, so the division is exact for every
//     `publicIn` the model can draw and for any fee rate. A ceil-div in the
//     contract is therefore indistinguishable here and in test/invariant/,
//     which registers the same scale.
//
//     Rounding is covered by `test/masp/MASP.fee.t.sol`, which registers an
//     asset with `scale = 1` so the division has a remainder. The balance
//     invariants below do not check fee rounding.
//
//   - Every rejection `_validateDeposit` performs: zero `publicIn`, zero payer,
//     recipient or commitment, wrong chain id, unknown or disabled asset,
//     malformed aux. The driver submits only well-formed deposits, so the model
//     has no rejected-submit action; the unit suite covers these rejections.
module masp {
  // Must match the driver's constants. `MaspReplay.setUp` asserts the pool
  // agrees on CANCEL_DELAY, so a mismatch fails at setup.
  pure val SCALE = 10000000000        // 1e10
  pure val FEE_BPS = 25
  pure val BPS = 10000
  pure val CANCEL_DELAY_DEFAULT = 7200   // MASP.CANCEL_DELAY_DEFAULT
  pure val CANCEL_DELAY_MIN = 3600       // MASP.CANCEL_DELAY_MIN
  pure val CANCEL_DELAY_MAX = 50400      // MASP.CANCEL_DELAY_MAX

  /// The delays `setCancelDelay` may choose: both ends of the permitted range
  /// plus the default, enough to both shorten the delay and attempt to
  /// lengthen it (which the contract only queues).
  pure val DELAY_CHOICES = Set(CANCEL_DELAY_MIN, CANCEL_DELAY_DEFAULT, CANCEL_DELAY_MAX)
  pure val LEAVES_PER_DEP = 2         // PubInputs.LEAVES_PER_DEPOSIT

  /// Bounds the nondet id domain. Ids are dense from 0, so this also bounds how
  /// many deposits a trace can create.
  pure val MAX_DEPOSITS = 6
  pure val MAX_PUBLIC_IN = 1000

  /// Block jumps. A constant set rather than a range so the cancel delay itself
  /// is drawable: submitting at `b` and advancing by exactly the delay puts the
  /// clock on the unlock block, the boundary `cancel` and `cancelTooEarly`
  /// divide. A range such as `1.to(7400)` would reach it with probability
  /// 1/7400. The set holds one jump per delay that can be in force, so the
  /// unlock block is reachable under whichever delay `setCancelDelay` last
  /// chose, plus small jumps to land just short of it.
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
  /// deposit costs and the pool pulls all of it, so this moves only on a
  /// cancel and directly checks refund arithmetic.
  var payerBalance: int
  var committedCount: int
  /// MASP.cancelDelay. A live storage value, not a per-deposit one; see
  /// `setCancelDelay` for the consequence.
  var cancelDelay: int
  /// AssetRegistry entry's `disabled` flag for the one modelled asset.
  var assetDisabled: bool

  /// Ghost; not compared against the chain (see `ignoreState` in the config).
  /// Incremented whenever a cancel action fires on the wrong side of the delay,
  /// which the guards make impossible. Without it the delay is unconstrained by
  /// any invariant: under mutation testing, deleting either guard satisfies
  /// every invariant and the timing rule is checked only by the replay.
  var guardViolations: int

  /// Ghost. Latches when a deposit is flushed or cancelled while its asset is
  /// disabled. Witnessed below: disabling stops new inflow without stranding
  /// escrowed deposits, and the witness shows the traces exercise that case.
  var settledWhileDisabled: bool

  /// Ghost. Latches when a deposit is cancelled at a block the default delay
  /// would still forbid, which is possible only if `setCancelDelay` shortened
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
  // Quint has no `UNCHANGED`, so every action assigns all thirteen variables.
  // The frame actions below group the `x' = x` assignments by what the
  // variables describe; a strict writer-partition would need twelve groups for
  // thirteen variables, since almost every variable has its own write-set.
  //
  // An action that writes part of a group cannot use that group's frame and
  // assigns the remaining members explicitly (see `flush`).

  /// The escrow book.
  action unchangedEscrows = all {
    deposits' = deposits,
    nextId' = nextId,
  }

  /// Where the tokens are. `accruedFee` is a claim on `poolBalance` rather than
  /// a separate balance, so the two are grouped together.
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

  /// The three ghosts. They have no on-chain counterpart and give the
  /// invariants an independent source to check against.
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
      // `_validateDeposit` rejects a disabled asset. This is the only read of
      // the flag; flush and cancel do not gate on it.
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
  /// No tokens move (the fee is already in the pool), so this reclassifies the
  /// fee; hence `accruedFee` is modelled separately from `poolBalance`.
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
      // Parenthesised because `x' = a or b` parses as `(x' = a) or b`, an
      // action-level disjunction whose first branch keeps the old value, so the
      // latch would never fire.
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

  /// Negative path: `cancelDeposit` before the delay reverts.
  ///
  /// The model asserts a rejection (every variable unchanged) and the driver
  /// wraps the call in `vm.expectRevert(CancelTooEarly.selector, id, unlock)`.
  /// The invariant suite does not exercise this guard: `cancelOne` rolls past
  /// the delay first.
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
      // A rejected cancel leaves all other state unchanged.
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
  /// `cancelDeposit` computes `unlockBlock = submittedAt + cancelDelay` from
  /// storage, and the escrow digest binds `submittedAt` but not the delay.
  /// Changing the delay therefore moves the unlock block of every deposit
  /// already in flight: shortening it can make an escrow cancellable
  /// immediately. By design, the delay is a live protocol parameter, not a
  /// term of each escrow.
  ///
  /// Lengthening it would extend the lock the payer accepted, so the contract
  /// only queues a longer delay (`ExitTerms`) and leaves the live value alone;
  /// it lands through `commitExitTerms` after 30 days. The model keeps the live
  /// value on a lengthening, so a contract that applied one at once diverges
  /// here. The queue and the commit are not modelled; see ABSTRACTED.
  ///
  /// `cancelDelay` is compared against `masp.cancelDelay()` after every step,
  /// and both cancel guards read it rather than a constant, so a contract
  /// change to the setter's bounds, or to reading the delay from storage at
  /// cancel time, diverges here.
  ///
  /// `wit_cancelledEarlierThanDefault` witnesses the consequence: a deposit
  /// cancelled in the window that opens when the delay is shortened beneath it.
  action setCancelDelay = {
    nondet newDelay = DELAY_CHOICES.oneOf()
    all {
      cancelDelay' = if (newDelay <= cancelDelay) newDelay else cancelDelay,
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
  /// The flag is read only in `_validateDeposit`, so it stops new deposits and
  /// nothing else. `flushBatch` and `cancelDeposit` do not consult it, so
  /// disabling an asset does not strand funds already escrowed in it.
  ///
  /// The model keeps flush and cancel enabled while the asset is disabled, so a
  /// contract change that gates either on the flag surfaces as an enabledness
  /// divergence rather than as stranded escrows.
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
  /// Mirrors `invariant_balanceConservation`, checked after every step rather
  /// than at the end of a run.
  val inv_balanceConservation =
    poolBalance == pendingPrincipal + pendingFee + shieldedPrincipal + accruedFee

  /// Ids are dense from zero. The sum type makes a deposit in two states
  /// unrepresentable.
  val inv_lifecycleDense = deposits.keys() == 0.to(nextId - 1)

  /// Two leaves per flushed deposit.
  val inv_committedCountMatchesFlushed =
    committedCount == LEAVES_PER_DEP * withStatus(Flushed).size()

  /// The treasury is paid only from accrued fees, and only fees from deposits
  /// that were shielded. A pending deposit's fee is escrowed, never accrued, as
  /// documented in `FeeConfig`.
  val inv_feeNeverEscrowed =
    accruedFee + treasuryBalance == sumOver(withStatus(Flushed), d => d.fee)

  /// A refund is exactly what was escrowed: principal plus fee.
  val inv_refundsAreExact = payerBalance == cancelledTotal

  /// No balance goes negative. Solidity reverts on underflow, so a model that
  /// allowed it would diverge in the replay; ruling it out in the model yields a
  /// readable counterexample.
  val inv_noNegativeBalances = and {
    poolBalance >= 0,
    accruedFee >= 0,
    treasuryBalance >= 0,
    payerBalance >= 0,
  }

  /// Neither cancel action fired on the wrong side of the delay. This is the
  /// only invariant that constrains the delay; the value-flow invariants above
  /// do not depend on when a refund happened.
  val inv_cancelGuardsRespected = guardViolations == 0

  /// The setter's bounds hold for every reachable delay. `cancelDeposit`
  /// relies on this: an unbounded delay could strand escrows indefinitely or
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

  /// A cancelled deposit whose unlock block equals the current block. A run
  /// that never lands on the boundary between `cancel` and `cancelTooEarly`
  /// tests both sides but not the edge.
  val wit_cancelledAtBoundary =
    withStatus(Cancelled).exists(i => blockNo == deposits.get(i).submittedAt + cancelDelay)

  /// Both a flush and a cancel happened, so both terminal states are covered.
  val wit_bothTerminalStates =
    withStatus(Flushed).size() > 0 and withStatus(Cancelled).size() > 0

  /// Fees were accrued and then swept, so the treasury path ran end to end.
  val wit_sweptAfterFlush = treasuryBalance > 0

  /// A deposit was flushed or cancelled while its asset was disabled: disabling
  /// stops new inflow without stranding escrows.
  val wit_settledWhileDisabled = settledWhileDisabled

  /// A deposit cancelled in the window that opens when the delay is shortened
  /// beneath it, a consequence of the delay being live state rather than a term
  /// of each escrow.
  val wit_cancelledEarlierThanDefault = cancelledEarlierThanDefault

}
