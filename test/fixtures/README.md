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

## Removed proof fixtures

`proof_transfer.json` and `proof_deposit_batch_n1.json` were deleted. Both were
2x2-shaped artifacts that the 3x3 pool cannot satisfy, and both were already
inert — every test reading them was skipped.

The tests remain in place, skipped, with the reason recorded at the skip site:

- `MASP.transferSnark.t.sol :: test_transferRealSnark_succeeds`
- `MASP.chainId.t.sol :: test_revert_CrossChainReplay`
- `MASP.chainId.t.sol :: test_revert_BadChainId_spend`
- `MASP.flushBatchSnark.t.sol :: test_realSnark_n1_flushBatchSucceeds`

Consequence: **no test currently verifies a real Groth16 proof end-to-end.**
Layout correctness is covered by `PubInputs.vector3x3.t.sol`; proof acceptance
is not.

Regenerating needs `script/fixtures/gen_proof_transfer.ts` extended to three
inputs and three outputs, and 3x3 prover artifacts — the published circuits
tarball ships only 2x2, so point at a local `../circuits/build` which has
`3x3_final.zkey` and `3x3.wasm`.
