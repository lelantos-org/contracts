# Symbolic suite

Halmos proves each `check_` function for every input in a bounded state space.

```sh
just halmos                    # prove the suite
just halmos-match <pattern>    # prove the tests matching a name pattern
```

Configuration is in `halmos.toml` and the `[profile.halmos]` block of `foundry.toml`. `halmos.toml` caps assertion solving at 30 s.

## Contents

- [Scope](#scope)
- [Properties](#properties)
- [Layout](#layout)
- [Authoring notes](#authoring-notes)
- [Adding a property](#adding-a-property)

## Scope

The suite covers properties that hold for all inputs and need no symbolic division or field arithmetic: digest binding, bitmap aliasing, mapping-key isolation, access control, request guards, and the shape of public-input compression.

Rejection proofs pin the specific revert selector. Every `MASP` spend-guard property except the fixture anchor is a rejection, since an accepted spend continues into `PubInputs.compress`.

Not covered here:

| Area | Reason | Covered by |
| --- | --- | --- |
| `unitFee` bound, monotonicity and rounding bracket; yield accounting; fee legs | Division of a symbolic product (`Math.mulDiv`) does not solve at any width | `test/fuzz/`, `test/yield/` |
| Values `PubInputs` computes; `SnarkCompression`; `BabyJubJub` curve checks | 254-bit field arithmetic and keccak modulo `R` | Differential fuzz tests against `compressRef`; `PubInputsSpendTest` |
| Accepting spend and flush paths, including the `SwapWrapper` execution path and spends of a disabled asset | They run `PubInputs.compress` over symbolic input | `test/masp/`, `test/swap/` |
| Groth16 verifier behaviour | The verifiers are mocked | `test/verifiers/` |
| Multi-call sequences: root eviction after 64 advances, full deposit-to-withdraw lifecycles | Concrete state reached by long call sequences | `test/invariant/`, `test/quint/` |
| Venue and ERC-4626 boundary behaviour | Requires an adversarial stateful mock | `test/yield/` |
| `UniV3Adapter`, `UniV4Adapter`, `LelantosGovernor`, `FeeBurner` | No symbolic tests | Their unit and invariant suites |

## Properties

### `Fees.unitFee`

Mocked: none.

| Property | Domain | Assumptions |
| --- | --- | --- |
| `unitFee == ceilDiv(units * bps, D)` | `uint48 × uint16` | none |
| The fee is zero only for a zero base or rate | `uint48 × uint16` | none |

### `NullifierSet`

Mocked: none.

| Property | Domain | Assumptions |
| --- | --- | --- |
| A consume marks exactly its own nullifier spent | `bytes32` | none |
| Consuming one nullifier leaves every other unspent | `bytes32 × bytes32` | `a != b` |
| Two distinct nullifiers both stay spent | `bytes32 × bytes32` | `a != b` |
| A second consume reverts `DoubleSpend` | `bytes32` | none |
| A reverted double-consume leaves the bitmap unchanged | `bytes32 × bytes32` | `a != b` |
| Spent is permanent | `bytes32 × bytes32` | `a != b` |

### `CommitmentTree`

Mocked: none.

| Property | Domain | Assumptions |
| --- | --- | --- |
| An advance sets the current root, marks it known and moves the count | `bytes32 × uint32` | none |
| `rootIndex` stays in the ring and matches `currentRoot()` | two advances, any roots | none |
| Re-pushing the same root leaves it known | `bytes32` | none |
| The previous root stays known | `bytes32 × bytes32` | `r1 != r2` |

### `FeeConfig` and `OwnableInit`

Mocked: `MockERC20`.

| Property | Domain | Assumptions |
| --- | --- | --- |
| No non-owner call moves the treasury or the owner | any caller, any calldata (`svm.createCalldata`) | caller is not owner; call succeeded |
| `setTreasury` rejects every non-owner | any caller, any destination | caller is not owner |
| The owner may set exactly the non-zero destinations | any destination | none |
| Accrual is additive | `uint120 × uint120` | sum within the funded balance |
| Sweep drains exactly the accrual, to the treasury, once | `uint120 × uint120` | sum within the funded balance |
| Ownership cannot be dropped | any owner calldata | call succeeded |

### `AssetRegistry`

Mocked: none.

| Property | Domain | Assumptions |
| --- | --- | --- |
| Registration is accepted for exactly the valid inputs | any id, token, scale and rates | none |
| `addAsset` rejects id 0 with `ZeroAssetId` | any token, scale and rates | none |
| Id 0 is never registered | any owner calldata (`svm.createCalldata`) | call succeeded |
| A registered id's token and scale never change | any id, any owner calldata | `id != 0`; call succeeded |
| A fee or disabled change touches only the named id | any two distinct ids | `id != other`, neither zero |
| A withdraw-rate raise does not take effect in the call that sets it; a decrease does | any start, target and deposit rate | rates within the 20% cap |
| A decrease drops a queued withdraw-rate raise | any start, queued and lowered rate | rates within the 20% cap |

### `MASP` escrow

Mocked: Permit2, both verifiers.

| Property | Domain | Assumptions |
| --- | --- | --- |
| No preimage other than the submitted one cancels an escrow | all 11 caller-supplied digest fields | mismatching preimages |
| Neither note's `inner` can be replaced at cancel (`DigestMismatch`) | any pair of replacement words | pair differs from the submitted one |
| An escrow is consumed once | any submitted `inner` | none |
| The cancel delay holds at every block height | any height at or after submission | `height >= submittedAt` |
| A contract payer's escrow can be cancelled only by the payer | any caller | `caller != payer` |
| A rate change does not re-rate a pending deposit | any new rate | within the cap, differs from the old rate |
| `setCancelDelay` accepts exactly its range and is owner-only; only a shortening applies at once | any delay, any caller | none |

### `MASP` deposit guards

Mocked: Permit2, both verifiers.

| Property | Domain | Assumptions |
| --- | --- | --- |
| A deposit request is accepted only when well formed | any amount, fee note, party, `inner`, chain id, asset id | one field broken per proof |
| `depositAuthorized` is callable only by the payer | any caller | `caller != payer` |
| A disabled asset takes no new deposits | concrete | none |

### `MASP.flushBatch`

Mocked: Permit2, both verifiers.

| Property | Domain | Assumptions |
| --- | --- | --- |
| No preimage other than the submitted one flushes an escrow | 8 fields across `meta` and `tpi` | mismatching preimages |
| A cancelled escrow cannot be flushed | any submitted `inner` | none |
| One id cannot be drained twice in a batch | any submitted `inner` | none |
| Flush rejects wide leaf amounts, a mismatched fee asset, non-deposit leaves, a misplaced batch and a wrong leaf count | any value in each | one field broken per proof |

### `MASP` spend guards

Mocked: both verifiers.

| Property | Domain | Assumptions |
| --- | --- | --- |
| A transfer names no asset | any asset id, registered or not | `assetId != 0` |
| A transfer withdraws nothing | any `publicOut`, any asset id | `publicOut != 0` |
| The spend fixture is accepted | concrete | none |
| A nullifier repeated in any two input slots is rejected | any 4-nullifier vector | some pair equal |
| An unknown root, a known root at the wrong slot, an out-of-range anchor slot and a misaligned `startIndex` are rejected | any root and index | differs from the live value |
| `pi.relayer` must be `msg.sender` | any relayer and caller | `relayer != caller` |
| A proof for another chain is rejected | any chain id | `chainId != block.chainid` |

### `MASP` pause

Mocked: Permit2, both verifiers.

| Property | Domain | Assumptions |
| --- | --- | --- |
| A pause halts spends for exactly its window | every duration and timestamp | within `MAX_PAUSE` |
| An escrow stays cancellable throughout a pause | every duration, every point inside | inside the window |
| `sweep` stays open throughout a pause | every duration, every point inside | inside the window |

### Yield binding

Mocked: venue and vault.

| Property | Domain | Assumptions |
| --- | --- | --- |
| A bound venue never changes | any id, any replacement venue | `id` unregistered and non-zero |
| A plain asset cannot gain a venue | concrete | none |
| The venue must be pinned to this pool and hold this asset | any foreign pool, any vault asset | differs from expected |
| A venue backs at most one id | any two distinct ids | distinct, neither zero nor the plain id |
| Id 0 cannot be bound to a venue | concrete | none |
| Yield registration and configuration are owner-only | any caller | `caller != owner` |

### `AuxValidation`

Curve points are held concrete.

| Property | Domain | Assumptions |
| --- | --- | --- |
| The aux payload is accepted exactly when well formed | ciphertext lengths 0, 1, 2, 3, 255, 256, 257 | none |
| The clue-bits prefix is confined to 14 bits | any 2-byte prefix | prefix has a bit outside the mask |

### `DelayedUpgradeProxy`

Mocked: a lightweight implementation.

| Property | Domain | Assumptions |
| --- | --- | --- |
| Activation succeeds exactly after the window | every timestamp | `t >= T0` |
| A queued upgrade does not change the served implementation | every timestamp inside the window | inside the window |
| The queued implementation cannot be replaced, nor queued without code | any implementation address | none |
| A pause defers activation by its duration | every permitted duration | within `MAX_PAUSE` |
| An upgrade queued during a pause is deferred by the pause still to run | every permitted duration, every queue time | within `MAX_PAUSE`; `activationAt` fits `uint40` |
| The constructor accepts exactly a pause ceiling shorter than the window | any non-zero delay, any ceiling | `upgradeDelay > 0` |
| A pause is accepted for exactly its permitted durations; chained pauses each defer the window by their duration | any two durations | none |
| Activation is permissionless | any caller | none |
| A cancel clears the queue and never promotes | every later timestamp | none |
| Privileged entry points reject every non-admin | any caller | `caller != admin` |

### `NativeAdapter`

Mocked: Permit2, both verifiers.

| Property | Domain | Assumptions |
| --- | --- | --- |
| The adapter is the only permitted payer, recipient and relayer | any address in each role | differs from the adapter |
| Only the wrapped-native token may send native coin, and refused coin is not retained | any sender and amount | `sender != WETH` |

### `MaspEscrowSatellite`

Mocked: pool (`MockEscrowPool`) and token (`MockEscrowToken`).

| Property | Domain | Assumptions |
| --- | --- | --- |
| `_cancelAndVerify` rejects every misreported refund | any recorded × delivered × reported amount | `delivered != reported`, non-overflowing |
| `_cancelAndVerify` accepts every exact refund and forwards the delivered amount | any recorded × delivered amount | non-overflowing |
| A cancel cannot be replayed | any recorded amount | none |
| An unknown id and a settled deposit are refused, leaving the record intact | any id, any refund | none |
| `_escrowMeasured` bounds the pull on both sides and records it exactly in between | any pull, floor and ceiling | none |

### `SwapWrapper`

Mocked: pool stand-in.

| Property | Domain | Assumptions |
| --- | --- | --- |
| Only the withdraw proof's `payer` may call `swap` | any caller × any payer | `caller != payer` |
| Recipient, relayer and deposit payer must be the wrapper | any address in each role | differs from the wrapper |
| The adapter must be allowlisted and the deadline not passed | any adapter, every timestamp | none |
| Zero input, zero floor and same-token pairs are refused | any token address | none |
| A well-formed request passes `_validate` | concrete | none |

### `GenericCallWrapper`

Mocked: pool stand-in.

| Property | Domain | Assumptions |
| --- | --- | --- |
| Only the withdraw proof's `payer` may call `execute` | any caller × any payer | `caller != payer` |
| Recipient, relayer, output payer and refund payer must be the wrapper | any address in each role | differs from the wrapper |
| The refund is in the withdrawn token; no output is a yield asset; no two outputs share a token; neither receiver is the wrapper | any asset id and token | one field broken per proof |
| A well-formed request passes `_validate` | concrete | none |

### `PubInputs`

Mocked: none.

| Property | Domain | Assumptions |
| --- | --- | --- |
| `compress(Transact)`: the digest word is returned unmodified, `z` hashes all 38 words, `y` evaluates the 13 coefficients | all 19 raw calldata words, dirty bits included, and every clue coordinate | compression did not revert; ciphertexts concrete |
| `compress(TreeUpdateBatch)`: the same over 37 words and 36 coefficients, with each sub-word member masked to its width | all 37 raw calldata words | compression did not revert |
| `compressSpend` builds `[oldRoot, newRoot, startIndex, 6, outCm, zeros, st.digest]` and nothing else in the request reaches it | all 19 `Transact` words, any `SpendTree`, any root | compression did not revert |
| `compressSpend` yields the same challenge and digest as `compress(TreeUpdateBatch)` for the same batch | as above | neither reverted |
| Compression rejects exactly an out-of-field coefficient, and never the digest or a challenge-only word | all raw calldata words, both shapes | none |

## Layout

| File | Role |
| --- | --- |
| `GuardAsserts.sol` | `_assertRejected`: the call failed with the selector of the guard under test. A base contract extended by every suite. |
| `PoolFixture.sol` | For suites that drive a `MASP`: `deployMockedPool` (both Groth16 verifiers and Permit2 mocked), constants, the deposit request, and `_submit`, which escrows with a symbolic `inner`. |
| `*.symbolic.t.sol` | The suites. |

- `match-contract` in `halmos.toml` scopes a run to contracts whose name contains `Symbolic`. Shared scaffolding does not carry that word.
- Suites that drive no pool deploy a small harness of their own (`AssetRegistry`, `NullifierSet`, `CommitmentTree`, `FeeConfig`, `AuxValidation`, `PubInputs`).
- The satellite suites use `MockEscrowPool` in place of the pool. `MaspEscrowSatellite` is abstract, so `SatelliteHarness` supplies external wrappers for the internal functions under proof. In the `SwapWrapper` and `GenericCallWrapper` suites every `_validate` guard reverts before the first pool call.

## Authoring notes

- **Digest comparisons.** Halmos models `keccak256` as an uninterpreted function with an injectivity axiom that relates symbolic hash terms to each other, not to a concretely evaluated hash. When a proof compares a stored digest against a symbolic preimage, at least one field of the stored digest's preimage must also be symbolic.
- **Warnings.** A `[PASS]` accompanied by a loop-bound warning or "all paths have been reverted" does not establish the property. A run is clean only when the warning count is zero.
- **Rejections.** Use `_assertRejected` so the proof pins the revert selector, and assert that the unmodified fixture is accepted.
- **Reference terms.** The `PubInputs` proofs rebuild the expected `z` and `y` with the same operations in the same order as the library, so each comparison is between identical terms. A change to the evaluation surfaces as `[TIMEOUT]` rather than a counterexample. Keep `_evaluate` folding from the top coefficient down.
- **Balances.** Account balances start symbolic. Compare a delta across the call rather than an absolute balance (`check_receive_rejectsEverySenderButWrappedNative`).
- **Stand-ins.** Constrain symbolic values to what the fixture can deliver, so that a mock's checked arithmetic does not revert before the guard under test. State the reason in the assumption.
- **`svm.createCalldata`.** It enumerates the whole external surface. On `MASP` it reaches `transfer` and `withdraw`, which do not terminate under mocked verifiers; `solver-timeout-assertion` bounds solver queries, not path exploration. Use it on contracts whose every function is cheap (`AssetRegistry`, `FeeConfig`); elsewhere enumerate the calls that can write the state in question (`check_ownerConfigurationCannotMoveAVenue`).

## Adding a property

1. Name it `check_*`. Halmos collects only that prefix and `invariant_`. forge-lint reports `mixed-case-function` warnings for these names; no CI job reads them.
2. Put it in a contract whose name contains `Symbolic`.
3. Add a row to the tables above.
4. If it times out, reshape it before raising the timeout. Look for symbolic division or modulo, a product of two symbolic values, an unmocked dependency, or a loop with a symbolic bound.

When deleting a symbolic test, also delete `out/halmos/<file>.sol`. Halmos runs from build artifacts, and `forge build` does not prune the artifact of a removed source.
