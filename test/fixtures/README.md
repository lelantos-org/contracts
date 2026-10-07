# Test fixtures

JSON read by Foundry tests and the anvil deploy scripts through `vm.readFile`.

> **Prototype setup.** The vectors, proofs and verification keys here, and the verifiers and `VerifyingKeys.sol` under `src/verifiers/`, are those of the `@lelantos-org/circuits` v0.20.0 release (public signals `[y, digest, z]`). That release's trusted setup has a single contributor and is marked not mainnet-safe. A deployment holding real value requires the keys of a multi-party ceremony. Replace the verifiers, `VerifyingKeys.sol`, the verification keys and every proof fixture together, using the procedures below.

## Files

| File | Contents | Refresh |
| --- | --- | --- |
| `asset_registry.json` | Asset ids, scales and ERC-20 metadata for the mock deployments. | By hand |
| `transact_4x6_vector.json` | `transact-4x6` witness vector from the circuits package. | Copy from `../../circuits/vectors/transact-4x6.json` |
| `tree_update_batch_vector.json` | `tree-update-batch-8` witness vector from the circuits package. | Copy from `../../circuits/vectors/tree-update-batch-8.json` |
| `transact_4x6_proof.json` | One Groth16 proof per transact vector. | `script/fixtures/gen_proof_fixture.sh transact_4x6` |
| `tree_update_batch_proof.json` | One Groth16 proof per tree-update vector. | `script/fixtures/gen_proof_fixture.sh tree_update_batch` |
| `masp_flow_proof.json` | Proofs for a deposit, its flush, and a transfer or withdraw of its note, as requests the pool accepts end to end. | `script/fixtures/gen_masp_fixture.sh` |
| `verification_key_4x6.json`, `verification_key_tree_update_batch.json` | Verification keys the vendored verifiers encode. | From the circuits release |
| `quint/` | Quint trace fixtures. See [../quint/README.md](../quint/README.md). | `just quint-gen` |

### `asset_registry.json`

Column-wise arrays `ids`, `scales`, `names`, `symbols`, `decimals`; an entry is one element at the same index in all five. Asset id 0 means "no asset" and cannot be registered.

Read by [DeployTest.s.sol](../../script/DeployTest.s.sol), [DeployTestSwap.s.sol](../../script/DeployTestSwap.s.sol), [DeployTestYield.s.sol](../../script/DeployTestYield.s.sol) and [MASP.deploy.t.sol](../masp/MASP.deploy.t.sol).

Constraints:

- Asset id 1 must keep the symbol `WETH`. `DeployTest.s.sol` matches on that symbol to deploy `MockWETH9` in its slot; every other slot is a `MockERC20`.
- `publicIn = baseUnits / scale`, and `publicIn` must fit `uint48`. The 18-decimal entries use `scale = 1e10` (1 ETH = 1e8 circuit units); the 8-decimal `mWBTC` uses `scale = 1`.

### Witness vectors

Both vector files are verbatim copies from the circuits package. Each file's SHA-256 matches its entry in the circuits `vectors/index.json` manifest; re-check it after a refresh.

- `transact_4x6_vector.json` is read by [PubInputs.vector4x6.t.sol](../libs/PubInputs.vector4x6.t.sol), which builds `PubInputs.Transact` from the circuit's witness and compares against the `[y, digest, z]` the compiled circuit produced. This pins the 13 coefficient slots, the digest word and the 38-word challenge preimage.
- `tree_update_batch_vector.json` is read by [PubInputs.vectorTub.t.sol](../libs/PubInputs.vectorTub.t.sol), which does the same for `PubInputs.TreeUpdateBatch` (36 coefficient slots and the digest word), and by [TreeUpdateBatchVerifier.vector.t.sol](../verifiers/TreeUpdateBatchVerifier.vector.t.sol). On a deposit slot `cms[k]` is the depositor's `inner`; the tree leaf is `Poseidon(TAG_CM, leafAsset · 2^64 + leafPublicIn, cms[k])`, and `intermediates.leaves[k]` records both.

### Circuit-level proofs

- `tree_update_batch_proof.json` is read by [TreeUpdateBatchVerifier.vector.t.sol](../verifiers/TreeUpdateBatchVerifier.vector.t.sol), which feeds the verifier the output of `PubInputs.compress` and checks acceptance, public-signal order, cross-vector replay, a tampered batch header and out-of-field signals.
- `transact_4x6_proof.json` is read by [BatchedGroth16Verifier.t.sol](../verifiers/BatchedGroth16Verifier.t.sol), which pairs each transact proof with each tree-update proof and asserts the batched verifier agrees with the two codegen verifiers.

G2 coordinates are stored in the `(x1, x0), (y1, y0)` order the pairing precompile expects, as produced by `snarkjs zkey export soliditycalldata`.

### `masp_flow_proof.json`

The circuit-level vectors carry zero recipient, payer, relayer and chain id, which the pool rejects before any proof check. This fixture holds requests the pool accepts:

- `.flush`: a deposit of 100 units of asset 1 with its zero-value relayer fee note, flushed from the empty tree. `tpi` is the full `PubInputs.TreeUpdateBatch`; `proof` is its `tree_update_batch` proof.
- `.transfer`: a spend of that note, 60 to a second owner and 40 back.
- `.withdraw`: a spend of the same note from the same tree state, 30 out to `pi.recipient` and 70 back.

The two spends consume the same nullifier and are alternatives; a test replays one per pool. Each spend holds the call's arguments:

| Field | Contents |
| --- | --- |
| `pi` | `PubInputs.Transact`. |
| `aux[6]` | `AuxValidation.Output` payloads. `PubInputs.auxDigest` of these bytes is the last word of the transact challenge. |
| `tpi` | `PubInputs.SpendTree` without `anchorIndex`, which the test reads from the pool (`rootIndex()` after the flush). |
| `txProof`, `tubProof` | The `4x6` proof and the `tree_update_batch` proof of the six inserted leaves. |

`.chainId` is the chain the spends were proven for (31337). `.note` is the opening of the deposited note. `pubSignals`, `txPubSignals` and `tubPubSignals` record the `[y, digest, z]` each proof was made for; tests do not read them. Field elements and proof coordinates are 32-byte hex words, addresses 20-byte hex, counts and `uint64` amounts decimal strings.

Read through [MaspFlowFixture.sol](../utils/MaspFlowFixture.sol) by:

- [MASP.flushBatchSnark.t.sol](../masp/MASP.flushBatchSnark.t.sol): `deposit`, then `flushBatch` against `TreeUpdateBatchGroth16Verifier`.
- [MASP.transferSnark.t.sol](../masp/MASP.transferSnark.t.sol): `transfer` and `withdraw` against `BatchedGroth16Verifier`.
- [MASP.chainId.t.sol](../masp/MASP.chainId.t.sol): the transfer replayed on another chain id.

Each suite also changes one word of an accepted request and expects the pool's proof rejection.

### Verification keys

Read by [VerifyingKeys.t.sol](../verifiers/VerifyingKeys.t.sol), which pins every constant in `src/verifiers/VerifyingKeys.sol` against them.

## Generating proof fixtures

`script/fixtures/gen_proof_fixture.sh {tree_update_batch|transact_4x6}` proves every vector in the corresponding witness file and writes the calldata triples.

Proving artifacts must come from the circuits GitHub release, not from a local `circuits/build/`. A local setup produces a different `delta`, so its proofs do not satisfy the vendored verifiers. The script asserts the release verification key against the vendored Solidity verifier before proving.

```sh
gh release download v0.20.0 --repo lelantos-org/circuits -D /tmp/rel \
  -p '*_final.zkey' -p '*.wasm' -p '*verification_key.json'
RELEASE=/tmp/rel CIRCUITS=../circuits \
  script/fixtures/gen_proof_fixture.sh transact_4x6
```

Groth16 proving is randomized: a refresh produces different proof triples over identical public signals.

`.source` records the vector file, the circuits package it belongs to (`package`, from `vectors/index.json`, whose hash entry the script checks against the vector), the circuit template and the layout digest.

## Generating the MASP-level fixture

`script/fixtures/gen_masp_fixture.sh` writes `masp_flow_proof.json`. It runs `scripts/gen-masp-fixture.ts` in the circuits checkout (`just masp-fixture` there), which builds the witnesses from the circuits reference code.

```sh
script/fixtures/gen_masp_fixture.sh
RELEASE=/tmp/rel CIRCUITS=../circuits script/fixtures/gen_masp_fixture.sh
```

`RELEASE` is the directory of release assets and defaults to `../circuits/build/prototype-0.20.0`. The wasm is taken from beside the keys when present, and from `../circuits/build/<circuit>_js/` otherwise.

Before writing, the generator asserts that each verification key matches the vendored Solidity verifier, that every proof verifies under snarkjs, and that its public signals equal the `[y, digest, z]` computed as `PubInputs.sol` computes them. Witnesses are deterministic; proofs are not.

The request is fixed in the generator and mirrored by the tests: asset id 1 (`TestConstants.ASSET_ID`), chain id 31337, and `TestConstants.RECIPIENT`, `ESCROW_PAYER` and `RELAYER`. The asset id must match the pool's registry.

Regenerate every proof fixture whenever the verifiers change.
