# Symbolic suite

Halmos proves each `check_` function here for every input in a bounded state
space, where `forge test`'s fuzzer samples it. Run with `just halmos`;
configuration lives in `halmos.toml` and the `[profile.halmos]` block of
`foundry.toml`.

This suite is deliberately small. A symbolic test earns its place only if it
establishes something the fuzz suite, the invariant suite, or plain static
reasoning does not — a proof that merely re-samples what
`test/fuzz/` already covers costs solver time and adds no assurance.

## Property matrix

| Property | Target | Domain | Why symbolic | Assumptions | Mocked | Runtime |
| --- | --- | --- | --- | --- | --- | --- |
| `unitFee` is exactly `ceilDiv(units * bps, D)` | `Fees.unitFee` | `uint48 x uint16` (the full call-site domain) | Pins a hand-rolled rounding form to OZ's reference for every input; three sites must agree on this number or an escrow cannot settle | none | none | 0.06s |
| Fee is zero only for a zero base or rate | `Fees.unitFee` | `uint48 x uint16` | The property rounding-up exists to provide; a reference comparison alone would not catch a switch to flooring | none | none | 0.16s |
| Consume marks exactly its own nullifier spent | `NullifierSet` | `bytes32` | — | none | none | 0.03s |
| Consuming one nullifier leaves every other unspent | `NullifierSet` | `bytes32 x bytes32` | Bucket/bit aliasing over all 2^256 x 2^256 pairs; the fuzzer can only draw pairs | `a != b` | none | 0.06s |
| Two distinct nullifiers both stick | `NullifierSet` | `bytes32 x bytes32` | — | `a != b` | none | 0.09s |
| Second consume always reverts `DoubleSpend` | `NullifierSet` | `bytes32` | No nullifier value slips through a second spend | none | none | 0.01s |
| A reverted double-consume leaves the bitmap intact | `NullifierSet` | `bytes32 x bytes32` | A caller that swallows the revert cannot un-spend | `a != b` | none | 0.08s |
| Advance sets current root, marks it known, moves the count | `CommitmentTree` | `bytes32 x uint32` | — | none | none | 0.01s |
| `rootIndex` stays in the ring and matches `currentRoot()` | `CommitmentTree` | two advances, any roots | The index is a power-of-two mask, not a modulo | none | none | 0.03s |
| Re-pushing the same root leaves it known | `CommitmentTree` | `bytes32` | Eviction must not unlearn a root still live in the buffer | none | none | 0.01s |
| The previous root stays known | `CommitmentTree` | `bytes32 x bytes32` | A proof against the root one batch behind must survive the next batch | `r1 != r2` | none | 0.02s |
| No non-owner call moves the treasury or the owner | `FeeConfig` | any caller, any calldata (`svm.createCalldata`) | Quantifies over every external function rather than an enumerated list, so a newly added one is covered the moment it compiles | caller is not owner; call succeeded | `MockERC20` | 0.05s |
| `setTreasury` rejects every non-owner with the OZ error | `FeeConfig` | any caller, any destination | — | caller is not owner | `MockERC20` | 0.01s |
| Owner accepts exactly the non-zero destinations | `FeeConfig` | any destination | Both directions, so an over-strict guard that could strand fees also fails | none | `MockERC20` | 0.01s |
| Accrual is additive | `FeeConfig` | `uint120 x uint120` | — | widths keep the sum inside the funded balance | `MockERC20` | 0.04s |
| Sweep drains exactly the accrual, to the pinned treasury, once | `FeeConfig` | `uint120 x uint120` | — | as above | `MockERC20` | 0.30s |
| Registration accepted for exactly the valid inputs | `AssetRegistry.addAsset` | any id, token, scale, both rates | Both directions of the guard, so an over-strict one is caught too | none | none | 0.06s |
| A registered id's token and scale never change | `AssetRegistry` | any id, any owner calldata (`svm.createCalldata`) | The escrow digest and every conversion are computed against these | call succeeded | none | 0.24s |
| A fee or disabled change touches only the named id | `AssetRegistry` | any two distinct ids | Mapping-key isolation; there is no pool-wide rate by design | `id != other` | none | 0.22s |
| Withdraw rate cannot rise while an upgrade is queued | `AssetRegistry.setAssetFee` | any start and target rate | Otherwise an exit fee could be raised against holders leaving during the delay | rates within the 20% cap | none | 0.05s |
| No preimage but the submitted one cancels an escrow | `MASP.cancelDeposit` | all 13 digest fields symbolic | The entire pending record is one hash; keccak injectivity makes the universal statement affordable | mismatching preimages only | Permit2, both verifiers | 3.27s |
| An escrow is consumed once | `MASP.cancelDeposit` | any submitted `cm` | Also the non-vacuity anchor for the proof above | none | Permit2, both verifiers | 0.09s |
| Cancel delay holds at every block height | `MASP.cancelDeposit` | any height at or after submission | Measured from the digest-bound `submittedAt` | `height >= submittedAt` | Permit2, both verifiers | 0.07s |
| A contract payer's escrow is self-service only | `MASP.cancelDeposit` | any caller | A third-party cancel is indistinguishable from a flush and strands the funder's claim | `caller != payer` | Permit2, both verifiers | 0.19s |
| A rate change cannot re-rate a pending deposit | `MASP.setAssetFee` + `cancelDeposit` | any new rate | `fbps` is folded into the digest at submit | new rate within cap, different | Permit2, both verifiers | 0.21s |
| Tree-update commitments must equal the spend's | `MASP._validateRequest` | any commitment vector | Nothing in either circuit binds the two proofs; this check does | vectors differ | both verifiers | 0.98s |
| Value commitments must be bound likewise | `MASP._validateRequest` | any `cv_dep` pair | An unbound one leaves the output permanently unspendable | pair non-zero | both verifiers | 0.04s |
| A spend output cannot be flagged as a deposit leaf | `MASP._validateRequest` | any flag vector | The batch circuit cannot tell them apart and does not force it | some flag set | both verifiers | — |
| Batch must commit exactly the spend's output count | `MASP._validateRequest` | any count | — | `count != 6` | both verifiers | 0.02s |
| A nullifier repeated in any two input slots is rejected | `MASP._validateRequest` | any 4-nullifier vector | All four are consumed in one call, so the bitmap cannot catch this | some pair equal | both verifiers | 0.27s |
| Unknown root, stale `oldRoot`, misaligned `startIndex` rejected | `MASP._validateRequest` | any root / index | Places the batch at the frontier | differs from the live value | both verifiers | 0.04s |
| `pi.relayer` must be `msg.sender` | `MASP._validateRequest` | any relayer and caller | Stops a third party front-running a spend to collect the relayer note | `relayer != caller` | both verifiers | 0.03s |
| A proof built for another chain is not replayable | `MASP._validateRequest` | any chain id | — | `chainId != block.chainid` | both verifiers | 0.02s |
| Deposit request accepted only when well formed | `MASP._validateDeposit` | any amount, fee note, party, commitment, chain id, asset id | The only thing between unauthenticated calldata and an escrow record; all of it rejects before the curve checks | one field broken per proof | Permit2, both verifiers | 0.23s total |
| `depositAuthorized` callable only by the payer | `MASP.depositAuthorized` | any caller | It pulls against the payer's Permit2 allowance; otherwise anyone could drain any approver | `caller != payer` | Permit2, both verifiers | 0.04s |
| A disabled asset takes no new deposits | `MASP` + registry | — | The other half (stays spendable) needs a spend to succeed and is out of reach | none | Permit2, both verifiers | 0.01s |
| No preimage but the submitted one flushes an escrow | `MASP.flushBatch` | 8 fields across `meta` and `tpi` | The flusher supplies the preimage *and* mints its own fee note from it; nothing but this equality authenticates either | mismatching preimages | Permit2, both verifiers | 2.37s |
| A cancelled escrow cannot be flushed | `MASP.flushBatch` | any submitted `cm` | Cancel and flush are the two consumers; the zero sentinel makes them exclusive | none | Permit2, both verifiers | 0.09s |
| One id cannot be drained twice in a batch | `MASP.flushBatch` | any submitted `cm` | `_drainDeposit` deletes as it goes, so the relayer's note cannot be paid twice | none | Permit2, both verifiers | 0.20s |
| Flush rejects wide leaf amounts, mismatched fee asset, non-deposit leaves, misplaced batch, wrong leaf count | `MASP.flushBatch` | any value in each | — | one field broken per proof | Permit2, both verifiers | 0.41s total |
| A bound venue never changes | `MASP.addYieldAsset` + owner config | any id, any replacement venue | Yield is opt-in per asset id; the choice only binds if the venue cannot be re-pointed underneath the holder | `id` unregistered | venue and vault | 0.30s |
| A plain asset cannot gain a venue later | `MASP.addYieldAsset` | — | Opting *out* must be as durable as opting in | none | venue and vault | 0.01s |
| Venue must be pinned to this pool and hold this asset | `YieldOps.initAsset` | any foreign pool, any vault asset | The binding is permanent, so a mis-binding is unrecoverable for that id | differs from expected | venue and vault | 0.06s |
| Yield registration and configuration are owner-only | `MASP` / `YieldIndex` | any caller | `addYieldAsset` binds custody permanently — the most consequential call on the pool | `caller != owner` | venue and vault | 0.08s |
| Aux payload accepted exactly when well formed | `AuxValidation.validate` | ciphertext lengths 0,1,2,3,255,256,257 | Lengths chosen either side of both bounds; halmos's default `0,65,1024` lands on neither edge | points held concrete | — | 0.04s |
| Clue-bits prefix confined to 14 bits | `AuxValidation.validate` | any 2-byte prefix | Bits outside the mask would smuggle a distinguisher into an opaque payload | prefix dirty | points held concrete | 0.00s |
| Activation happens exactly after the window | `DelayedUpgradeProxy` | every timestamp | The exit window is the whole upgrade guarantee; early activation owns every deposit | `t >= T0` | lightweight implementation | 0.02s |
| A queued upgrade does not change the served implementation | `DelayedUpgradeProxy` | every timestamp inside the window | Holders exiting during the window transact against the code they entered under | inside window | as above | 0.13s |
| The queued payload cannot be swapped, nor queued codeless | `DelayedUpgradeProxy.queueUpgrade` | any implementation address | The window cannot be restarted with different code midway | — | as above | 0.02s |
| A pause defers activation by its own duration | `DelayedUpgradeProxy.pauseSpends` | every permitted duration | Makes the window measure *unpaused* time; otherwise a pause could run it out | within `MAX_PAUSE` | as above | 0.02s |
| Pause accepted for exactly its permitted durations, one-shot until reset | `DelayedUpgradeProxy` | any duration | Bounds how long a guardian can hold spends closed | — | as above | 0.03s |
| Activation is permissionless | `DelayedUpgradeProxy.activateUpgrade` | any caller | Closing the window needs no privileged keeper | — | as above | 0.01s |
| Cancel withdraws and never promotes | `DelayedUpgradeProxy.cancelUpgrade` | every later timestamp | A cancelled upgrade cannot be resurrected by waiting | — | as above | 0.01s |
| Privileged proxy entry points reject every non-admin | `DelayedUpgradeProxy` | any caller | — | `caller != admin` | as above | 0.02s |
| A pause halts spends for exactly its window | `MASP` + proxy | every duration and timestamp | A pause outliving its duration is an indefinite halt by another name | within `MAX_PAUSE` | Permit2, both verifiers | 0.28s |
| Escrow stays cancellable throughout a pause | `MASP.cancelDeposit` | every duration, every point inside | The recoverability guarantee: a guardian must not be able to hold depositors' funds | inside window | Permit2, both verifiers | 0.10s |
| Sweep stays open throughout a pause | `MASP.sweep` | every duration and point | Verifies nothing, moves only what accrued | inside window | Permit2, both verifiers | 0.03s |
| The adapter is the only permitted payer, recipient and relayer | `NativeAdapter` | any address in each role | Its Permit2 allowance covers its whole balance, including refunds parked for others | differs from adapter | Permit2, both verifiers | 0.06s |
| Only wrapped-native may push raw coin, and refused coin is not retained | `NativeAdapter.receive` | any sender and amount | Refund accounting is measured in wrapped deltas; unattributed coin is refused | `sender != WETH` | Permit2, both verifiers | 0.05s |
| Ownership can never be dropped | `OwnableInit` via `FeeConfig` | any owner calldata | An unowned pool cannot register assets, retune fees, or be handed to governance | call succeeded | `MockERC20` | 0.06s |
| Spent is permanent | `NullifierSet` | any two distinct nullifiers | The property a double-spend defence rests on | `a != b` | none | 0.07s |
| Cancel delay accepted for exactly its range, owner-only | `MASP.setCancelDelay` | any delay, any caller | Decides how long escrowed funds are locked; bounded on both sides | — | Permit2, both verifiers | 0.09s |
| No `execute` moves the pool's or wrapper's owner | `ProtocolAdmin.execute` | any calldata (`svm.createBytes`), both targets | The contract's whole reason to exist rests on a four-byte comparison against a 2^32 space; a fuzzer drawing `bytes` never hits either value | call succeeded | pool and wrapper | 0.06s each |
| Both `Ownable` selectors refused, whatever follows them | `ProtocolAdmin.execute` | any trailing 32 bytes | Pins the revert reason, so a guard firing for an unrelated cause is caught | none | as above | 0.01s |
| An ordinary governance call is forwarded | `ProtocolAdmin.execute` | any argument | Non-vacuity anchor for the two rows above | none | as above | 0.01s |
| Every self-call is refused | `ProtocolAdmin.execute` | any calldata | Reaching `grantRole` with `msg.sender == address(this)` would mint a guardian or revoke governance | none | as above | 0.00s |
| `execute` and `migrateAdmin` reject every non-admin | `ProtocolAdmin` | any caller, any target, any calldata | The guardian holds a role here, so "not governance" is the property | `caller != gov` | as above | 0.01s |
| Each guardian switch drives one way only | `ProtocolAdmin` | any asset id, any adapter | A compromised guardian key must cost availability, never custody | none | as above | 0.02s |
| Guardian entry points reject every non-guardian | `ProtocolAdmin` | any caller, any id, any adapter | — | caller lacks the role | as above | 0.02s |
| The guardian cannot reach governance's surface | `ProtocolAdmin` | any calldata, any successor | The role split stated from the other side | none | as above | 0.01s |
| `migrateAdmin` moves both owners together | `ProtocolAdmin.migrateAdmin` | — | A pool and wrapper under different owners cannot be driven by either; the targets are immutable | none | as above | 0.02s |
| Migration rejects mismatched targets, an ungoverned successor, and every codeless one | `ProtocolAdmin.migrateAdmin` | any claimed pool and wrapper, any address | Stops the accident; a hostile successor is bounded by the timelock delay instead | one field wrong per proof | as above | 0.04s total |
| Every underfunded refund is rejected | `MaspEscrowSatellite._cancelAndVerify` | any recorded amount x any delivered amount | Clearing a record destroys the only evidence of what the funder is owed; the boundary is four points a sampler has no reason to draw | none | pool and token | 0.15s |
| Every funded refund is accepted and the delivered amount forwarded | as above | any recorded x any delivered above it | On a yield asset the refund exceeds the pull by what the escrow earned, so an exact-match check would revert every cancel | `delivered >= amount` | as above | 0.04s |
| A refund too wide for the record is rejected, not truncated | as above | every value above `type(uint96).max` | Truncation would pay a fraction and strand the rest | non-overflowing | as above | 0.06s |
| A cancel cannot be replayed | as above | any recorded amount | The record is the authorization | none | as above | 0.03s |
| An unknown id and a settled deposit are both refused | as above | any id, any refund | A refused cancel must also leave the record intact | none | as above | 0.01s each |
| The measured pull is bounded on both sides, and exact in between | `MaspEscrowSatellite._escrowMeasured` | any pull, floor and ceiling | `d` is unauthenticated and the Permit2 grant covers the satellite's whole balance, so an oversized `publicIn` would escrow other parties' funds | none | as above | 0.21s |
| No address but the withdraw proof's `payer` may drive a swap | `SwapWrapper.swap` | any caller x any payer | Without it a withdraw proof seen in the mempool is replayable under a different `deposit_d`, redirecting the output | `caller != payer` | pool stand-in only | 0.04s |
| Recipient, relayer and deposit payer must all be the wrapper | `SwapWrapper._validate` | any address in each role | Binds both legs' funds to the contract that must hold them | differs from wrapper | as above | 0.02s each |
| Only an allowlisted adapter, and never past the deadline | `SwapWrapper._validate` | any adapter, every timestamp | The adapter receives the unshielded funds; the deadline is proved in both directions, inclusive at the boundary | none | as above | 0.02s each |
| Zero input, zero floor and same-token pairs refused | `SwapWrapper._validate` | any token address | `minOut` is the only slippage bound there is | none | as above | 0.02s each |
| A well-formed request clears the whole guard block | `SwapWrapper._validate` | — | Non-vacuity anchor: all nine `_validate` rows are rejections | none | as above | 0.02s |

Every spend-guard row proves a *rejection*. That is a cost decision, not a gap:
a request that passes validation goes on to `PubInputs.compress`, which no
solver here finishes, while a rejected one never reaches it. Each is pinned to
the specific revert selector, so a fixture that silently stops being valid fails
rather than passing vacuously on "it reverted somehow".

Runtimes are solver time from a local `just halmos` run, excluding the build.
Nearly every property is sub-second; `halmos.toml` caps assertion solving at 30s so a
badly shaped proof surfaces as a failure rather than a slow CI job.

## What is deliberately not here

**`unitFee`'s bound, monotonicity, and rounding-cost inequalities.**
`fee <= units` for `bps <= BPS_DENOMINATOR`, monotonicity in either argument,
and the `fee * D >= num`/`fee * D < num + D` bracketing all time out at 120s on
both bundled solvers, and stay timed out with the arguments narrowed to uint32,
uint24 and uint16 — halmos words are 256-bit whatever the Solidity type, so the
blocker is the division, not the range. Each makes the solver reason *about*
`(units * bps) / D` instead of carrying it symbolically. All are arithmetic
corollaries of the ceiling-division characterization that is proved here, and
`test/fuzz/FeeConfig.fuzz.t.sol` samples them directly.

**Obvious type-width facts.** That `uint48 * uint16` cannot overflow a `uint256`
is settled by the types; it does not need an SMT query.

**Cryptography.** `PubInputs`, `SnarkCompression` and `BabyJubJub` are
keccak-heavy, assembly-heavy, or built on 254-bit field arithmetic. They stay
with the differential fuzz tests written for them. The protocol glue around a
proof — a reused nullifier rejected, a stale root rejected — is the part worth
proving, and the nullifier half of that is above.

**Whole-protocol paths.** Nothing here deploys a MASP. The unit and fuzz suites
reach `NullifierSet` and `CommitmentTree` through `MASPHarness`, which drags in
permit2, verifiers and the pool; symbolic execution explores every path of
everything it touches, so these tests use minimal harnesses instead.

## Triage: what belongs here and what does not

A candidate list of ~200 properties was assessed against the code and against
measured solver behaviour. The verdicts below are the reasoning, so a property
rejected here is not re-proposed later without new information.

Three findings drive most of the rejections.

**Division of a symbolic product is the hard wall.** `unitFee`'s bound and
monotonicity time out at 120s on both bundled solvers, and stay timed out at
`uint32`, `uint24` and `uint16` arguments — halmos words are 256-bit whatever
the Solidity type. Anything reaching `Math.mulDiv(n, g, s, r)` (all of
`YieldOps`' unit conversion) or `(publicIn * scale * fbps) / BPS` (the fee legs)
is out for the same reason, at any width.

**`keccak256` is cheap and exact — but only between symbolic hashes.** Halmos
models it as an uninterpreted function with an injectivity axiom, so "the digest
binds field X" is provable for *all* preimages at about the cost of one concrete
hash. This is where the suite earns the most: a fuzzer can only sample
forgeries.

The axiom relates uninterpreted hash terms **to each other**. It does not tie
such a term to a hash that halmos evaluated concretely. A test that stores a
digest built from an entirely concrete preimage and then compares it against a
symbolic one is therefore unsound in the permissive direction: `escrowed[id]`
holds a literal constant, the solver may choose a symbolic preimage whose
uninterpreted hash equals that literal, and a correct contract fails with a
forged counterexample. Both escrow proofs were written that way first and failed
exactly so.

The rule: **whenever a proof compares a stored digest against a symbolic
preimage, at least one field of the stored digest's preimage must also be
symbolic.** `MASPEscrow.symbolic.t.sol` submits its escrow with a symbolic `cm`
for this reason, which also makes each proof strictly stronger — it now holds for
every submitted commitment rather than one.

**Guards that revert early are cheap; the happy path often is not.** A rejected
spend never reaches `PubInputs.compress`, and a rejected flush never reaches
phase 3's verifier, so negative proofs about request validation and digest
binding cost nothing while their positive counterparts are intractable.

### Accepted

| Cluster | Properties | Why it earns a proof |
| --- | --- | --- |
| Escrow digest binding | No preimage but the submitted one cancels or flushes; replay rejected; delay measured from the bound `submittedAt`; contract payer is self-service only; a rate change cannot re-rate a pending deposit | The whole record is one hash. Every guarantee about a pending deposit reduces to that equality, and keccak injectivity makes the universal statement affordable |
| Nullifier bitmap | Consume marks exactly one; no aliasing across any pair; double-consume always reverts; a reverted consume changes nothing | Bucket/bit aliasing over all 2^256 pairs — the fuzzer draws pairs, this quantifies over them |
| Asset registry | Add-only over the whole owner surface; per-id isolation of fee and disabled changes; the accept/reject boundary on scale and rates; withdraw rate cannot rise during the upgrade window | Statements about mapping keys and an authority surface, with no arithmetic anywhere |
| Access control | No non-owner call moves the treasury or owner, over `svm.createCalldata` rather than an enumerated list | Covers a function added tomorrow the moment it compiles |
| Root ring buffer | Index stays in range and matches `currentRoot()`; re-pushed root stays known; previous root survives | Power-of-two masking and the eviction guard |
| Spend request guards | `pi.relayer == msg.sender`; nullifiers pairwise distinct; `isDeposit` pinned to zero; `outCm`/`outCvDep` cross-bound to the tree-update proof; unknown root and stale `oldRoot` rejected | These, not the circuit, cross-bind two independent Groth16 proofs. All revert before `compress`, so they are cheap |
| Aux length and mask guards | Ciphertext length bounds; clue bits confined to 14 | Reverts before the curve checks |
| Fee rounding | `unitFee` is exactly `ceilDiv`; zero only on zero input | Pins a hand-rolled form to an audited reference |

### Rejected: intractable

Symbolic division, symbolic-times-symbolic products, or 254-bit field
arithmetic. All stay with the fuzz suite, which is the right tool for them.

- Every yield accounting and rounding property — `index` positivity, rounding
  direction on withdraw/cancel/shield conversions, round-trip solvency,
  normalized-supply conservation through rebalance, performance-fee accrual
  amounts. All route through `Math.mulDiv`.
- `unitFee` bound, monotonicity, and the one-unit rounding bracket. Corollaries
  of the ceiling-division characterization that *is* proved.
- All of `PubInputs`: Fiat-Shamir compression, field cleaning, transcript
  binding, polynomial evaluation. Assembly, keccak and `mulmod` folding over
  50-69 words; already covered by a differential fuzz test against a reference.
- Curve checks in `AuxValidation` — on-curve, low-order, valid-point acceptance.
  `BabyJubJub` is `mulmod` over a 254-bit prime.
- Any *successful* spend or flush: both run `compress` on the way through.

### Rejected: nothing to prove

- **Groth16 verifier behaviour** — valid proof accepted, invalid rejected,
  components not substitutable. The verifier must be mocked for anything else
  to be tractable, and a mocked verifier proves only what the mock was told to
  return. Pairing correctness is not a solver question.
- **"Public inputs passed in the correct order"** — would need `compress` to run.
- **Type-width facts** — that `uint48 * uint16` cannot overflow a `uint256` is
  settled by the types.

### Rejected: better served by another tool

- **Root eviction after 64 advances, index wrap-around at the ring boundary.**
  Needs 65 sequential calls; the state is concrete and the existing invariant
  suite already walks it. Symbolic execution adds nothing over a loop.
- **Whole-protocol paths** — deposit → flush → spend → withdraw sequences,
  balance conservation across a full lifecycle. That is what
  `test/invariant/MASP.flow.invariant.t.sol` is for.
- **Venue and ERC-4626 boundary behaviour** — a venue reporting odd asset
  counts, withdrawals exceeding available assets. Needs an adversarial venue
  mock; stateful fuzzing explores it better than a bounded symbolic run.

### Deferred, not rejected

All three items previously listed here have been built, two of them in full.
What remains of them, and what was never on the list:

1. **The `SwapWrapper` execution path** — slippage (`InsufficientOut`), the
   withdraw receipt floor (`InsufficientWithdraw`) and the closing leftover
   invariant (`LeftoverBalance`). `_validate`'s nine guards are proved above and
   need no router mock, because all nine revert before `POOL.withdraw`. These
   three do not: each sits past a completed spend, which runs
   `PubInputs.compress`, so they are out for the same reason every other
   accepting spend path is. They stay with `test/swap/`.
2. **The two Uniswap adapters** — that only the wrapper may drive the callbacks.
   Cheap comparisons, but each needs a router mock, and `UniV4Adapter`'s
   unlock/callback shape needs a stateful one.
3. **`LelantosGovernor` and `FeeBurner`** — still untouched. The governor is
   mostly OpenZeppelin, whose own suite covers the voting arithmetic; what would
   earn a proof here is the wiring, not the base contracts. `FeeBurner`'s
   slippage bound routes through a swap quote, which is the division wall again.

`ProtocolAdmin` was called out here as the most worthwhile of the three, and it
proved to be: `execute`'s selector gate is the single comparison standing
between a governance proposal and an unowned, permanently unadministrable pool.
Deleting either selector from that gate is caught by three separate rows above.

The spend half of the disabled-asset rule — that a disabled asset stays
spendable and withdrawable so notes and escrows can exit — is out of reach for
the same reason as every other accepting spend path, and stays in
`test/masp/MASP.assets.t.sol`.

### Traps worth knowing before adding any of these

Both were hit while building the suite, and both produce a proof that looks
green while establishing less than it claims — or a failure against correct code.

**A `[PASS]` with a loop-bound warning is not a pass.** At `--loop 4`, three
spend-guard proofs covered only a prefix of the arrays they quantified over and
still reported `[PASS]`; one reported "all paths have been reverted". Raising
the bound to 16 took one from 5 explored paths to 71. Read the warnings.

**A revert-only assertion can pass vacuously.** `assertFalse(ok)` is satisfied by
a fixture that reverts for an unrelated reason, and several guard proofs explore
a single path, where that is invisible. `_assertRejected` in `GuardAsserts.sol`
is where that requirement lives; every rejection proof here pins the
revert selector for this reason, and the deposit guards additionally assert that
the unmodified fixture *is* accepted.

**Account balances start symbolic.** `assertEq(address(x).balance, 0)` is not
provable even for a contract that has never been paid — halmos gives every
account an unconstrained starting balance, and forced ether makes a zero balance
untrue of the real contract anyway. Compare a delta across the call instead, as
`check_receive_rejectsEverySenderButWrappedNative` does.

**A stand-in can revert before the guard under test.** The token backing the
satellite proofs credits a refund into a balance that already holds the
satellite's seed, and Solidity's checked addition reverts on a sum that wraps —
so a proof quantifying over *every* refund above `type(uint96).max` failed
against correct code, having never reached the width guard it was about. The
counterexample names the mock's arithmetic, not the contract's. Constrain the
symbolic value to what the fixture can actually deliver, and say why in the
assumption, or the next reader will read the bound as a weakened property.

Relatedly: two of those proofs first reported "all paths have been reverted"
because the satellite's record was seeded without marking the escrow live on the
pool, so every path died on `DepositAlreadySettled`. Halmos reports that as a
warning beside a `[PASS]`, which is the vacuity trap above wearing a different
hat — the run is only clean when the warning count is zero.

**`svm.createCalldata` does not terminate on a contract with an expensive entry
point.** It enumerates the whole external surface, so on `MASP` it reaches
`transfer` and `withdraw` — and because the verifier is mocked to accept, those
paths *succeed* into `PubInputs.compress` rather than reverting. The result is a
proof that runs forever: `solver-timeout-assertion` bounds each solver query, not
path exploration, so there is no timeout to catch it. Use it on contracts whose
every function is cheap (`AssetRegistry`, `FeeConfig`); elsewhere enumerate the
calls that can write the state in question and say so, as
`check_ownerConfigurationCannotMoveAVenue` does.

## Layout

`GuardAsserts.sol` holds `_assertRejected`, the two-line assertion almost every
property here ends with: the call failed, and it failed with the selector of the
guard under test. Every suite extends it, directly or through `PoolFixture`.

It began on `PoolFixture`, which put it out of reach of the nine suites that
deploy no pool — they each re-spelled the pair inline, in fifty-three places. It
is a base contract rather than a library because both assertions come from
forge-std's `Test`, which a library cannot inherit.

`PoolFixture.sol` holds what the proofs that drive a real `MASP` share: the
`deployMockedPool` wiring (both Groth16 verifiers and Permit2 mocked, with the
reasoning for each), the constants, the deposit request, and `_submit`'s
symbolic-`cm` escrow. Five suites were each carrying their own copy of that.

Neither has `Symbolic` in its name, deliberately: `match-contract` in
`halmos.toml` scopes a run to contracts matching that word, and shared
scaffolding is not a test.

Suites that drive a pool extend it. The rest deploy one small harness of their
own — `AssetRegistry`, `NullifierSet`, `CommitmentTree`, `FeeConfig`,
`AuxValidation` — or need a differently shaped fixture and reuse only the
wiring, as `NativeAdapter` does with its wrapped-native pool.

The three peripheral suites deploy no pool at all, because none of their
properties are about what the pool does:

- `ProtocolAdmin` drives two `MockAdminTarget`s. Ownership on them is real
  `Ownable`, since the property under proof is that `execute` cannot move it,
  and a stubbed owner would prove nothing about the selector guard.
- `MaspEscrowSatellite` drives `MockEscrowPool` over `MockEscrowToken`, whose
  pull and refund amounts are both settable so the proofs can quantify over
  every amount the pool might move. The satellite is abstract and both functions
  under proof are internal, so `SatelliteHarness` in that file supplies the
  external wrappers.
- `SwapWrapper` needs only a constructor argument: all nine `_validate` guards
  revert before the first pool call.

## Adding a property

1. Name it `check_*` — halmos only collects that prefix (and `invariant_`).
   forge-lint's `mixed-case-function` objects to every such name; the directory
   is listed in `[lint].ignore`, but that key is inert in both forge 1.5.1 and
   1.8.1, so expect the warnings either way. They are warnings only, and no CI
   job reads them.
2. Put it in a `*Symbolic*` contract; `match-contract` in `halmos.toml` scopes
   the run to those.
3. Add a row to the matrix above.
4. If it times out, reshape it before touching the timeout. Look for symbolic
   division or modulo, a symbolic-times-symbolic product, an unmocked
   dependency, or a loop with a symbolic bound.

When you delete a symbolic test, delete `out/halmos/<file>.sol` with it. Halmos
runs from build artifacts, and `forge build` does not prune the artifact of a
source that no longer exists — a removed test otherwise keeps running, and keeps
failing, with nothing in `test/symbolic/` to explain it.
