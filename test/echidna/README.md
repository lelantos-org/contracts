# Echidna suite

Property fuzzing for `MASP` and its peripherals.

## Targets

| Target | Subject | Properties | Optimization targets |
| --- | --- | --- | --- |
| `EchidnaMasp` | Plain-asset state machine: deposit, flush, cancel, sweep, withdraw, transfer | 25 | 2 |
| `EchidnaMaspYield` | Yield-asset accounting | 6 | 2 |
| `EchidnaGenericCall` | `GenericCallWrapper` against a stub pool | 8 | 2 |

Each target is a separate contract with its own corpus.

## Running

```sh
just echidna              # all targets, property mode, 50k tests each
just echidna 400000       # nightly CI limit, capped by `timeout`
just echidna-optimize     # all targets, optimization mode
```

- Both recipes build under `[profile.echidna]` and regenerate their configs from the current artifacts. The profile pre-links `YieldOps` and `DepositOps` at fixed addresses, and `just _echidna-config` places each library's code there. The generated configs and the corpus are git-ignored.
- Echidna persists its corpus on disk (`corpusDir` in [`echidna.yaml`](../../echidna.yaml)), so a run mutates sequences found by earlier runs. The nightly job in [`.github/workflows/fuzz.yml`](../../.github/workflows/fuzz.yml) caches one corpus per target. A campaign stopped by `timeout` still writes its corpus and reports its properties.
- Property mode exits 0 when all properties hold and is the gate. Optimization mode always exits non-zero; the recipe ignores the exit code and the CI step sets `continue-on-error`.

## `EchidnaMasp`

Both verifiers are stubbed to accept. Conservation of value across a spend is enforced by the circuit and is not asserted here; `withdrawOne` bounds itself to shielded principal the ghost state recorded as deposited.

**Bookkeeping**

| Property | Holds that |
| --- | --- |
| `echidna_solvency` | The pool balance equals escrowed totals, plus shielded principal not yet withdrawn, plus claimable fees. |
| `echidna_feeAccrualAccounted` | `accruedFee` moves only at flush, withdraw and sweep. |
| `echidna_rootCoherence` | The live root is the last one written, is in the known-roots ring, and the leaf count matches. |
| `echidna_lifecycleExclusivity` | Every id is in exactly one of Pending, Flushed, Cancelled. |

**Guards**

| Property | Holds that |
| --- | --- |
| `echidna_cancelDigestBinds` | No `cancelDeposit` with a corrupted digest field was accepted. |
| `echidna_flushDigestBinds` | No `flushBatch` with a corrupted digest field was accepted. |
| `echidna_cancelDelayEnforced` | No deposit was cancelled before `cancelDelay` elapsed. |
| `echidna_noDoubleDrain` | No deposit was drained twice. |
| `echidna_payerGuardEnforced` | No contract payer's deposit was cancelled by another address. |
| `echidna_escrowMatchesLifecycle` | `escrowed[id]` is non-zero for exactly the pending ids. |
| `echidna_treasuryConservation` | The treasury balance equals the total swept. |

**Withdraw**

| Property | Holds that |
| --- | --- |
| `echidna_noNullifierReuse` | No nullifier was consumed twice through `withdraw`. |
| `echidna_unknownRootRejected` | No withdrawal against a root the pool never committed was accepted. |
| `echidna_spentNullifiersStaySpent` | Every consumed nullifier still reads spent. |
| `echidna_withdrawFeeSplitExact` | `net + fee == gross`, summed over every withdrawal. |
| `echidna_recipientCredited` | The recipient received exactly the net amount. |

**Batch and transfer**

| Property | Holds that |
| --- | --- |
| `echidna_transferMovesNoTokens` | A transfer consumes notes and advances the tree without changing the pool's balance. |
| `echidna_transferNamesNoAsset` | No transfer whose request names an asset was accepted. |
| `echidna_noDuplicateIdInBatch` | A batch naming the same deposit twice is rejected. |

**Root ring and pause**

| Property | Holds that |
| --- | --- |
| `echidna_rootRingConsistent` | Every root in the ring reads as known. |
| `echidna_evictedRootsUnknown` | No evicted root reads as known. |
| `echidna_evictedRootRejected` | No withdrawal against an evicted root was accepted. |
| `echidna_pauseBlocksDeposits` | No deposit was accepted while paused. |
| `echidna_pauseBlocksSpends` | No spend was accepted while paused. |
| `echidna_pauseCannotTrapFunds` | A cancel past its delay is honoured while paused. |

| Optimization target | Maximises |
| --- | --- |
| `optimize_solvencyDeficit` | Amount owed (escrowed deposits, shielded principal, claimable fees) minus the pool's balance. |
| `optimize_feeAccrualDrift` | Absolute difference between `accruedFee` and the accrual implied by the flush, withdraw and sweep history. |

## `EchidnaMaspYield`

| Property | Holds that |
| --- | --- |
| `echidna_noFreeMoney` | Paid out never exceeds paid in plus what the venue earned. |
| `echidna_poolCoversIdlePlusPlainLiability` | The pool holds the booked idle buffer in addition to what the plain id is owed. |
| `echidna_idleNeverExceedsGross` | Booked idle never exceeds the backing. |
| `echidna_everyUnitIsBacked` | Outstanding units are backed. |
| `echidna_highWaterMarkNeverFalls` | `lastIdx` only rises. |
| `echidna_venueBindingImmutable` | The venue binding does not change and the asset stays indexed. |

| Optimization target | Maximises |
| --- | --- |
| `optimize_freeMoney` | `paidOut - (paidIn + earned)`. |
| `optimize_idleOverGross` | `idle - gross`. |

## `EchidnaGenericCall`

The target is also the handler for `test/invariant/GenericCallWrapper.invariant.t.sol`. It uses no cheatcodes: it is the withdraw proof's `payer`, drives every execution itself, and derives the next executor clone's address from the wrapper's CREATE nonce.

Each handler builds one execution shape, predicts from the stub pool's fee arithmetic whether the calls land or refund and what every address receives, runs it, and records the prediction.

| Handler | Shape |
| --- | --- |
| `swap` | Ten `SwapMode`s. Landing: `Honest`, `UnusedInput`, `DonationMidLeg`, `PrefundedExecutor`, `StaleApproval`. Refunding: `Shortfall`, `FailingCall`, `Expired`, `DeniedTarget`, `HookDrain`. |
| `split` | Three outputs, the input token among them. |
| `cancel`, `flush`, `donate`, `drainPast` | Actions between executions. |
| `tamper`, `stranger`, `oversized` | Calls the wrapper must refuse. |

| Property | Holds that |
| --- | --- |
| `echidna_poolBalancesMatch` | The pool holds exactly the escrowed notes net of cancels, plus unshield fees. |
| `echidna_surplusMatches` | `surplusTo` received exactly the cushions, unused input and donations. |
| `echidna_refundsMatch` | `refundTo` received exactly what cancelled escrows held. |
| `echidna_wrapperHoldsOnlyDonations` | Between executions the wrapper holds only what was donated to it. |
| `echidna_executorsEmpty` | Every clone is empty after its execution, and the drainer holding approvals on old clones received nothing. |
| `echidna_escrowRecordsMatchPool` | Every pending escrow's record names `refundTo` and the amount the pool holds; a cancelled one is cleared. |
| `echidna_outcomesAsPredicted` | Every execution landed or refunded as predicted and did not revert. |
| `echidna_guardsHold` | No tampered intent, lifted proof, oversized note or cancel of a settled escrow landed. |

| Optimization target | Maximises |
| --- | --- |
| `optimize_wrapperResidue` | Wrapper balance above what was donated. |
| `optimize_surplusDrift` | `surplusTo` balance above the recorded amount. |

## Files

| File | Role |
| --- | --- |
| `EchidnaMasp.sol` | Plain-asset target: properties and optimization targets. Inherits the three modules below. |
| `EchidnaMaspBase.sol` | Constants, ghost state, constructor (pool and mock deployment), shared helpers. |
| `EchidnaMaspHandlers.sol` | Honest handlers: escrow, withdraw and transfer, root ring, pause. |
| `EchidnaMaspAdversarial.sol` | Negative handlers: tampered digests, early cancel, double drain, stranger cancel. |
| `EchidnaMaspPayer.sol` | The plain target's payer: a deployed contract with permissive ERC-1271 that originates its own calls. |
| `EchidnaMaspYield.sol` | Yield target: shield, settle, exit, and venue growth, loss, illiquidity and maintenance. |
| `EchidnaGenericCall.sol` | `GenericCallWrapper` target, shared with the Foundry invariant suite. |
| `EchidnaRoots.sol` | Root values reduced into the BN254 scalar field, for the targets that stub the tree-update verifier. |
| `Echidna*Reachability.t.sol` | `forge test` gates, one per target. See [Reachability](#reachability). |

## Differences from the Foundry handlers

Echidna runs on hevm, whose cheatcode set is smaller than Foundry's.

| Concern | Foundry suites | Echidna targets |
| --- | --- | --- |
| Tree-update verifier | `vm.mockCall` | `MockTreeUpdateVerifier`, a deployed contract |
| Payer | `vm.etch` and `vm.prank` | `EchidnaMaspPayer`, a deployed contract |
| Block advancement | `vm.roll` past `cancelDelay` | The delay guard is live; `maxBlockDelay` is set against `CANCEL_DELAY_DEFAULT` (7,200 blocks) |

## Reachability

A property whose handler returns early is reported as passing. Each target therefore has a reachability test, run under `forge test`, that drives every handler directly and asserts it changed state. `EchidnaMaspReachability.t.sol` also asserts that a cancel inside the delay window is rejected, and `EchidnaMaspYieldReachability.t.sol` that the optimization targets observe real inflow and outflow. The Echidna coverage report (`corpus/covered.*.txt`) confirms reachability under Echidna itself.

Constraints that affect reachability:

- Echidna resets state between sequences, so a deep state must be reachable within one sequence. `churnRoots` advances the root in a loop to reach the ring wrap, and `seqLen` is 400.
- Block and time delays are drawn independently. The pause properties need a paused pool (timestamp-bounded) holding a deposit past its cancel delay (block-bounded), so `maxTimeDelay` is small relative to `maxBlockDelay`.
