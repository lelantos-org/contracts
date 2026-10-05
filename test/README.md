# Test suite

`forge test` runs everything under this directory except the fork tests, which skip themselves unless `FORK_TESTS=1`.

| Command | Runs |
| --- | --- |
| `just test` | Unit, fuzz, invariant and Quint replay tests at the default profile. |
| `just test-fuzz` | `*.fuzz.t.sol` and `*.invariant.t.sol` at the `fuzz` profile. |
| `just halmos` | [symbolic/](symbolic/README.md) |
| `just echidna` | [echidna/](echidna/README.md) |
| `just quint-test` | [quint/](quint/README.md) |

## Layout

Directories are by subject: `masp/`, `yield/`, `native/`, `swap/`, `generic/`, `names/`, `bundler/`, `burn/`, `governance/`, `upgrade/`, `deploy/`, `core/` (tree, nullifiers, curve, compression), `libs/` and `verifiers/`. `fuzz/` and `invariant/` hold cross-cutting suites.

The technique is in the file suffix:

| Suffix | Meaning | Where it runs |
| --- | --- | --- |
| `*.t.sol` | Unit tests | `forge test` |
| `*.fuzz.t.sol` | Fuzzed properties | `forge test`; `just test-fuzz` at 10k runs |
| `*.invariant.t.sol` | Stateful invariant suites | `forge test`; `just test-fuzz` at depth 256 |
| `*.fork.t.sol` | Against a live chain | `FORK_TESTS=1 forge test` |

A new fuzz or invariant suite goes next to its subject. `symbolic/`, `echidna/` and `quint/` are directories because their tools select by path or contract name. Files under `quint/generated/` are generated; do not edit them.

A large suite is split into `Subject.aspect.t.sol` files sharing an abstract base (`Bundler.access.t.sol`, `FeeBurner.price.t.sol`).

## Bases

Use the narrowest base that deploys what the test needs. A suite whose subject is the deployment itself keeps its own `setUp` and uses the free functions in `utils/PoolDeployer.sol`.

| Base | Provides |
| --- | --- |
| `utils/MockPoolTestBase` | Mock verifier stack, `masp`, `_transact` / `_spendTree` spend inputs. No `setUp`: the suite chooses registry, fee and owner. |
| `utils/MASPTestBase` | Real Groth16 verifiers and Permit2, one `MockERC20` at the fixture asset id. |
| `utils/EscrowFlowBase` | A real pool plus `_deposit` / `_flush` / `_depositAndFlush`. |
| `utils/MASPUpgradeTestBase` | `EscrowFlowBase` behind a suite-controlled `DelayedUpgradeProxy`. |
| `utils/YieldTestBase` | A plain and an indexed id over one ERC-20, an ERC-4626 venue, escrow helpers. |
| `utils/WrapperTestBase` | Stub pool, Permit2 and tokens for the escrow wrappers. Extended by `swap/SwapTestBase` and `generic/GenericCallTestBase`. |
| `governance/GovTestBase` | Token, timelock, governor and burner over a real pool owned by the timelock, with proposal helpers. |
| `burn/FeeBurnerTestBase` | `EscrowFlowBase` with the burner as treasury. |

Bases are `abstract`: a concrete contract inherited by other suites reruns its tests once per child.

## Fixtures and helpers

Cheatcode-free libraries, usable from Halmos and Echidna targets:

| Library | Provides |
| --- | --- |
| `SpendFixture` | Transact outputs, spend-tree arguments, valid aux payloads. |
| `DepositFixture` | Deposit requests, Permit2 signatures for an ERC-1271 payer, flush batches and metadata, the cancel fee note. |
| `EscrowLogs` | A deposit's refund cap, read from its `DepositEscrowed` log. |
| `FeeMath` | Expected fee and gross amounts, computed independently of `Fees`. |
| `FixtureLoader` | Groth16 proofs read from fixture JSON, and zero proofs. |
| `TestConstants`, `GovConstants` | Shared values. A suite aliases the ones it uses and keeps a local literal only where the value is what it tests. |

Libraries that use cheatcodes:

- `Stubs`: ERC-1271 etch and accepting verifiers.
- `MaspFlowFixture`: reads `fixtures/masp_flow_proof.json` and replays its deposit and flush through the pool's entry points.

Harnesses that subclass production contracts (`MASPHarness`, `MASPSpendHarness`, `CommitmentTreeHarness`, `NullifierSetHarness`, `CompressHarness`) live in `utils/`. Mocks live in `mocks/`, or in a subject's own `mocks/` when used by that subject only.

Build requests, signatures and batches through these libraries; their shapes are constrained by the pool (distinct nullifiers, the relayer fee leaf, the anchor slot).

## Conventions

- Test names: `test_<subject>_<case>`; `test_revert_<Error>` or `test_revert_<subject>_<case>` for a revert; `testFuzz_<property>`; `invariant_<property>`; `check_<property>` for Halmos.
- Place `vm.expectRevert` immediately before the call under test. Funding and calling are separate helpers (`_fundPayer`, `_depositCall`) because a helper that mints or pranks in between consumes the expectation.
- Warp and roll to absolute values or from `vm.getBlockTimestamp()`. Under `via_ir` the optimizer may cache `block.timestamp` within a call.
- Renaming or moving a test changes its `.gas-snapshot` key. Refresh with `just snapshot`.
