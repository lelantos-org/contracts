# Quint suite (model-based testing)

Each spec under [`spec/`](../../spec) is an executable model of one contract.
The Quint simulator generates traces from it, and the tests here replay those
traces against the real contract, asserting the model's expected state **after
every step**.

Run with `just quint-test`. `just test` also picks them up — they are ordinary
Foundry tests. Regeneration (`just quint-gen`) needs node and quint; replay
needs neither.

Tooling is [quint-sol-connect](https://github.com/lelantos-org/quint-sol-connect),
vendored as the `lib/quint-sol-connect` submodule. The submodule commit is the
version pin.

## How this differs from the suites next door

| | chooses the calls | checks | reaches |
| --- | --- | --- | --- |
| `test/fuzz/` | random, one run | properties of that call | shallow, wide inputs |
| `test/invariant/` | random handler sequence | invariants at the end of a run | `depth = 64` |
| `test/symbolic/` | the solver, all inputs | one property, proven | 1-2 calls deep |
| `test/quint/` | a model that is itself invariant-checked | **the whole state, every step** | as deep as `maxSteps` |

The distinction that earns this suite its place is the third column. An
invariant run tells you a property held at the end; it does not tell you the
contract agreed with a model of it at step 37. That difference is what turns a
silent no-op into a named failure — see the `flushOne` note in
[`test/invariant/MASP.flow.invariant.t.sol`](../invariant/MASP.flow.invariant.t.sol).

## Property matrix

| Property | Target | Model action set | What it adds over the suites above | Abstracted | Traces × steps |
| --- | --- | --- | --- | --- | --- |
| `rootIndex` stays in the ring across a wrap | `CommitmentTree` | `advance` | The index is a power-of-two mask, not a modulo. `[invariant] depth = 64` means the invariant suite essentially never reaches a wrap; `test/symbolic/CommitmentTree.symbolic.t.sol` proves it for two advances. These traces run 90 advances and assert at each. | Poseidon: roots are opaque small integers | 8 × 91 |
| The live root is always known | `CommitmentTree` | `advance` | Asserted at every step through 26 evictions, not only at the end of a run | as above | 8 × 91 |
| Nothing is known that has left the ring | `CommitmentTree` | `advance` | Rules out an eviction that failed to unlearn. Not covered elsewhere. | as above | 8 × 91 |
| The full ring contents match, slot by slot | `CommitmentTree` | `advance` | All 64 slots compared every step. No other suite compares the ring as a whole. | as above | 8 × 91 |
| The exit window is exactly the delay plus every pause inside it | `DelayedUpgradeProxy` | queue / cancel / activate / activateTooEarly / pause / reset / changeAdmin / advanceTime | `pauseSpends` extends `activationAt` **only if an upgrade is already pending**, so `queue; pause` and `pause; queue` differ from identical inputs. The symbolic suite's 11 proxy checks are all single-call; this is a sequencing asymmetry no single-call proof can see. | the implementation (V1/V2 by `version()`), caller identity | 8 × 61 |
| An activation actually promotes the implementation | `DelayedUpgradeProxy` | `activateUpgrade` | `implVersion` is read live through the proxy by delegatecall, so an activation that cleared the queue without calling `upgradeToAndCall` diverges. Nothing else would notice. | as above | 8 × 61 |
| The one-shot pause latch agrees with its own history | `DelayedUpgradeProxy` | `pauseSpends`, `resetGuardianPause` | The bound `pauses - resets <= 1` is satisfied by a reset that failed to clear the latch. Counting *effective* resets pins the live boolean to the counts. | as above | 8 × 61 |
| The spent set matches the bitmap after every consume | `NullifierSet` | `consume`, `consumeSpent` | `test/symbolic/` proves the isolation property for a *pair* over all 2^256 values. This runs a *sequence* — up to 24 consumes across three buckets — and re-reads the whole set after each. | nothing; live reads throughout | 6 × 25 |
| A second consume is rejected, and changes nothing | `NullifierSet` | `consumeSpent` | A negative action: the model asserts a *rejection* and the driver wraps the call in `vm.expectRevert(DoubleSpend.selector)`. An invariant run with `fail_on_revert = false` cannot tell a correct rejection from an unrelated revert from a call that never ran. | as above | 6 × 25 |
| Every pool token is claimed by exactly one thing | `MASP` | submit / flush / cancel / cancelTooEarly / sweep / advanceBlocks / setCancelDelay / setAssetDisabled | `invariant_balanceConservation` checks this at the end of a run. Here it is checked after every step, so the report names the action that broke it. | Groth16, permit2, ERC-1271, the root ring | 20 × 97 |
| `committedCount == 2 × flushed` | `MASP` | as above | `invariant_rootCoherence` documents this in NatSpec and then asserts `committedCount == ghostInserted` against a ghost counting one. Both halves were wrong and cancelled at `0 == 0`, because no flush ever landed. | as above | 20 × 97 |
| A pending deposit's fee is never accrued | `MASP` | as above | `accruedFee + treasury == fees of flushed deposits`. `FeeConfig` documents that escrowed fees are not accrued; nothing checked it. | as above | 20 × 97 |
| A refund is exactly principal + fee | `MASP` | `cancel` | `payerBalance` moves only on a refund, because submit mints exactly what the deposit costs. That makes it a direct check on refund arithmetic, which no other suite asserts. | as above | 20 × 97 |
| Cancelling before the delay is rejected | `MASP` | `cancelTooEarly` | Negative action, wrapped in `vm.expectRevert(CancelTooEarly.selector, id, unlock)`. `invariant_lifecycleExclusivity`'s handler rolls past the delay first, so the guard is never exercised there. 9 of the committed cancels land exactly on the unlock block. | as above | 20 × 97 |
| The cancel delay is a live parameter | `MASP` | `setCancelDelay` | `cancelDeposit` reads `cancelDelay` from storage, and the escrow digest binds `submittedAt` but not the delay — so moving it moves the unlock block of every deposit already in flight. The delay is now compared after every step, and both cancel guards read it. | as above | 20 × 97 |
| Disabling an asset does not strand escrows | `MASP` | `setAssetDisabled` | `disabled` is read in exactly one place, `_validateDeposit`, so it stops new deposits and nothing else. Flush and cancel stay enabled while disabled, so gating either on the flag surfaces as an enabledness divergence instead of silently stranded funds. An absence of a check is exactly what a later refactor breaks. | as above | 20 × 97 |
| The asking price falls monotonically while the clock runs | `FeeBurner` | accrueFees / buy / wait / setLot / setPaused | The decay is `startPrice >> periods` minus a linear term inside the period. `test/symbolic/README.md` records that halmos cannot enter any of it — division of a symbolic product is a hard wall — so no accepting `buy` is proven anywhere. Here the curve is compared at every step, and the two ends of each jump are held against each other. | `harvest` and the pool, `minLot`, multiple lot tokens | 8 × 81 |
| `govIn` is a ceiling, and the burn split is not | `FeeBurner` | `buy` | Five roundings run in one call, in two directions. `bidderGov` moves only by `govIn`, so the composite is compared directly rather than inferred; the ghosts bracket the total between the cost basis and the cost basis plus one unit per fill, which a floor cannot sit inside. | as above | 8 × 81 |
| The restart ratchet never leaves the lot cheaper | `FeeBurner` | `buy` | `startPrice` is rewritten from the price the *previous* `buy` cleared at, scaled by the share that buy took. A sawtooth that only exists across steps: no single-call proof and no end-of-run invariant sees it. Nothing else in the repo touches `buy`. | as above | 8 × 81 |
| GOV supply falls by exactly what was burned | `FeeBurner` | `buy` | `govSupply` is read live from `totalSupply()` and compared against a ghost accumulated independently. `test/burn/FeeBurner.invariant.t.sol` checks monotonicity, which a burn of the wrong size satisfies. | as above | 8 × 81 |

Runtime: ~60 ms for all five suites. `commitmentTree` is ~46M gas per trace (91
steps, each re-reading all 64 ring slots); `nullifierSet` is ~1.3M (25 steps
over a 7-value domain). Recorded the way `test/symbolic/README.md` records
solver time, so a regression in cost is visible.

`nullifierSet` drives `test/utils/NullifierSetHarness.sol`, which the symbolic
suite also uses — the two reason about the same surface and differ only in what
they establish. `masp` deploys a real pool behind its proxy with permit2 and a
mock ERC-20, the same setup `test/invariant/MASP.flow.invariant.t.sol` builds.

## What is deliberately not here

**Hashing.** Roots are integers `1..7`, not Poseidon outputs. This models the
bookkeeping *around* a root — eviction, the known-root set, the leaf count — not
the hashing that produces one. The circuits' own vectors cover that.

**A wide root domain.** Six distinct roots over 64 slots is deliberate: it makes
an evicted value usually still present elsewhere in the ring, which is the case
the eviction carve-out exists for. Drawing from a wide domain would make that
case essentially unreachable, and the suite would look thorough while testing
less.

**The spend path.** `withdraw` and `transfer` need real Groth16 proofs, which
Foundry cannot synthesise. The deposit lifecycle is modelled; spends are not.

**Multi-deposit and multi-asset batches.** One deposit per flush, one plain
asset. A batch of n is the same arithmetic n times over, and the leaf-alignment
rule that makes it interesting (`actualCount == 2n`) is already exercised at
n = 1 — that is the check `MaspFlowHandler.flushOne` failed.

**Yield assets, upgrades, pausing.** Separate machines with their own suites.
`MASP`'s escrow lifecycle is what this models.

**`FeeBurner`'s pool.** `harvest` and `burnAccruedGov` are abstracted away: fee
tokens simply arrive at the burner, which is what `FeeConfig.sweep` does when the
burner is the treasury. `harvest` ignores every outcome of the calls it makes, so
routing them adds state without adding a property. `minLot` is held at zero — the
dust floor is a single-call guard, which is halmos territory — and one lot token
is modelled, because the per-token mapping is a mapping.

**`ProtocolAdmin`.** Considered and cut, so this reads as a decision. Its state is
role sets over a fixed address set plus mirrored booleans: no arithmetic, no
time, no accumulator, so a model asserted after every step establishes nothing an
end-of-run invariant misses. The finding that 0–3 byte calldata bypasses
`execute`'s selector gate is a *single-call* property (`data.length >= 4`) that a
unit test or halmos owns better than a trace, and modelling the rest would mostly
mean modelling OpenZeppelin `AccessControl`. Its two genuinely sequence-shaped
properties — `migrateAdmin` as a one-way exit, and lockout by revoking the last
admin — are each a fifteen-line Foundry test.

**Nullifier properties that are already proven.** "Consuming `a` never marks
`b`" holds for all 2^256 pairs and `test/symbolic/NullifierSet.symbolic.t.sol`
proves it. Restating it over a seven-value domain would be strictly weaker. What
is here instead is the thing a pairwise proof does not give: a *sequence*, with
the whole set compared after every call.

**A wide nullifier domain.** The seven values are chosen so every bit position
is shared across buckets and every bucket holds several bits (the table in
`spec/nullifier_set.qnt` sets this out). Random 256-bit nullifiers would
essentially never collide, so a wrong bucket index or a wrong mask would go
unobserved while the suite looked thorough.

**Properties the fuzz suite already samples cheaply.** A trace that merely
re-covers `test/fuzz/CommitmentTree.fuzz.t.sol` costs replay time and adds
nothing. Everything in the matrix above is there because of the fourth column.

## Findings from writing the models

**A root can be in the ring and not be known.** "Every root still present in the
ring is still known" reads like an invariant. It is not: `_advanceRoot` unlearns
the value it evicted without checking whether the same value still occupies
another slot. Quint refuted it in 13 ms, and `wit_ringRootUnlearned` in
[`spec/commitment_tree.qnt`](../../spec/commitment_tree.qnt) now witnesses it in
100% of traces, so it stays visible rather than being rediscovered.

Benign today: production roots come from Poseidon over a strictly growing leaf
set, so two batches never share one and the duplicate case cannot arise. It is
recorded because a change that made roots repeatable would turn it into a live
bug that silently rejects valid proofs.

**The `evicted != newRoot` carve-out is a gas guard, not a correctness one.**
Its comment says clearing that entry "would mark a root still live in the buffer
as unknown", but the very next line sets `isKnownRoot[newRoot] = true`
unconditionally, so the stated failure cannot occur. Confirmed observationally:
a model without the carve-out replays green against the unmodified contract.
Both branches of the condition avoid an SSTORE, which is a real saving —
the comment is what is wrong, not the code.

**The MASP model rediscovers the `flushOne` bug on its own.** Setting
`actualCount = 1` in `MaspReplay._flush` — the exact mistake
`test/invariant/MASP.flow.invariant.t.sol` shipped with — fails all 12 traces at
step 2 with an enabledness divergence naming `BatchMisaligned()`. Under
`fail_on_revert = false` the invariant suite absorbed the same mistake in
silence for the life of the file. That difference is the argument for this
suite in one line.

## How much the invariants actually check

A replay proves the model and the contract agree on the traces that were
generated. It does not prove the model is a faithful abstraction, and
`quint run --invariant` passing proves less than it looks like it does: an
invariant that is an arithmetic consequence of the transitions holds for a
wrong model just as happily as for a right one.

So the models were mutation-tested — each action's update broken one at a time,
asking whether the invariant check alone notices:

| | caught before | caught now |
| --- | --- | --- |
| `masp` (8 mutations) | 6 | 8 |
| `fee_burner` (10) | 0 | 10 |
| `delayed_upgrade_proxy` (8) | 5 | 8 |
| `commitment_tree` (4) | 2 | 4 |
| `nullifier_set` (2) | 0 | 2 |

`fee_burner` caught *nothing* on the first pass, and for the reason this whole
section exists: every invariant was an arithmetic consequence, and every ghost
restated the expression it was supposed to check. The rebuild tracks each
quantity a second way — `costBasis` against `govInTotal`, `soldTotal` and
`accruedTotal` against the balance, `timeAdvanced` against the clock,
`lastTouchAt` against `startedAt`. One mutation still survived that: dropping the
mid-period interpolation. Every invariant reads the price through the same
`priceAt`, so a flattened curve is still inside the band, still above the floor,
still below `startPrice`. Closing it needed the one invariant here that is not a
consequence of the decay expression — hold the curve at *two* clocks against each
other, which is what `priceAt` being parametrised on the clock is for.

The misses were not random elsewhere either. Value flow was well covered from the
start; what nothing constrained was **timing and counting** — deleting either cancel-delay
guard, walking the ring two slots per advance, or counting advances instead of
leaves all left every invariant satisfied. `nullifier_set` caught nothing at
all, because `spentSet.subseteq(NULLIFIERS)` is true by construction and
survives any mutation of `consume`.

One Quint gotcha is worth knowing before writing a ghost: `x' = a or b` parses
as `(x' = a) or b` — assignment binds tighter than `or`, so Quint reads it as a
*nondeterministic choice between two actions*, and the branch that just carries
the old value is always available. A latch written that way never fires and
never errors. It cost two witnesses here, both of which looked like
unreachable states until the parentheses went in. Parenthesise the whole
right-hand side.

Each gap is closed by a ghost variable that tracks the same quantity a second
way — `advances`, `insertedTotal`, `consumeCount`, `guardViolations` — listed
in `ignoreState` with its reason, since there is nothing on chain to compare
them against. The generator copies those reasons into the generated `State`
struct, so the gap is visible where the comparison happens.

Worth being clear about what this does and does not buy. These ghosts catch an
*inconsistent edit to the model* — the failure mode where someone changes one
action and the spec quietly stops describing the contract. They say nothing
about the contract itself. That is still the replay's job, and the fault
injections above are how it is checked.

**A `via_ir` hazard that lands on the read, not the write.**
`test/upgrade/DelayedUpgradeProxy.t.sol` records that warps must be absolute
because the optimizer caches `block.timestamp`. In a replay driver the warp is
actually safe — it happens inside `apply_`, which is reached through an external
self-call and so reads the clock fresh. What is *not* safe is reading
`block.timestamp` in `_project`, which is inlined into the replay loop: the
optimizer hoists it, every step reads the starting timestamp, and every trace
diverges on the clock at the first jump. Read it through an external call
(`this.quintNow()`), which cannot be hoisted.

## Triage: model bug or contract bug?

A failure prints the diverging fields, the step, the action, the trace path and
a reproduce command. Then:

1. Reproduce: `QUINT_VERBOSE=2 forge test --match-test <name> -vvv`.
2. Read the model's intent at that step in ITF. One `exemplar.itf.json` is
   committed per spec — the trace maximising the minimum per-action count — and
   it opens in the [ITF Trace Viewer](https://marketplace.visualstudio.com/items?itemName=informal.itf-trace-viewer).
   For any *other* trace, `just quint-gen <spec> --itf <n>` writes its companion
   to the git-ignored `test/fixtures/quint/<spec>/.itf/`; it refuses if the local
   quint differs from the version the fixture records, since a companion
   generated by a different simulator would be a debugging aid that lies.
   Per-trace companions are not committed: they were 45% of the fixture bytes
   and their use is per-incident, not per-run.
3. Classify by **shape**: a model bug usually diverges early and in *many*
   traces at once; a contract bug usually diverges deep and in *one*.
4. Classify by **flavour**: an `ENABLEDNESS DIVERGENCE` means the model allowed
   an action and the contract reverted — either the model is missing a guard the
   contract has, or the contract gained one the model does not know about. A
   *negative* action lands here too, when its `expectRevert` did not fire: that
   one means the contract stopped rejecting something it should. The report
   decodes the revert string, so these are distinguishable on sight. A state
   divergence with both sides succeeding is usually the contract, or a genuine
   disagreement about semantics.
5. Classify by **provenance**: if the diverging field is one `_project()` builds
   from driver-local state rather than a live read, suspect the driver first.
   Drivers here cross-check such fields with a `require` so a driver bug fails
   as a driver bug.
6. Tie-break: restate the property in `test/symbolic/` and let halmos give an
   independent verdict.
7. Whatever the verdict, keep the trace: copy it to
   `test/fixtures/quint/<spec>/regression/` and commit it.

## Adding a spec

1. Write `spec/<name>.qnt`. Three rules, because they are what `--mbt` needs:
   `step` must be `any { … }` over **bare named** actions; every `nondet` must
   draw from a constant non-empty domain with the guard *inside* the action; a
   pick name must have one type across all actions.

   Then group the frame conditions. Quint has no `UNCHANGED`, so every action
   must assign every variable, and the three larger specs here were 84–93 lines
   of `x' = x` apiece — 261 in total, now 71. Factor them into named
   `unchangedX` actions and conjoin those, so an action lists what it changes
   and names what it leaves alone.

   Group by **what the variables describe**, not by which action writes them. A
   strict writer-partition works for `fee_burner` and is useless for the other
   two: `masp` has twelve distinct write-sets across thirteen variables. The
   cost of grouping by meaning is that an action writing *part* of a group
   cannot also frame it and spells out the rest by hand — `flush` in
   `spec/masp.qnt` and `cancelUpgrade` in `spec/delayed_upgrade_proxy.qnt` are
   the shape. Keep it that way rather than splitting groups until they fit: a
   group name that means something is worth more than one that saves a line.

   Nested composition is invisible to `--mbt`, which reports the action named in
   `step`. Regenerating after this refactor produced byte-identical fixtures
   across all five specs, which is the check to run: it proves the grouping
   changed nothing.
2. Add an entry to [`quint-sol-connect.config.mjs`](../../quint-sol-connect.config.mjs)
   giving the Solidity type of each state variable and each pick.
3. `just quint-gen <name>` — or scaffold a driver stub first.
4. Write the driver: `setUp`, `apply_`, `_project`. Prefer live reads; where the
   contract cannot expose one, shadow it and `require` the shadow against the
   nearest observable.
5. **Fault-inject before believing it.** Change the spec so it disagrees with the
   contract, regenerate, and confirm the failure names the right field at the
   right step. A harness that never fails when the model is wrong is worse than
   none. Then revert.
6. Add a row to the property matrix above, and a line to "what is deliberately
   not here" for anything you chose to leave out.
