# Echidna suite

Property fuzzing for MASP, run by [`just echidna`](../../justfile). Two targets:

- **`EchidnaMasp`** — the plain-asset state machine: deposit, flush, cancel,
  sweep, withdraw and transfer. 24 properties, 2 optimization targets.
- **`EchidnaMaspYield`** — the indexed-asset (yield) accounting. 6 properties,
  2 optimization targets.

Separate contracts rather than one wider one: their setups share nothing (the
yield target needs a venue, a vault, and two asset ids over one ERC-20) and a
combined contract would make every sequence pay for both. They keep separate
corpora for the same reason — a corpus is a set of call sequences against one
ABI.

## What it checks

Twenty-four properties across five groups, plus two optimization targets.

**Bookkeeping** — ported from `test/invariant/MASPPendingFee.invariant.t.sol`
and `test/invariant/MASP.flow.invariant.t.sol`, restated so the corpus below
has something to compound against:

| Property | Holds that |
| --- | --- |
| `echidna_solvency` | The pool holds escrowed totals + shielded principal not yet withdrawn + claimable fees, and nothing else. |
| `echidna_feeAccrualAccounted` | `accruedFee` moves only at flush, at withdraw, and at sweep — never at submit or cancel, so escrowed fees stay refundable. |
| `echidna_rootCoherence` | The live root is the last one written, is inside the known-roots ring, and the leaf count matches. |
| `echidna_lifecycleExclusivity` | Every id is in exactly one of {Pending, Flushed, Cancelled}. |

**Guards** — the negative space. Everything above drives the pool the way an
honest caller would and can only confirm that correct input is accepted; these
make calls the pool must *reject*. Nothing else in the repo fuzzes this half:
the Foundry handlers always resupply a correct preimage.

| Property | Holds that |
| --- | --- |
| `echidna_cancelDigestBinds` | No `cancelDeposit` with any one of the ten digest fields corrupted has been accepted. |
| `echidna_flushDigestBinds` | The same, on the flush leg — which rebuilds the digest from the batch rather than from call arguments, so it is a separate reconstruction. |
| `echidna_cancelDelayEnforced` | No deposit cancelled before `cancelDelay` elapsed. |
| `echidna_noDoubleDrain` | No deposit drained twice. |
| `echidna_payerGuardEnforced` | No contract payer's deposit cancelled by anyone else. |
| `echidna_escrowMatchesLifecycle` | `escrowed[id]` is non-zero for exactly the pending ids — catches a drain that moved funds without clearing the slot, or a clear that moved none. |
| `echidna_treasuryConservation` | Everything swept is in the treasury; nothing else reached it. |

**Withdraw** — the entrypoint with the least sequence-level coverage in the
repo. The unit tests exercise it, but the only invariant suite that touches
nullifiers drives `MASPHarness.consumeNullifierExternal`, i.e. `NullifierSet`
in isolation, never the real spend path.

| Property | Holds that |
| --- | --- |
| `echidna_noNullifierReuse` | No nullifier consumed twice through `withdraw` itself. |
| `echidna_unknownRootRejected` | No withdrawal against a root the pool never committed. |
| `echidna_spentNullifiersStaySpent` | Every consumed nullifier still reads spent — the bitmap packs 256 per slot, so a write clobbering neighbours would silently un-retire a note. |
| `echidna_withdrawFeeSplitExact` | `net + fee == gross`, to the wei, summed over every withdrawal. |
| `echidna_recipientCredited` | The recipient received exactly the net, and nothing besides. |

**Batch and transfer** — entry points and shapes the Foundry handlers never
build. `flushOne` only ever passes one id, so the loop in `flushBatch` and the
per-token fee accumulator behind it run at n = 1 and nowhere else.

| Property | Holds that |
| --- | --- |
| `echidna_transferMovesNoTokens` | A shielded transfer consumes notes and advances the tree while leaving the pool's balance bit-identical — MASP's own comment on the branch is "No tokens move". |
| `echidna_noDuplicateIdInBatch` | A batch naming the same deposit twice is rejected. Accepting it would mint two commitments against one escrow — the drain-once rule *within* a transaction, which `echidna_noDoubleDrain` cannot reach. |

**Root ring and pause** — `CommitmentTree` keeps `ROOT_HISTORY = 64` roots in a
ring and forgets what the next push displaces. Nothing else in the repo pushes
past the wrap.

| Property | Holds that |
| --- | --- |
| `echidna_rootRingConsistent` | Every root the buffer still holds reads as known. The buffer and the map are written together but read apart. |
| `echidna_evictedRootsUnknown` | No evicted root still reads as known — else a spend proves inclusion in a tree state the pool has forgotten. |
| `echidna_evictedRootRejected` | No withdrawal against an evicted root is accepted. Distinct from `echidna_unknownRootRejected`: this root *was* the pool's state once, so it is the case a stale-root check is likeliest to get wrong. |
| `echidna_pauseBlocksDeposits` | A pause stops the pool taking on new obligations. |
| `echidna_pauseBlocksSpends` | A pause stops the pool settling spends. |
| `echidna_pauseCannotTrapFunds` | A cancel past its delay is still honoured while paused. `cancelDeposit` and `sweep` are excluded from `whenNotPaused` on purpose — a deliberate asymmetry is exactly what a later refactor tidies away, at which point an admin could freeze depositors' money. |

### What the withdraw properties deliberately do not assert

Both verifiers are stubbed to accept, so the fuzzer supplies the public inputs
a circuit would otherwise have constrained and can "withdraw" value no deposit
funded. Conservation of value across a spend is the *circuit's* invariant, not
MASP's, and it is not observable here — asserting it would report an
insolvency that is an artifact of the stub. `withdrawOne` therefore bounds
itself to shielded principal the ghost knows was deposited, and every property
above asserts something MASP itself owns: nullifier uniqueness, root
membership, and the exact arithmetic of the fee split.

## Why this exists next to `test/invariant/`

Foundry's invariant runner starts each run from a fixed seed and samples fresh
call sequences. A rare sequence that reached a deep state last night has to be
rediscovered from scratch tonight. Echidna mutates a corpus it keeps on disk
(`corpusDir` in [`echidna.yaml`](../../echidna.yaml)), so the nightly job
compounds: sequences that first reached a deep state weeks ago stay in the pool
as mutation bases. That is the whole return on running both, and it only holds
while the corpus survives between runs — see the cache note in the `echidna`
job in [`.github/workflows/fuzz.yml`](../../.github/workflows/fuzz.yml).

Optimization mode is the second thing Foundry has no equivalent of.
`just echidna-optimize` maximises a value rather than asserting it, which
answers "how far can solvency drift" instead of "does it ever break" — the
question that separates a bounded rounding residue from a leak that grows with
volume.

## The yield target

`test/yield/YieldSolvency.invariant.t.sol` already covers this ground well —
seven invariants over thirteen handlers, spanning growth, loss, illiquidity,
rebalance, unwind and the fee high-water mark. `EchidnaMaspYield` is
deliberately *not* a port of it. Re-stating those invariants would buy almost
nothing; what Foundry cannot express is **magnitude**, and that is the point of
the file.

`invariant_paysOutNoMoreThanCameInPlusYield` asks whether the yield id ever
distributes value that was neither deposited nor earned. Yes or no, and the
answer is no. It cannot ask *how close the pool gets* — which is the question
separating a rounding residue bounded by a few wei from a leak that grows with
volume. Yield is exactly where that matters: every conversion between
normalized units and assets is a `mulDiv` with a rounding direction.
`optimize_freeMoney` maximises that slack directly.

| Property | Holds that |
| --- | --- |
| `echidna_noFreeMoney` | Paid out never exceeds paid in plus what the venue genuinely earned. |
| `echidna_poolCoversIdlePlusPlainLiability` | The pool holds the idle buffer it booked *on top of* what the plain id is owed — the risk two ids over one ERC-20 creates. |
| `echidna_idleNeverExceedsGross` | Booked idle is a component of the backing, never more than it. |
| `echidna_everyUnitIsBacked` | Units outstanding are never unbacked. |
| `echidna_highWaterMarkNeverFalls` | `lastIdx` only rises, so the treasury cannot bill twice for one period of growth. |
| `echidna_venueBindingImmutable` | The venue binding is permanent and the asset stays indexed. |

| Optimization target | Maximises |
| --- | --- |
| `optimize_freeMoney` | `paidOut - (paidIn + earned)` — the slack in the no-free-money invariant. |
| `optimize_idleOverGross` | `idle - gross` — how far booked idle can exceed real backing. |

A related fix went into the justfile alongside this: `just test-fuzz` globbed
only `test/fuzz/**` and `test/invariant/**`, so `YieldSolvency.invariant.t.sol`
— an invariant suite by everything except its directory — had never run at the
nightly depth. It does now.

## Files

| File | Role |
| --- | --- |
| `EchidnaMasp.sol` | Plain-asset target: handlers (honest, adversarial and withdraw), ghost bookkeeping, properties, optimization targets. |
| `EchidnaMaspYield.sol` | Indexed-asset target: shield/settle/exit plus venue growth, loss, illiquidity and maintenance. |
| `EchidnaMaspPayer.sol` | The fixture payer as a real contract — permissive ERC-1271, and able to originate its own calls. Used only by the plain target; the yield target uses `depositAuthorized` and is its own payer. |
| `EchidnaMaspReachability.t.sol` | A `forge test` gate proving each handler actually lands. See below. |
| `EchidnaMaspYieldReachability.t.sol` | The same for the yield target, including that the optimization targets see real inflow and outflow — a maximum of 0 over a history that never paid anything out is indistinguishable from exact accounting. |

## Where it diverges from the Foundry handlers

Echidna runs on hevm, whose cheatcode set is smaller than Foundry's. Three
things had to change, all noted at their sites in `EchidnaMasp.sol`:

- **Tree-update verifier.** The Foundry suites stub it with `vm.mockCall`; hevm
  has no `mockCall`, so this one uses `MockTreeUpdateVerifier`, a real contract.
- **The payer.** The Foundry suites `vm.etch` a stub at a hard-coded address and
  `vm.prank` it for the calls MASP restricts to the payer. `EchidnaMaspPayer` is
  deployed instead, so it has code (Permit2 routes through ERC-1271) and
  originates its own calls (`cancelDeposit`'s `PayerNotSender` guard is
  satisfied honestly rather than by impersonation).
- **Block advancement.** The Foundry handlers `vm.roll` past `cancelDelay`
  unconditionally, which makes every cancel succeed and so never exercises the
  timing guard. Here the guard is live and Echidna has to find the timing;
  `maxBlockDelay` is set against `CANCEL_DELAY_DEFAULT` (7,200 blocks) so it
  can, and the coverage report confirms it does.

## Reachability is not free here

Three of these properties passed *vacuously* when first written: across 40,000
calls, the handlers behind `echidna_evictedRootsUnknown`,
`echidna_evictedRootRejected` and `echidna_pauseCannotTrapFunds` never once
reached the pool, and the run reported them green. Two independent causes, both
worth knowing before adding a property that needs a deep state:

- **Echidna resets state between sequences.** Anything requiring many landed
  calls in a row has to fit inside one sequence. The ring evicts nothing until
  64 roots are in it, and transfers spread across two dozen handlers landed
  perhaps twenty times per sequence. `churnRoots` exists for this: it advances
  the root in a loop, putting the wrap within a few calls instead of a few
  hundred. `seqLen` was raised to 400 for the same reason.
- **Independent delays have to overlap.** The pause properties need a paused
  pool (timestamp-bounded) holding a deposit whose cancel delay of 7,200
  *blocks* has elapsed. Echidna draws its block and time delays separately, and
  at the original `maxTimeDelay: 300000` any single call ended the pause long
  before a block jump could cross the delay. Time is now deliberately slow
  relative to blocks, `pauseSpends` refuses to trip over an escrow too small to
  outlast its own window, and `pausedCancelHonoured` searches for a deposit
  that is *both* pending and past its delay rather than giving up on the first
  pending one.

The general shape: a property whose handler early-returns is indistinguishable
from one that holds. The gate below is what tells them apart, and the coverage
report (`corpus/covered.*.txt`) is what confirms it under Echidna specifically —
an `*` on the handler's attempt counter means the call was actually made.

## The reachability gate

A fuzzer reports a property as passing whether it held across a thousand real
state transitions or across a thousand calls that all reverted on entry.
`MaspFlowInvariantTest.test_handlerReachesEveryPath` exists because exactly that
happened to the Foundry suite once: `flushOne` built a one-leaf batch,
`_validateBatchHeader` rejected it, and with reverts tolerated the call rolled
back leaving no trace — so `invariant_rootCoherence` spent its whole life
comparing 0 to 0.

This suite is *more* exposed to that than the Foundry one, because its handlers
were rewritten around a different cheatcode set and `cancelOne` deliberately
leaves a guard live. `EchidnaMaspReachability.t.sol` runs under `forge test` and
drives each handler directly, asserting it changed state — including that a
cancel inside the delay window is rejected, so a passing cancel path cannot be
confused with an unreachable one.

## Running it

```sh
just echidna              # both targets, property mode, 50k tests each
just echidna 400000       # roughly what CI runs nightly
just echidna-optimize     # both targets, optimization mode; reports, does not gate
```

Note that Echidna exits **non-zero in optimization mode whatever it finds** — an
optimization target is never "solved", so it is reported as an open test the way
a failing property would be. The recipe swallows that, and the CI step carries
`continue-on-error`. Property mode exits 0 normally, and is what gates.

Both recipes build under `[profile.echidna]` and regenerate their config first.
That profile pre-links the `YieldOps` library at a fixed address because
Echidna cannot deploy-and-link one the way Foundry does; `just _echidna-config`
then places YieldOps' code there. The generated configs are rebuilt from the
current artifact on every run, so the bytecode cannot go stale — and both they
and the corpus are gitignored.
