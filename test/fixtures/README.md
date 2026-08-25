# Test Fixtures

JSON read by Foundry tests and the anvil deploy scripts via `vm.readFile`.

## Files

### `asset_registry.json`

Maps asset ids to ERC-20 token metadata and value-commitment scales. Asset
generators are derived in-circuit via `HashToAssetGen(publicAssetId)` and are
not stored on-chain.

- `ids` — asset identifiers
- `scales` — per-asset scaling factors
- `names` / `symbols` / `decimals` — ERC-20 metadata for the mock deployments

Read by [DeployTest.s.sol](../../script/DeployTest.s.sol),
[DeployTestSwap.s.sol](../../script/DeployTestSwap.s.sol),
[MASP.deploy.t.sol](../MASP.deploy.t.sol) and
[BabyJubJub.t.sol](../BabyJubJub.t.sol).

Edited by hand — the arrays are column-wise, so an entry is one element added
at the same index in all five. Two constraints are not obvious from the file:

- **Asset id 1 must keep the symbol `WETH`.** `DeployTest.s.sol` matches on
  that symbol to wire the slot to `MockWETH9`; the e2e multi-asset and
  eth-bridge paths depend on it. Every other slot is a plain `MockERC20`.
- **`scale` collapses base units into circuit units**: `publicIn = baseUnits /
  scale`, and `publicIn` must fit `uint48` (max ≈ 2.81e14). For an 18-decimal
  token `scale = 1` overflows at ~0.000281 ETH, so the 18-decimal entries use
  `1e10`, leaving 8 fractional digits and putting 1 ETH at 1e8 circuit units.
  `mWBTC` is 8-decimal and uses `scale = 1`.

### `transact_3x3_vector.json`

The `transact-3x3` witness vector published by the circuits package, copied
verbatim. Its SHA-256 matches the `vectors/index.json` manifest entry, so the
copy is verifiable against the release.

Read by [PubInputs.vector3x3.t.sol](../PubInputs.vector3x3.t.sol), which drives
`PubInputs.Transact` from the circuit's own witness and compares against the
`(y, z)` the compiled circuit produced. This pins all 42 coefficient slots
against an artifact generated outside this repo — the other layout tests only
compare the contract to reference code written alongside it.

Refresh by re-copying from `../../circuits/vectors/transact-3x3.json` and
re-checking the manifest SHA-256.

### `tree_update_batch_vector.json`

The `tree-update-batch-4` witness vector published by the circuits package,
copied verbatim. SHA-256 `97c441353d720893f6d02d5bdbfe299103bae4a69230bd1baa85
4091416b79e0`, matching the `vectors/index.json` manifest entry for
`@lelantos-org/circuits@0.11.2`.

Read by [PubInputs.vectorTub.t.sol](../PubInputs.vectorTub.t.sol), the batch
counterpart to the 3x3 layout test: it drives `PubInputs.TreeUpdateBatch` from
the circuit's own witness and pins all 28 coefficient slots against the
`(y, z)` the compiled circuit produced. Unlike the transact vector there is no
substituted slot — the batch circuit takes every coefficient as a public input,
so the published `(y, z)` is asserted directly.

Also read by
[TreeUpdateBatchVerifier.vector.t.sol](../TreeUpdateBatchVerifier.vector.t.sol)
to rebuild the struct behind each proof.

Refresh by re-copying from `../../circuits/vectors/tree-update-batch-4.json`
and re-checking the manifest SHA-256.

### `tree_update_batch_proof.json`

Three real Groth16 proofs, one per vector above, against the deployed
[TreeUpdateBatchVerifier.sol](../../src/verifiers/TreeUpdateBatchVerifier.sol).
Read by
[TreeUpdateBatchVerifier.vector.t.sol](../TreeUpdateBatchVerifier.vector.t.sol),
which checks acceptance, the `(y, z)` public-signal order, cross-vector replay,
a tampered batch header, and out-of-field signals — and feeds the verifier the
output of `PubInputs.compress` rather than the fixture's signals, closing the
compress-to-verify path.

G2 coordinates are stored in the `(x1, x0), (y1, y0)` order the pairing
precompile expects, taken from `snarkjs zkey export soliditycalldata` rather
than from `proof.json`, which stores them the other way round.

Regenerate with `script/fixtures/gen_proof_fixture.sh tree_update_batch` — see
**Generating proof fixtures** below.

### `transact_3x3_proof.json`

Three real Groth16 proofs, one per vector in `transact_3x3_vector.json`, against
[Verifier.sol](../../src/verifiers/Verifier.sol). Read by
[BatchedGroth16Verifier.t.sol](../BatchedGroth16Verifier.t.sol), which pairs each
of them with each tree-update proof and asserts the batched verifier agrees with
the two codegen verifiers.

Regenerate with `script/fixtures/gen_proof_fixture.sh transact_3x3`.

### `verification_key_3x3.json`, `verification_key_tree_update_batch.json`

The two published verification keys, copied verbatim from the v0.11.2 release
(SHA-256 `941891fd…fbb72c` and `9c80109d…42aab9`). Read by
[VerifyingKeys.t.sol](../VerifyingKeys.t.sol), which pins every constant in
`src/verifiers/VerifyingKeys.sol` against them. The codegen verifiers' own
constants are contract-scoped and non-public, so Solidity cannot compare against
those directly — this JSON is the only readable form.

## Generating proof fixtures

`script/fixtures/gen_proof_fixture.sh {tree_update_batch|transact_3x3}` proves
every vector in the corresponding witness file and writes the calldata triples.

**Artifacts must come from the GitHub release, never from a local
`circuits/build/`.**

1. `just setup-*` contributes with `openssl rand -hex 32`, so a local ceremony
   produces a different `delta` than the release. Proofs made against a local
   zkey cannot satisfy the vendored verifiers under `src/verifiers/`, which are
   copied from the release.
2. A local `build/` may be partially rebuilt: a current r1cs/wasm beside a zkey
   from an earlier ceremony.

The script asserts the release verification key against the vendored Solidity
verifier before proving anything, so a mismatched artifact set fails there
rather than as an unexplained rejection in a test.

```
gh release download v0.11.2 --repo lelantos-org/circuits -D /tmp/rel0112 \
  -p '*_final.zkey' -p '*.wasm' -p '*verification_key.json'
RELEASE=/tmp/rel0112 CIRCUITS=../circuits \
  script/fixtures/gen_proof_fixture.sh transact_3x3
```

Groth16 proving is randomized, so a refresh produces different — equally valid —
proof triples over identical public signals.

## Remaining coverage gap

The transact path has real-proof coverage at the **verifier** level
(`transact_3x3_proof.json`, above) but not at the **MASP** level. Four tests are
still skipped for want of a MASP-level witness:

- `MASP.transferSnark.t.sol :: test_transferRealSnark_succeeds`
- `MASP.chainId.t.sol :: test_revert_CrossChainReplay`
- `MASP.chainId.t.sol :: test_revert_BadChainId_spend`
- `MASP.flushBatchSnark.t.sol :: test_realSnark_n1_flushBatchSucceeds`

The prover artifacts are published by the release (`3x3_final.zkey`,
`3x3.wasm`). The blocker is that the circuit takes `out_aux_digest` as an
*input* while `PubInputs.compress` recomputes it from aux calldata, so the aux
payload, the tree roots and the cross-bound `cms`/`cvDeps` must all be chosen
before proving. Spend tests therefore use `vm.mockCall`.
