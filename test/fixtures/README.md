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

The `tree-update-batch-8` witness vector published by the circuits package,
copied verbatim. SHA-256 `8f976f589ce6c17a61c8cabf3aafc85b8ef31d717304e003e087
6c6b4dd32275`, matching the `vectors/index.json` manifest entry for
`@lelantos-org/circuits@0.8.0`.

Read by [PubInputs.vectorTub.t.sol](../PubInputs.vectorTub.t.sol), the batch
counterpart to the 3x3 layout test: it drives `PubInputs.TreeUpdateBatch` from
the circuit's own witness and pins all 52 coefficient slots against the
`(y, z)` the compiled circuit produced. Unlike the transact vector there is no
substituted slot — the batch circuit takes every coefficient as a public input,
so the published `(y, z)` is asserted directly.

Also read by
[TreeUpdateBatchVerifier.vector.t.sol](../TreeUpdateBatchVerifier.vector.t.sol)
to rebuild the struct behind each proof.

Refresh by re-copying from `../../circuits/vectors/tree-update-batch-8.json`
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

Regenerate with
[gen_tree_update_batch_proof.sh](../../script/fixtures/gen_tree_update_batch_proof.sh):

```sh
CIRCUITS=../circuits script/fixtures/gen_tree_update_batch_proof.sh
```

Needs a local circuits checkout with a built `build/` — the published tarball's
`files` list ships only the 2x2 and 3x3 artifacts, so `tree_update_batch_final.
zkey` and `tree_update_batch.wasm` have to come from a local `just build`. The
script asserts each proof's public signals against the vector's own `(y, z)`
before writing. Groth16 proving is randomized, so a refresh produces different
— equally valid — proof triples over identical public signals.

## Removed proof fixtures

`proof_transfer.json` and `proof_deposit_batch_n1.json` were deleted. Both were
2x2-shaped artifacts that the 3x3 pool cannot satisfy, and both were already
inert — every test reading them was skipped.

The tests remain in place, skipped, with the reason recorded at the skip site:

- `MASP.transferSnark.t.sol :: test_transferRealSnark_succeeds`
- `MASP.chainId.t.sol :: test_revert_CrossChainReplay`
- `MASP.chainId.t.sol :: test_revert_BadChainId_spend`
- `MASP.flushBatchSnark.t.sol :: test_realSnark_n1_flushBatchSucceeds`

Consequence: **the transact path has no real-proof coverage.** Its layout is
pinned by `PubInputs.vector3x3.t.sol`; proof acceptance is not. The batch path
is covered — see `tree_update_batch_proof.json` above — but nothing there
exercises `MASP` itself, only the verifier and `PubInputs.compress`.

Regenerating needs `script/fixtures/gen_proof_transfer.ts` extended to three
inputs and three outputs, and 3x3 prover artifacts — the published circuits
tarball ships only 2x2, so point at a local `../circuits/build` which has
`3x3_final.zkey` and `3x3.wasm`.
