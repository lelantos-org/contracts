# Lelantos Contracts

Solidity implementation of a Multi-Asset Shielded Pool (MASP): private, pooled transfers over ERC-20 assets, with deposits, transfers, and withdrawals proven in zero knowledge.

## Design

Notes are commitments in a quaternary Merkle tree. Deposits are escrowed on submission and inserted into the tree in batches under a single tree-update proof. Spends consume notes by nullifier and produce new commitments, verified against a recent known root. Leaf insertion is proven rather than computed on-chain, keeping per-transaction cost flat in tree depth.

Every spend verifies two Groth16 proofs: a transaction proof (`transact_2x2`) and a tree-update proof that advances the Merkle root. Public inputs are compressed to a single pair `(y, z)` by Fiat-Shamir before pairing, so verification cost is independent of the logical public-input count.

## Components

| Contract | Role |
| --- | --- |
| `MASP.sol` | Pool entry points. Inherits `CommitmentTree`, `AssetRegistry`, `NullifierSet`, `FeeConfig`. |
| `CommitmentTree.sol` | Lazy-root quaternary tree with a 64-slot known-root ring buffer. |
| `AssetRegistry.sol` | Owner-managed asset id to (ERC-20, scale) mapping. Add-only; assets may be disabled, never removed. |
| `NullifierSet.sol` | Packed-bitmap spent-nullifier set. |
| `FeeConfig.sol` | Fee basis points, treasury, and per-token accrual. |
| `libs/PubInputs.sol` | Public-input structs and Fiat-Shamir compression. |
| `libs/AuxValidation.sol` | Bounds and curve checks on per-output FMD payloads. |
| `SnarkCompression.sol` | Horner evaluation over the coefficient vector. |
| `BabyJubJub.sol` | On-curve and prime-order-subgroup checks. |
| `swap/SwapWrapper.sol` | Atomic unshield to swap to re-shield across a MASP pair. |
| `swap/UniV3Adapter.sol` | Uniswap SwapRouter02 adapter for `SwapWrapper`. |

## Entry Points

| Function | Behavior |
| --- | --- |
| `submitIntent` / `submitIntentAuthorized` / `submitIntentNative` | Escrow deposit funds. No proof verified at submission. |
| `flushBatch` | Insert up to `MAX_N_BATCH = 8` escrowed intents under one tree-update proof. |
| `cancelIntent` | Refund the digest-bound payer after `cancelDelay`. |
| `transfer` / `withdraw` / `withdrawNative` | Spend notes, verifying both proofs. |
| `sweep` | Drain accrued fees to the treasury. |

Escrowed funds are never counted as accrued fees: a deposit locks `inAmt + fee` without touching any fee map, `flushBatch` accrues the fee on insertion, and `cancelIntent` refunds principal and fee together.

## Gas

Each Groth16 verifier costs 195 026 per `verifyProof` call, independent of the logical public-input count. End-to-end for a shielded transfer:

| Component | Gas |
| --- | --- |
| `MASP.transfer` total | 524 457 |
| ├ transaction proof | 195 026 |
| ├ tree-update proof | 195 026 |
| └ contract logic, storage, events | 139 405 |

Per-function aggregates, with verification mocked (so excluding the 195 026 per proof above). `Min` is typically an early-revert guard path and `Max` the fullest success path:

| Function | Min | Avg | Max |
| --- | --- | --- | --- |
| `submitIntent` | 30 676 | 125 072 | 171 434 |
| `submitIntentAuthorized` | 41 771 | 88 425 | 145 897 |
| `submitIntentNative` | 28 910 | 60 871 | 159 047 |
| `flushBatch` | 34 287 | 135 790 | 187 047 |
| `cancelIntent` | 25 539 | 51 180 | 66 888 |
| `transfer` | 43 512 | 54 234 | 202 653 |
| `withdraw` | 43 634 | 164 706 | 264 774 |
| `withdrawNative` | 43 261 | 162 760 | 289 730 |
| `sweep` | 24 226 | 27 868 | 56 898 |
| `SwapWrapper.swap` | 45 607 | 54 848 | 289 338 |

`flushBatch` amortizes one tree-update proof and the root advance across up to `MAX_N_BATCH` intents, with fees accrued once per unique token in the batch.

Deployed sizes under the deploy profile (EIP-170 limit 24 576 B):

| Contract | Runtime (B) | Margin (B) |
| --- | --- | --- |
| `MASP` | 20 317 | 4 259 |
| `SwapWrapper` | 7 504 | 17 072 |
| `UniV3Adapter` | 2 073 | 22 503 |
| `Groth16Verifier` | 1 463 | 23 113 |
| `TreeUpdateBatchGroth16Verifier` | 1 463 | 23 113 |

## Circuit Coupling

The public-input layouts in `libs/PubInputs.sol` must match the PolyEval coefficient order used by the circuits in `../circuits`. Both structs are fully static, so their calldata block is word-for-word identical to the coefficient vector; that equivalence is pinned against independent reference implementations in the test suite.

## Dependencies

`@openzeppelin/contracts`, `forge-std`, `poseidon-solidity`, `permit2`. Built with [Foundry](https://book.getfoundry.sh/) against Solidity `^0.8.30`.

## License

MIT. See [LICENSE](LICENSE).

Exception: `src/verifiers/Verifier.sol` and `src/verifiers/TreeUpdateBatchVerifier.sol` are snarkJS codegen output, carry `SPDX-License-Identifier: GPL-3.0` with an upstream copyright notice, and retain their own terms.
