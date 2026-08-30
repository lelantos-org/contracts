# Contract Reference

Source-level documentation for the Lelantos Multi-Asset Shielded Pool (MASP). This document describes what each contract in `src/` does, how they compose, and the exact sequence of checks each entry point performs.

For build instructions, gas figures, and deployed sizes, see the [repository README](../README.md).

---

## Table of Contents

- [Overview](#overview)
- [Module Map](#module-map)
- [Core State](#core-state)
  - [CommitmentTree](#commitmenttree)
  - [NullifierSet](#nullifierset)
  - [AssetRegistry](#assetregistry)
  - [FeeConfig](#feeconfig)
- [Proof Plumbing](#proof-plumbing)
  - [SnarkCompression](#snarkcompression)
  - [PubInputs](#pubinputs)
  - [AuxValidation and BabyJubJub](#auxvalidation-and-babyjubjub)
- [Flows](#flows)
  - [Shield: deposit escrow and batch flush](#shield-deposit-escrow-and-batch-flush)
  - [Spend: transfer and withdraw](#spend-transfer-and-withdraw)
  - [Fee accounting](#fee-accounting)
- [Escrow satellites](#escrow-satellites)
- [Shielded Swap](#shielded-swap)
- [Native coin](#native-coin)
- [Constants](#constants)

---

## Overview

The pool holds ERC-20 balances on behalf of a set of shielded *notes*. A note is a commitment `cm` inserted as a leaf of a quaternary Merkle tree; spending it publishes a nullifier `nf` and produces new commitments. Ownership, value conservation, and Merkle membership are proven in zero knowledge — the chain sees only commitments, nullifiers, and the public deposit/withdraw legs.

Two design choices drive most of the contract structure:

1. **Merkle insertion is proven, not computed.** The contract never hashes a Merkle path. A relayer computes the new root off-chain and submits a `tree_update_batch` proof; the contract verifies it and swaps the root. Per-transaction cost is therefore flat in tree depth.
2. **Public inputs are compressed before pairing.** Both circuits expose dozens of logical public signals. Each set is folded into a single pair `(y, z)` via a Fiat–Shamir challenge and a Horner evaluation, so every `verifyProof` call takes exactly two field elements regardless of the logical signal count.

Consequently every spend verifies **two** independent Groth16 proofs, and the contract — not the circuits — is what cross-binds them.

3. **The spend path verifies both proofs in one pairing call.** `BatchedGroth16Verifier` checks `E_1 · E_2^r2 = 1` over six pairing terms instead of two separate four-term checks, folding the `alpha`/`beta` and `gamma` terms the two circuits share. Measured saving: ~94k gas per spend. `r2` is a Fiat–Shamir coefficient over the full twenty-word calldata transcript, so the soundness error is about `2^-254`. `flushBatch` carries a single proof and uses the codegen verifier directly; its "batch" is a batch of leaves, unrelated to the batched pairing.

```mermaid
flowchart LR
  subgraph OFFCHAIN["Off-chain"]
    W["Wallet<br/>note secrets, FMD clues"]
    R["Relayer<br/>tree witness, batching"]
  end

  subgraph ONCHAIN["On-chain"]
    M["MASP"]
    V2["TreeUpdateBatch<br/>Groth16Verifier<br/>flush only"]
    BV["BatchedGroth16Verifier<br/>both spend proofs, one pairing"]
    P2["Permit2"]
    T["ERC-20"]
  end

  W -->|"proof + public inputs"| R
  R -->|"tx"| M
  M --> V1
  M --> V2
  M --> P2
  M --> T
  M -.->|"events: DepositEscrowed,<br/>NotePayload, RootAdvanced"| W
```

---

## Module Map

`MASP` is a single deployed contract composed by inheritance from four abstract state modules, plus three stateless libraries.

```mermaid
classDiagram
  class MASP {
    +mapping escrowed
    +IVerifier TREE_UPDATE_BATCH_VERIFIER
    +IBatchVerifier SPEND_VERIFIER
    +deposit()
    +depositAuthorized()
    +flushBatch()
    +cancelDeposit()
    +transfer()
    +withdraw()
  }
  class CommitmentTree {
    <<abstract>>
    +bytes32 roots
    +uint64 committedCount
    +mapping isKnownRoot
    #_advanceRoot()
  }
  class NullifierSet {
    <<abstract>>
    -mapping _spentBuckets
    +spent()
    #_consumeNullifier()
  }
  class AssetRegistry {
    <<abstract>>
    -mapping _assets
    +addAsset()
    +setAssetDisabled()
    +setAssetFee()
  }
  class FeeConfig {
    <<abstract>>
    +address treasury
    +mapping accruedFee
    +sweep()
    #_accrueFee()
  }
  class PubInputs {
    <<library>>
    +compress()
    +compressRef()
    +auxDigest()
  }
  class AuxValidation {
    <<library>>
    +validate()
  }
  class SnarkCompression {
    <<library>>
    +evaluatePolyAt()
  }
  class BabyJubJub {
    <<library>>
    +isOnCurve()
    +isLowOrder()
  }

  MASP --|> CommitmentTree
  MASP --|> NullifierSet
  MASP --|> AssetRegistry
  MASP --|> FeeConfig
  MASP ..> PubInputs
  MASP ..> AuxValidation
  PubInputs ..> SnarkCompression
  AuxValidation ..> BabyJubJub
```

| File | Role |
| --- | --- |
| [MASP.sol](MASP.sol) | Pool entry points, escrow ledger, proof cross-binding, token movement. |
| [CommitmentTree.sol](CommitmentTree.sol) | Lazy-root quaternary tree and 64-slot known-root ring buffer. |
| [NullifierSet.sol](NullifierSet.sol) | Packed-bitmap spent-nullifier set. |
| [AssetRegistry.sol](AssetRegistry.sol) | Owner-managed `assetId → (ERC-20, scale)` mapping. |
| [FeeConfig.sol](FeeConfig.sol) | Fee basis points, treasury, per-token accrual, permissionless `sweep`. |
| [libs/PubInputs.sol](libs/PubInputs.sol) | Public-input structs and Fiat–Shamir compression (calldata fast path + memory reference path). |
| [libs/AuxValidation.sol](libs/AuxValidation.sol) | Bounds and curve checks on per-output FMD payloads. |
| [SnarkCompression.sol](SnarkCompression.sol) | Horner evaluation over the coefficient vector, mod the BN254 scalar field. |
| [BabyJubJub.sol](BabyJubJub.sol) | On-curve and prime-order-subgroup checks on the twisted Edwards curve. |
| [verifiers/Verifier.sol](verifiers/Verifier.sol) | snarkJS codegen for `4x6` (`Groth16Verifier`). **Not deployed** — provenance for the `VK1_*` constants and the differential-test oracle. |
| [verifiers/TreeUpdateBatchVerifier.sol](verifiers/TreeUpdateBatchVerifier.sol) | snarkJS codegen for `tree_update_batch` (`TreeUpdateBatchGroth16Verifier`). |
| [verifiers/VerifyingKeys.sol](verifiers/VerifyingKeys.sol) | The thirty verifying-key constants, lifted verbatim from the two codegen files, plus the `BATCH_DOMAIN` transcript separator. |
| [verifiers/BatchedGroth16Verifier.sol](verifiers/BatchedGroth16Verifier.sol) | Hand-written assembly verifying both spend proofs in one pairing call. |
| [interfaces/](interfaces/) | `IVerifier`, `IBatchVerifier`, `IWrappedNative`, `IMASPPool` — the pool surface both adapters call, pinned to `MASP`'s selectors by `IMASPPool.t.sol`. |
| [MaspEscrowSatellite.sol](MaspEscrowSatellite.sol) | Abstract base for peripherals that escrow as their own `payer`: Permit2 arming, balance-delta escrow measurement, escrow record, cancel-and-verify. |
| [native/](native/) | `NativeAdapter`: wraps native coin into the deposit path and unwraps it out of the withdraw path. The pool itself is ERC-20 only. |
| [swap/](swap/) | Atomic unshield → swap → re-shield wrapper, plus the Uniswap v3 and v4 adapters. |

`NativeAdapter` and `SwapWrapper` both extend `MaspEscrowSatellite`; see [Escrow satellites](#escrow-satellites).

`Verifier.sol` and `TreeUpdateBatchVerifier.sol` are generated output and carry `SPDX-License-Identifier: GPL-3.0` with their own upstream terms; everything else, `VerifyingKeys.sol` and `BatchedGroth16Verifier.sol` included, is MIT.

---

## Core State

### CommitmentTree

A depth-11, arity-4 tree holding up to `4^11 = 4_194_304` leaves. The contract stores no internal nodes — only a ring buffer of the last 64 roots, a membership map, and the number of leaves baked into the latest root.

`_advanceRoot` is the sole mutator, and its callers must already have verified a tree-update proof and that `oldRoot == currentRoot()`.

```mermaid
flowchart TD
  A["_advanceRoot(newRoot, inserted, oldRoot)"] --> B["newIdx = (rootIndex + 1) mod 64"]
  B --> C{"evicted slot nonzero<br/>and != newRoot?"}
  C -->|yes| D["isKnownRoot[evicted] = false"]
  C -->|no| E["keep evicted marked known"]
  D --> F["roots[newIdx] = newRoot<br/>isKnownRoot[newRoot] = true"]
  E --> F
  F --> G["rootIndex = newIdx<br/>committedCount += inserted"]
  G --> H["emit RootAdvanced"]
```

`rootIndex` and `committedCount` share a storage slot. Both are read at the top of `_advanceRoot` and written together at the bottom, with the `roots` and `isKnownRoot` writes in between, so the pair costs one `SLOAD` and one `SSTORE` rather than two of each. Splitting those writes apart puts an unrelated store between them and the optimizer stops fusing them, which is worth roughly 200 gas on every `transfer`, `withdraw` and `flushBatch`.

The `evicted != newRoot` guard matters: if the same root value occupies two slots in the buffer, clearing on eviction would mark a still-live root unknown and invalidate proofs built against it.

Spends prove membership against `pi.merkleRoot`, which need only be in `isKnownRoot` — any of the last 64 roots. The *update* leg is stricter: `tpi.oldRoot` must equal `currentRoot()` exactly, and `tpi.startIndex` must equal `committedCount`. Insertions therefore serialize, while proof generation tolerates a 64-root lag.

```mermaid
flowchart LR
  subgraph RING["roots[64] ring buffer"]
    direction LR
    R0["r_n-2"] --> R1["r_n-1"] --> R2["r_n (currentRoot)"] --> R3["next slot<br/>(evicted on write)"]
  end
  S["Spend proof"] -.->|"membership vs any<br/>isKnownRoot entry"| R0
  U["Tree update"] -->|"oldRoot must equal"| R2
  U -->|"writes"| R3
```

### NullifierSet

Spent nullifiers are stored as a packed bitmap: `_spentBuckets[nf >> 8]` holds 256 flags keyed by `nf & 0xff`. A spend consumes `TRANSACT_IN = 3` nullifiers; a repeat within the same word costs no extra storage slot.

Two distinct guards apply:

- `DuplicateNullifier` — raised in `_validateRequest` by a pairwise comparison across all three input slots, blocking the same note being spent twice *within one transaction*.
- `DoubleSpend` — raised in `_consumeNullifier` when the bit is already set, blocking a spend *across transactions*.

The pairwise loop is required rather than a single adjacent comparison: at `N_IN = 3`, checking only `[0] != [1]` would leave the third slot free to repeat either.

### AssetRegistry

Maps a circuit-visible `uint64 publicAssetId` to an ERC-20 address and a `scale` factor converting circuit units to token base units. The registry is **add-only**: `addAsset` reverts on a duplicate id, and there is no removal path. An asset may be *disabled*, which blocks new deposits (`_validateDeposit`) while leaving existing notes and escrows spendable so funds can always exit.

`scale` is bounded to `1e18` and must be nonzero. The hot path uses two lookups deliberately: `_getAsset` reads both slots, while `_requireAssetKnown` — used by `transfer`, which moves no tokens — touches only slot 0 and skips the cold `SLOAD` for `scale`.

### FeeConfig

Rates are **per asset**, not pool-wide: every `AssetEntry` carries its own `depositBps` and `withdrawBps`, set when the asset is registered and changed only by `setAssetFee(id, …)`. Both are capped at `MAX_FEE_BPS = 2000` (20%), and a stored `0` means zero — there is no fallback and no sentinel, so a fee change reaches exactly the ids named in the call. The constructor's rate argument is a starting value written into each genesis entry, not retained state. Fees accumulate per token in `accruedFee` and are drained by `sweep`, which is permissionless — anyone may call it, but the destination is owner-pinned to `treasury`.

`FeeConfig` also supplies the `ReentrancyGuardTransient` base used by every state-mutating entry point.

The critical invariant: **escrowed principal is never counted as accrued fee.** A deposit locks `inAmt + fee + the relayer note's value` in the pool without touching `accruedFee`; only the treasury's `fee` is ever accrued, and only when `flushBatch` commits the leaves; `cancelDeposit` refunds all three together, since no leaf was minted and so nobody earned the relayer's share. The relayer's portion is never accrued at all — it stays pool principal, because the note minted against it is spendable only while the pool still holds the tokens behind it. A sweep can therefore never drain a depositor's refundable balance.

---

## Proof Plumbing

### SnarkCompression

`evaluatePolyAt(coefficients, z)` evaluates the coefficient vector as a polynomial at `z` by Horner's method over the BN254 scalar field `R`. Soundness rests on Schwartz–Zippel: because `z` is drawn by Fiat–Shamir *after* the prover has committed to the coefficients, a prover substituting a different public-input vector succeeds with probability at most `deg(p) / R`.

The inner loop is unrolled by two and reverts `CoefficientOutOfField` in place on any word `>= R`. Both operands of a pair are range-checked before either is folded in, so an out-of-field coefficient can never influence the result.

### PubInputs

Defines the three public-input structs and the compression that turns each into the `(y, z)` pair the verifiers consume.

| Struct | Circuit | Coefficients |
| --- | --- | --- |
| `Transact` | `4x6` | 69 = 50 calldata words + `3 × TRANSACT_OUT` clue words + 1 aux digest |
| `TreeUpdateBatch` | `tree_update_batch` | 52 = `4 + 6 × MAX_L_BATCH` |
| `DepositRequest` | — (Permit2 witness only) | n/a |

```mermaid
flowchart TD
  A["Transact calldata<br/>(32 static words)"] -->|calldatacopy| B["memory image:<br/>0x20 || n || coefficients"]
  A2["aux[0..2]:<br/>clueRx, clueRy, clueBits"] --> B
  A3["auxDigest(aux)<br/>keccak of dynamic tuple[] mod R"] --> B
  B --> C["re-clean sub-word members<br/>(mask uint64 / address)"]
  C --> D["z = keccak256(image) mod R"]
  D --> E["y = HornerEval(coefficients, z)"]
  E --> F["verifyProof(a, b, c, [y, z])"]
```

Three details are load-bearing:

- **Static layout.** Both structs are fully static, so their ABI calldata block is word-for-word identical to the coefficient vector. Compression is a single `calldatacopy` plus a few masks — no ABI decode, no second copy.
- **Re-cleaning.** Raw calldata may carry dirty high bits that a typed member read would have masked. Each sub-word field (`uint64`, `address`, `uint8`) is masked in place before hashing, so a caller cannot smuggle a different preimage past a value the contract already validated.
- **The aux digest.** The per-output clue fields enter the coefficient vector individually, but `ephPub` and `ciphertext` would otherwise be unconstrained — a relayer could corrupt the payload beyond recovery while leaving the proof valid and the recipient's FMD scan still flagging the note. The final coefficient binds the whole aux array, recomputed on-chain rather than read from calldata. It is encoded as a *dynamic* `tuple[]` so the array length joins the preimage and arrays of different arity cannot collide.

`compressRef` mirrors each layout as a straight-line cursor walk, implemented independently of the assembly fast path. It is never used on-chain; the test suite fuzzes `compressRef == compress` to detect drift between the two.

> **Circuit coupling.** The coefficient order here must match the circuit-side PolyEval order byte-for-byte. Changing `TRANSACT_IN`, `TRANSACT_OUT`, or `MAX_L_BATCH` requires a new circuit, a new ceremony, and a new verifier.

### AuxValidation and BabyJubJub

Each output note carries an FMD (fuzzy message detection) payload: a clue point `R = [r]·G`, an ephemeral public key `E = [e]·G`, and a ciphertext prefixed by two bytes of clue bits.

`AuxValidation.validate` enforces:

- `2 ≤ len(ciphertext) ≤ 256`
- the 2-byte prefix fits the 14-bit clue mask `0x3FFF`
- `R` and `E` are on the Baby-Jubjub curve
- neither is a low-order point

`BabyJubJub.isLowOrder` performs three projective doublings and tests whether `[8]P` is the identity. The doubling formula is complete on Baby-Jubjub (`a` square, `d` non-square), so `Z` stays nonzero for any on-curve input. Rejecting cofactor-order points blocks small-subgroup attacks against the clue mechanism; it is defense-in-depth backing the equivalent in-circuit constraint.

---

## Flows

### Shield: deposit escrow and batch flush

Depositing is split in two. Funds are escrowed with **no SNARK at submit time**, and a relayer later inserts up to eight escrowed deposits into the tree under a single tree-update proof.

```mermaid
stateDiagram-v2
  [*] --> Pending: deposit variants
  Pending --> Committed: flushBatch, digest matches, proof verifies
  Pending --> Refunded: cancelDeposit, after cancelDelay
  Committed --> [*]: leaf in tree, fee accrued
  Refunded --> [*]: inAmt plus fee returned to payer

  note right of Pending
    escrowed id = keccak of
    address(this), chainId, id, cm, cvDep,
    assetId, publicIn, feeBpsAtSubmit,
    payer, submittedAt
  end note
```

Two submit variants differ only in how funds arrive:

| Entry point | Funding mechanism | Authorization |
| --- | --- | --- |
| `deposit` | Permit2 `permitWitnessTransferFrom` | Per-tx signature; witness binds `keccak256(abi.encode(d, aux))` |
| `depositAuthorized` | Permit2 `AllowanceTransfer.transferFrom` | Pre-signed `PermitSingle`; requires `msg.sender == d.payer` |

Native-coin deposits go through [`NativeAdapter.depositNative`](native/NativeAdapter.sol), which wraps `msg.value` and then drives `depositAuthorized` as its own payer — see [Native coin](#native-coin).

For `deposit`, the signed `maxTotal` caps the whole pull — `inAmt + fee + the relayer note's value` — bounding any fee increase between signing and execution.

The escrow ledger stores only a `bytes32` digest per id. The full preimage lives in the `DepositEscrowed` event; flush and cancel resupply it as calldata, and a single keccak equality binds every submit-time field — asset, amount, commitment, fee rate, payer, and block. A nonzero digest is the presence sentinel, and `delete` on drain is what rejects a repeated id within one batch.

```mermaid
sequenceDiagram
  autonumber
  participant U as Depositor
  participant P2 as Permit2
  participant M as MASP
  participant Rl as Relayer
  participant TV as TreeUpdateBatchVerifier

  U->>M: deposit(d, sig, aux, feeAux)
  M->>M: _validateDeposit (chainId, amount bounds,<br/>asset enabled, aux curve checks)
  M->>P2: permitWitnessTransferFrom(inAmt + fee + relayerFee)
  P2-->>M: tokens
  M->>M: escrowed[id] = digest
  M-->>Rl: emit DepositEscrowed(id, ..., cvDep, rcv, aux)

  Note over Rl: collect up to MAX_L_BATCH deposits,<br/>build tree witness, prove tree_update_batch

  Rl->>M: flushBatch(ids, meta, tp, tpi)
  M->>M: header checks: n in [1,4], actualCount == n,<br/>oldRoot == currentRoot, startIndex == committedCount
  loop each slot i
    M->>M: _drainDeposit: digest match, isDeposit[i] == 1,<br/>accumulate fee per token, delete escrowed[id]
  end
  M->>M: _accrueFee once per unique token
  M->>TV: verifyProof(tp, compress(tpi))
  TV-->>M: true
  M->>M: _advanceRoot(newRoot, n, oldRoot)
```

Each deposit occupies `LEAVES_PER_DEPOSIT` = 2 adjacent leaves — its principal and the note paying whoever flushes it — so deposit `i` owns leaves `2i` and `2i + 1`, and a batch advances the tree by `2n`. That also halves the ceiling: a batch holds `MAX_L_BATCH / LEAVES_PER_DEPOSIT` deposits, not `MAX_L_BATCH`. The per-leaf Pedersen commitment `cvDep` pins `(asset, value)` directly, and the circuit binds each leaf's `cvDep` to its own `leafPublicIn` independently, so there is no padding leaf whose split would be free.

`cancelDeposit` pays only the digest-bound `payer`, and only after `cancelDelay` blocks (default 7200, owner-tunable within `[3600, 50400]`). Because `submittedAt` is part of the digest, the delay check runs on a value the caller cannot forge. The escrow slot is cleared before the transfer (checks-effects-interactions).

Who may call depends on the payer. An **EOA payer** can be cancelled by anyone: `deposit` is Permit2-signature based, so the payer may be an address that never sends a transaction and depends on a relayer to cancel for it. A **contract payer** may only cancel its own deposit (`payer.code.length != 0 && msg.sender != payer` reverts `PayerNotSender`). A contract can always transact for itself, and it is the party that must observe the refund, since the coin returns to it rather than to whoever funded it — settled by a third party, an adapter's refund lands with nothing on-chain left to distinguish it from a flushed deposit, stranding the funder's claim. Note an EIP-7702 delegated EOA carries code and is classified as a contract payer.

### Spend: transfer and withdraw

Both spend entry points share the same skeleton and differ only in their public-leg constraints and settlement:

| Entry point | `publicIn` | `publicOut` | Settlement |
| --- | --- | --- | --- |
| `transfer` | must be 0 | must be 0 | none — registry existence check only |
| `withdraw` | must be 0 | must be nonzero | `safeTransfer(recipient, outAmt - fee)` |

Unshielding to native coin is a `withdraw` whose `recipient` is the [`NativeAdapter`](native/NativeAdapter.sol) — see [Native coin](#native-coin).

```mermaid
sequenceDiagram
  autonumber
  participant C as Caller (relayer)
  participant M as MASP
  participant BV as BatchedGroth16Verifier
  participant T as ERC-20

  C->>M: withdraw(p, pi, tp, tpi, aux)
  M->>M: publicIn == 0, publicOut != 0
  M->>M: _validateRequest
  Note right of M: chainId, nonzero recipient/payer,<br/>relayer == msg.sender,<br/>pairwise nullifier distinctness,<br/>pi.outCm == tpi.cms,<br/>pi.outCvDep == tpi.cvDeps,<br/>tpi.isDeposit all zero,<br/>aux validation,<br/>isKnownRoot[pi.merkleRoot],<br/>tpi.oldRoot == currentRoot,<br/>tpi.startIndex == committedCount
  M->>M: _getAsset(publicAssetId)
  M->>BV: verifyBatch(p, compress(pi, aux), tp, compress(tpi))
  Note right of BV: both Groth16 residuals in one<br/>six-term pairing check
  BV-->>M: true
  M->>M: _consumeNullifier x3
  M->>M: _advanceRoot(newRoot, 3, oldRoot)
  M->>M: accrue fee on outAmt
  M->>T: safeTransfer(recipient, outAmt - fee)
  M-->>C: emit AssetMoved, NotePayload x3
```

**`_validateRequest` is the security centre of the spend path.** The two Groth16 proofs are independent; nothing in either circuit relates one to the other. The contract is what ties them together:

- `pi.outCm[k] == tpi.cms[k]` — the leaves being inserted are exactly the notes the spend created.
- `pi.outCvDep[k] == tpi.cvDeps[k]` — their value commitments agree.
- `tpi.actualCount == TRANSACT_OUT_LEAVES` — the batch commits precisely the spend's output leaves, no more.
- `tpi.isDeposit[k] == 0` for every output leaf. The batch circuit cannot distinguish a spend leaf from a deposit leaf, and deposit binding is per-leaf (`cv_dep == leaf_public_in·V^leaf_asset + rcv·H`). A spend output could satisfy that relation by declaring its own `(asset, value)` — which would publish the note's opening in the compressed public inputs. This must be pinned on-chain.
- `pi.relayer == msg.sender` — the proof names its submitter, so it cannot be lifted from the mempool and replayed by a third party.

Token movement binds to `payer` and `recipient`, both public inputs, rather than to `msg.sender`. Any relayer may therefore submit on a user's behalf without gaining control of the funds.

### Fee accounting

```mermaid
flowchart TD
  subgraph SHIELD["Shield leg"]
    S1["deposit*<br/>pull inAmt + fee + relayerFee"] --> S2["escrowed[id] = digest<br/>(no accrual)"]
    S2 --> S3{"outcome"}
    S3 -->|flushBatch| S4["_accrueFee(token, fee)<br/>once per unique token"]
    S3 -->|cancelDeposit| S5["refund inAmt + fee + relayerFee<br/>to payer"]
  end
  subgraph UNSHIELD["Unshield leg"]
    W1["withdraw<br/>outAmt = publicOut * scale"] --> W2["fee = outAmt * asset.withdrawBps / 10000"]
    W2 --> W3["_accrueFee(token, fee)"]
    W2 --> W4["send outAmt - fee<br/>to recipient"]
  end
  S4 --> A["accruedFee[token]"]
  W3 --> A
  A -->|"sweep(token), permissionless"| TR["treasury"]
```

Deposit fees use the asset's `depositBps` snapshotted at submit time and carried in the digest, so a later `setAssetFee` cannot re-rate a pending deposit or its cancellation; withdraw fees read the asset's `withdrawBps` live at execution, which is bound by nothing the spender signed — `MAX_FEE_BPS` is the only ceiling on that leg. `flushBatch` accumulates fees into a fixed `MAX_L_BATCH`-wide array keyed by token address and writes one `SSTORE` per *unique* token, rather than one per deposit.

---

## Escrow satellites

`MASP` has no privileged peripheral position. A peripheral that wants to shield funds it is holding calls `depositAuthorized` with `d.payer = address(this)` and lets the pool pull against its own Permit2 allowance. Both current peripherals do this, and the pattern comes with a fixed set of consequences, so it lives once in [MaspEscrowSatellite.sol](MaspEscrowSatellite.sol) rather than per contract.

| Piece | Why it is shared |
| --- | --- |
| `POOL` / `PERMIT2` immutables, zero-address checks | Identical wiring in every satellite. |
| `_approveToken` | The ERC-20 → Permit2 → MASP approval pair, at infinite allowance and max expiry. |
| `_escrowMeasured` | Neither the deposit fee nor the relayer note is visible to a satellite, so the pull is only knowable as a balance delta across `depositAuthorized`. It takes a mandatory `[minPull, maxPull]` window and enforces it — see below. |
| `Escrow { refundTo, amount }` + `_cancelAndVerify` | The pool refunds the digest-bound payer — the satellite — so a cancel needs an on-satellite record of who funded it, and the refund has to be verified by delta before it is paid out. |
| `ReentrancyGuardTransient` | Every delta above is sound only if nothing can move the balance between the two reads, so the guard is a property of being a satellite. Subclasses still apply `nonReentrant` at their own entry points. |

**The pull window is an argument, not a convention.** The Permit2 allowance a satellite grants the pool is unbounded and covers its entire balance, while `DepositRequest` is unauthenticated calldata — so a caller who oversizes `publicIn` could escrow coin parked in the satellite for somebody else into a note of their own. Every satellite must therefore bound the measured pull, and `_escrowMeasured` takes that bound as two required parameters rather than documenting the obligation: `NativeAdapter` passes `[1, msg.value]`, `SwapWrapper` passes `[minOut, actualOut]`. A satellite that omits the bound does not compile, and one that wants no ceiling has to write `type(uint256).max` where a reviewer can see it. The floor doubles as the asset check — a deposit denominated in any other asset moves none of the measured token, so it lands as a zero pull and trips `PullBelowMin`.

**The record is one storage slot.** `refundTo` is an address and `amount` is a `uint96`, so the pair fills a slot exactly and an escrow costs one cold `SSTORE` instead of two — around 22 000 gas on every `depositNative` and every `swap`, and about 18 000 more on each cancel. The pool bounds what can reach that width from far below it: `publicIn` and `feeIn` are each validated against `type(uint48).max`, so a pull cannot exceed roughly `2^48 · scale · 2.2`. At the registered scales (`1` and `1e10`) the worst case is about `6.2e24` against a ceiling of `7.92e28` — four orders of magnitude of headroom — and the width is only reachable by an asset registered with a `scale` above roughly `1.2e14`. `_escrowMeasured` enforces it regardless: a pull that would not fit reverts `EscrowAmountTooLarge` rather than truncating, which would under-record the escrow and strand the difference on cancel.

The record holds no token address. `NativeAdapter` has a single immutable token, and a third field would spill into a second slot and undo the packing above. A satellite that handles an open set of tokens keeps its own `depositId → token` mapping and returns it from `_consumeEscrowToken`, which the base calls once the cancel guards have passed and before any external call — so the per-satellite half of the record is cleared under the same CEI ordering as the base's half, and a rejected cancel never pays to clear a record it is about to keep.

Payout is **not** in the base: `_cancelAndVerify` returns `(token, refundTo, amount)` and stops. `NativeAdapter` unwraps and sends native coin; token satellites `safeTransfer`. See [MaspEscrowSatellite.sol](MaspEscrowSatellite.sol) for the full rationale on each piece.

---

## Shielded Swap

`SwapWrapper` composes an unshield, a venue swap, and a re-shield into one atomic transaction, so no intermediate balance is ever exposed to an observer as a user-held position.

```mermaid
sequenceDiagram
  autonumber
  participant U as User (pi_w.payer)
  participant SW as SwapWrapper
  participant M as MASP
  participant AD as ISwapAdapter (UniV3Adapter / UniV4Adapter)
  participant RT as Venue router (SwapRouter02 / UniversalRouter)
  participant TR as Treasury

  U->>SW: swap(SwapArgs)
  SW->>SW: _validate: adapter allowlisted, deadline,<br/>pi_w.recipient == wrapper,<br/>pi_w.relayer == wrapper,<br/>deposit_d.payer == wrapper,<br/>msg.sender == pi_w.payer
  SW->>SW: snapshot balances of tokenIn / tokenOut
  SW->>M: withdraw(p_w, pi_w, tp_w, tpi_w, aux_w)
  M-->>SW: tokenIn (net of MASP fee)
  SW->>SW: received = balance delta, revert if below amountIn
  SW->>AD: transfer received, then swap(...)
  AD->>AD: snapshot tokenOut balance
  alt UniV3Adapter — SwapRouter02
    AD->>RT: forceApprove(router, amountIn)<br/>exactInputSingle / exactInput, recipient = adapter
    RT-->>AD: tokenOut
    AD->>RT: forceApprove(router, 0)
  else UniV4Adapter — UniversalRouter V4_SWAP
    AD->>RT: transfer amountIn, then execute(V4_SWAP, deadline)<br/>settles CONTRACT_BALANCE, payerIsUser = false<br/>no approval, hooks pinned to address(0)
    RT-->>AD: tokenOut
  end
  AD->>AD: actualOut = tokenOut balance delta,<br/>not the router's return value;<br/>revert if below minOut
  AD-->>SW: transfer actualOut
  SW->>SW: revert if actualOut below minOut
  SW->>M: depositAuthorized(deposit_d, aux_d)
  M-->>SW: depositId (pulled via Permit2)
  SW->>SW: check minOut, pulled, actualOut ordering
  SW->>TR: transfer dust = actualOut - pulled
  SW->>SW: leftover invariant: both balances<br/>back to snapshot
  SW-->>U: (actualOut, depositId)
```

Every amount is measured as a **balance delta across an external call**, because neither the MASP withdraw fee nor the size of its escrow pull is visible to the wrapper. Four properties make that measurement safe:

1. `nonReentrant` on both the wrapper and the MASP entry points.
2. The adapter is owner-allowlisted, so the callee is not attacker-chosen.
3. `minOut ≤ pulled ≤ actualOut` constrains `deposit_d` to be denominated in `tokenOut` — any other asset yields a zero delta — and to carry at least the requested output rather than routing it to the treasury as dust.
4. A closing leftover invariant reverts on any net drift in either token, measured against the pre-swap snapshot rather than against zero, so unrelated donations do not brick the swap.

The `msg.sender == pi_w.payer` check is what stops a mempool replay: `swap` is permissionless and `deposit_d` — which names the output note's commitment and recipient — is unauthenticated calldata. `payer` is a public input of the withdraw proof carrying no other constraint on the spend path, so it serves as the name of the address permitted to drive the swap.

An escrow the wrapper creates is owned by the wrapper: MASP refunds the digest-bound payer, and a contract payer may only cancel its own deposit. `swap` therefore records `refundTo = pi_w.payer` — the address authorized to drive that swap — alongside the escrowed token and amount, readable via `escrows(depositId)`, and `cancelEscrow` is what recovers a leg that never gets flushed. Anyone may call it, the destination is the recorded driver rather than the caller, and the refund is attributed by balance delta across the pool call — sound because the wrapper is necessarily the one making it. An already-settled deposit was flushed and is rejected with `DepositAlreadySettled` rather than paid out of another escrow's coin.

`UniV3Adapter` is a thin pull-then-push adapter: the wrapper pre-transfers `amountIn`, the adapter approves the router, swaps to itself, resets the approval to zero (keeping tokens such as USDT, which reject non-zero-to-non-zero approval changes, usable on the next call), and pushes the output to `msg.sender`. Like `UniV4Adapter`, it reports the output as a balance delta across the router call rather than the router's own return value: the wrapper hands that number to `_escrowMeasured` as the pull ceiling, so it has to be what the venue actually delivered. A 64-byte `route` is decoded as `(uint24 fee, uint160 sqrtPriceLimitX96)` and routed single-hop; any other length is treated as a packed multi-hop path. `swap` is restricted to the pinned `WRAPPER`, without which any caller could drain donated tokens by routing output to themselves.

`UniV4Adapter` is the same shape against the UniversalRouter's `V4_SWAP` command, with three differences worth naming. It needs **no approval at all**: it transfers `amountIn` to the router and settles with `CONTRACT_BALANCE` / `payerIsUser = false`, which pays out of the router's own balance and keeps the flow off Permit2. It **measures its own balance delta**, because `execute` returns nothing where `SwapRouter02.exactInputSingle` returns `amountOut`. And it **forwards `deadline`** to the router, which enforces it, where SwapRouter02 takes none. Its 64-byte `route` is `(uint24 fee, int24 tickSpacing)`; currency ordering is derived from the token addresses and `hooks` is pinned to `address(0)`, so neither can be named by the caller — `route` is unauthenticated calldata, and an attacker-chosen hook would otherwise be invoked by the PoolManager mid-swap.

Adding a venue is additive: a new `ISwapAdapter`, `setAdapterAllowed`, and nothing else. `SwapWrapper` never decodes `route` and its safety argument does not depend on the venue.

---

## Native coin

`MASP` is ERC-20 only: it has no `receive`, no wrapped-native immutable, and no native branch in any entry point. `NativeAdapter` is the sole bridge, wrapping on the way in and unwrapping on the way out. It is ownerless and permissionless — all authority comes from the SNARK public inputs or from the adapter's own escrow bookkeeping.

| Entry point | Wraps around | Native leg |
| --- | --- | --- |
| `depositNative` | `depositAuthorized` (adapter is `d.payer`) | wrap `msg.value`, return the surplus over the pool's pull |
| `cancelNative` | `cancelDeposit` (adapter is the digest-bound `payer`) | unwrap the refund, forward it to the recorded funder |
| `withdrawNative` | `withdraw` (adapter is `pi.recipient` and `pi.relayer`) | unwrap the proceeds, forward them to `pi.payer` |

Amounts are measured as **balance deltas across the pool call**, never recomputed: neither the deposit fee nor the withdraw fee is visible to the adapter, and mirroring MASP's fee math would drift the moment the asset's rate changed between quote and execution. On the deposit leg that also means callers may overshoot `msg.value` rather than reproduce the fee formula — the surplus is unwrapped and returned in the same transaction.

Because the pool refunds the digest-bound `payer` — the adapter — a canceled escrow needs an on-adapter record of who funded it: `escrows(id)` holds `(refundTo, amount)`, packed into one storage slot. Both that record and the cancel path around it come from [MaspEscrowSatellite](MaspEscrowSatellite.sol); only the wrapping and the native payout are adapter-specific.

Attribution rests on the pool's contract-payer rule. Since only the adapter can cancel an adapter-owned deposit, every refund arrives during a `cancelNative` call, and the wrapped-balance delta across that call must equal the recorded amount. `POOL.escrowed(id) == 0` therefore means one thing — the deposit was flushed — and `cancelNative` rejects it with `DepositAlreadySettled` rather than guessing. There is no shared pot, so a record left behind by a flushed deposit is inert and cannot hold up anyone else's refund.

On the spend side the destination is `pi.payer`, a public input of the withdraw proof that carries no other constraint. Binding the native recipient to the proof rather than to a calldata argument keeps `withdrawNative` permissionless for relayers while leaving no field a front-runner could repoint. A zero wrapped-balance delta reverts the whole spend, so an unshield of some other asset can never strand an ERC-20 on the adapter.

---

## Constants

| Constant | Value | Location |
| --- | --- | --- |
| `DEPTH` | 10 | `CommitmentTree` |
| `ARITY` | 4 | `CommitmentTree` |
| `MAX_LEAVES` | 4 194 304 (`4^11`) | `CommitmentTree` |
| `ROOT_HISTORY` | 64 | `CommitmentTree` |
| `TRANSACT_IN` / `TRANSACT_OUT` | 3 / 3 | `PubInputs` |
| `MAX_L_BATCH` | 8 | `PubInputs` |
| `TRANSACT_COEFFS` | 42 | `PubInputs` |
| batch coefficients | 52 (`4 + 6 × 8`) | `PubInputs` |
| `MAX_FEE_BPS` | 2 000 (20%) | `FeeConfig` |
| `BPS_DENOMINATOR` | 10 000 | `FeeConfig` |
| `CANCEL_DELAY_DEFAULT` | 7 200 blocks (~24 h at 12 s) | `MASP` |
| `CANCEL_DELAY_MIN` / `MAX` | 3 600 / 50 400 blocks | `MASP` |
| `MAX_CIPHERTEXT_LEN` | 256 bytes | `AuxValidation` |
| `CLUE_BITS_MASK` | `0x3FFF` (14 bits) | `AuxValidation` |
| `R` (BN254 scalar field) | `21888242871839275222246405745257275088548364400416034343698204186575808495617` | `SnarkCompression` |
| Baby-Jubjub `a` / `d` | 168 700 / 168 696 | `BabyJubJub` |
| max `scale` | `1e18` | `AssetRegistry` |
