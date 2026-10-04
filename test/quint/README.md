# Quint suite

Model-based tests. Each spec under [`spec/`](../../spec) is an executable model of one contract. The Quint simulator generates traces from the model, and the tests here replay those traces against the contract, asserting the model's expected state after every step.

Tooling is [quint-sol-connect](https://github.com/lelantos-org/quint-sol-connect), vendored as the `lib/quint-sol-connect` submodule. The submodule commit pins its version.

## Running

| Command | Effect |
| --- | --- |
| `just quint-test` | Replay the committed traces. They are ordinary Foundry tests and also run under `just test`. |
| `just quint-gen [spec]` | Regenerate trace fixtures and generated Solidity. Requires `node` and `quint`. |
| `just quint-check` | Fail if the committed traces drifted from the config. |
| `just quint-diff` | Check that regeneration is a no-op on unchanged specs. |
| `just quint-fresh` | Generate fresh random traces and replay them. |
| `just quint-spec` | Typecheck the specs. |
| `just quint-install` | Install the quint toolchain into `lib/quint-sol-connect`. |

Replay requires neither `node` nor `quint`.

## Specs

| Spec | Target | Actions | Abstracted | Traces × steps |
| --- | --- | --- | --- | --- |
| `commitment_tree.qnt` | `CommitmentTree` | `advance` | Poseidon: roots are small integers | 2 × 91 |
| `delayed_upgrade_proxy.qnt` | `DelayedUpgradeProxy` | queue, cancel, activate, activateTooEarly, pause, reset, changeAdmin, advanceTime | The implementation (V1/V2 by `version()`), caller identity | 8 × 77 |
| `nullifier_set.qnt` | `NullifierSet`, through `test/utils/NullifierSetHarness.sol` | consume, consumeSpent | Nothing | 6 × 25 |
| `masp.qnt` | `MASP` behind its proxy, with Permit2 and a mock ERC-20 | submit, flush, cancel, cancelTooEarly, sweep, advanceBlocks, setCancelDelay, setAssetDisabled | Groth16, Permit2, ERC-1271, the root ring | 20 × 97 |
| `fee_burner.qnt` | `FeeBurner` | accrueFees, buy, wait, setLot, setPaused, setDecayParams | `harvest` and the pool, `restartMultBps` changes, multiple lot tokens | 8 × 97 |

## Properties

All properties are asserted after every step.

**`CommitmentTree`**

- `rootIndex` stays within the ring across a wrap.
- The live root is known.
- Every root in the ring is known (`inv_ringRootsAreKnown`), including roots held in more than one slot.
- No root that has left the ring is known.
- The ring contents match the model slot by slot.

**`DelayedUpgradeProxy`**

- The exit window equals the delay plus every pause inside it and contains `UPGRADE_DELAY` unpaused seconds (`inv_exitWindowIsUnpaused`), across the `queue; pause`, `pause; queue` and cancel-and-requeue orderings.
- An activation promotes the implementation. `implVersion` is read through the proxy.

**`NullifierSet`**

- The spent set matches the bitmap after every consume.
- A second consume reverts `DoubleSpend` and changes nothing.

**`MASP`**

- `poolBalance == pendingPrincipal + pendingFee + shieldedPrincipal + accruedFee` (`inv_balanceConservation`).
- `committedCount == 2 × flushed` (`inv_committedCountMatchesFlushed`).
- A pending deposit's fee is not accrued: `accruedFee + treasuryBalance == fees of flushed deposits` (`inv_feeNeverEscrowed`).
- A refund is exactly principal plus fee (`inv_refundsAreExact`).
- A cancel before the delay reverts `CancelTooEarly` (`inv_cancelGuardsRespected`).
- `cancelDelay` is read live. A shortening applies to deposits in flight; a lengthening is queued and leaves the live delay unchanged. The commit is not modelled.
- Disabling an asset blocks new deposits only. Flush and cancel stay enabled.

**`FeeBurner`**

- The asking price falls monotonically while the clock runs.
- Total `govIn` lies between the cost basis and the cost basis plus one unit per fill.
- The restart ratchet never leaves the lot cheaper.
- Only a fill of at least `minLot` with non-zero weight re-anchors.
- `setDecayParams` does not reprice a running lot.
- Governance-token supply falls by exactly the amount burned.

## Scope

Not modelled:

- Hashing. Roots are opaque integers; the model covers eviction, the known-root set and the leaf count.
- The spend path. `withdraw` and `transfer` require Groth16 proofs.
- Multi-deposit and multi-asset batches. The model flushes one deposit of one plain asset.
- Yield assets, upgrades and pausing in the `MASP` model.
- `FeeBurner.harvest` and `burnAccruedGov`. Fee tokens arrive at the burner directly. `minLot` and `restartMultBps` are fixed, and one lot token is modelled.
- `LelantosGovernor` and `TimelockController`.

Domains are small by design. The root domain makes an evicted value usually still present elsewhere in the ring. The seven nullifier values share bit positions across buckets (see the table in `spec/nullifier_set.qnt`).

## Ghost variables

Specs carry ghost variables (`advances`, `insertedTotal`, `consumeCount`, `guardViolations`, `costBasis`, and others) that track a quantity independently of the state it is checked against, so that an invariant is not an arithmetic consequence of the transition it checks. They are listed in `ignoreState` with a reason, since no on-chain value corresponds to them; the generator copies the reasons into the generated `State` struct.

Ghost variables detect an inconsistent edit to the model. Agreement between the model and the contract is established by the replay.

## Triage

A failure prints the diverging fields, the step, the action, the trace path and a reproduce command.

1. Reproduce: `QUINT_VERBOSE=2 forge test --match-test <name> -vvv`.
2. Read the model's intent at that step in ITF. One `exemplar.itf.json` is committed per spec and opens in the [ITF Trace Viewer](https://marketplace.visualstudio.com/items?itemName=informal.itf-trace-viewer). For any other trace, `just quint-gen <spec> --itf <n>` writes its companion to the git-ignored `test/fixtures/quint/<spec>/.itf/`. The command fails if the local quint version differs from the version the fixture records.
3. Classify by shape. A model bug usually diverges early and in many traces; a contract bug usually diverges deep and in one.
4. Classify by kind. An `ENABLEDNESS DIVERGENCE` means the model allowed an action and the contract reverted, or a negative action's `expectRevert` did not fire. The report decodes the revert string. A state divergence with both sides succeeding points to the contract or to a disagreement about semantics.
5. Classify by provenance. If the diverging field is built by `_project()` from driver-local state rather than a live read, check the driver first. Drivers cross-check such fields with a `require`.
6. For an independent verdict, restate the property in `test/symbolic/`.
7. Copy the trace to `test/fixtures/quint/<spec>/regression/` and commit it.

## Adding a spec

1. Write `spec/<name>.qnt`. `--mbt` requires that:
   - `step` is `any { … }` over bare named actions;
   - every `nondet` draws from a constant non-empty domain, with the guard inside the action;
   - a pick name has one type across all actions.
2. Factor frame conditions into named `unchangedX` actions grouped by what the variables describe, and conjoin them. An action that writes part of a group spells out the rest (`flush` in `spec/masp.qnt`, `cancelUpgrade` in `spec/delayed_upgrade_proxy.qnt`).
3. Add an entry to [`quint-sol-connect.config.mjs`](../../quint-sol-connect.config.mjs) giving the Solidity type of each state variable and each pick.
4. Run `just quint-gen <name>`.
5. Write the driver: `setUp`, `_apply`, `_project`. Prefer live reads. Where the contract exposes none, shadow the value and `require` the shadow against the nearest observable.
6. Fault-inject: change the spec so it disagrees with the contract, regenerate, and confirm the failure names the right field at the right step. Revert the change.
7. Add the spec to the tables above and list anything left out under [Scope](#scope).

Notes:

- In Quint, `x' = a or b` parses as `(x' = a) or b`, a nondeterministic choice between two actions. Parenthesise the right-hand side.
- Do not read `block.timestamp` directly in `_project`. It is inlined into the replay loop, and under `via_ir` the optimizer hoists the read. Read it through an external call (`this.quintNow()`).
