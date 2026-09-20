# Test suite

`forge test` runs everything under this directory except the fork tests, which
skip themselves unless `FORK_TESTS=1`. The heavier engines have their own
entry points and READMEs: `just test-fuzz` (fuzz and invariant suites at the
`fuzz` profile), `just halmos` ([symbolic/](symbolic/README.md)),
`just echidna` ([echidna/](echidna/README.md)) and the Quint trace replays
([quint/](quint/README.md)).

## Layout

Directories are by subject: `masp/`, `yield/`, `native/`, `swap/`, `generic/`,
`bundler/`, `burn/`, `governance/`, `upgrade/`, `deploy/`, `core/` (tree,
nullifiers, curve, compression), `libs/` and `verifiers/`.

The technique goes in the file suffix, not the directory:

| Suffix | Meaning | Where it runs |
| --- | --- | --- |
| `*.t.sol` | Unit tests | `forge test` |
| `*.fuzz.t.sol` | Suites whose subject is a fuzzed property | `forge test`, and `just test-fuzz` at 10k runs |
| `*.invariant.t.sol` | Stateful invariant suites | `forge test`, and `just test-fuzz` at depth 256 |
| `*.fork.t.sol` | Against a live chain | `FORK_TESTS=1 forge test` |

`fuzz/` and `invariant/` still hold the cross-cutting suites that predate this
rule. A new fuzz or invariant suite goes next to its subject; the nightly
recipe selects it by suffix.

`symbolic/`, `echidna/` and `quint/` are directories because their tools
select by path or contract name. Everything under `quint/generated/` is
regenerated; do not edit it.

A large suite is split into `Subject.aspect.t.sol` files sharing an abstract
base (`Bundler.access.t.sol`, `FeeBurner.price.t.sol`), rather than grown past
a few hundred lines.

## Bases

Pick the narrowest base that deploys what the test needs. A suite whose subject
is the deployment itself (registry, owner, fee legs, verifier wiring) keeps its
own `setUp` and uses the free functions in `utils/PoolDeployer.sol` directly.

| Base | Provides |
| --- | --- |
| `utils/MockPoolTestBase` | Mock verifier stack, `masp`, `_transact`/`_spendTree` spend inputs. No `setUp`: the suite chooses registry, fee and owner. |
| `utils/MASPTestBase` | Real Groth16 verifiers and Permit2, one `MockERC20` at the fixture asset id. |
| `utils/EscrowFlowBase` | A real pool plus `_deposit`/`_flush`/`_depositAndFlush`, for tests that need accrued fees or a non-empty tree. |
| `utils/MASPUpgradeTestBase` | `EscrowFlowBase` behind a suite-controlled `DelayedUpgradeProxy`. |
| `utils/YieldTestBase` | A plain and an indexed id over one ERC-20, an ERC-4626 venue, escrow helpers. |
| `utils/WrapperTestBase` | Stub pool, Permit2 and tokens for the escrow wrappers; extended by `swap/SwapTestBase` and `generic/GenericCallTestBase`. |
| `governance/GovTestBase` | Token, timelock, governor and burner over a real pool owned by the timelock, with proposal helpers. |
| `burn/FeeBurnerTestBase` | `EscrowFlowBase` with the burner as treasury. |

Bases are `abstract`. A concrete contract that other suites inherit reruns
every test it declares once per child.

## Fixtures and helpers

Cheatcode-free libraries, usable from Halmos and Echidna targets too:

- `SpendFixture`: transact outputs, spend-tree arguments, valid aux payloads.
- `DepositFixture`: deposit requests, Permit2 signatures for an ERC-1271 payer,
  flush batches and metadata, the cancel fee note.
- `FeeMath`: the expected fee and gross amounts, restated independently of
  `Fees`.
- `FixtureLoader`: the bundled proof JSON, and zero proofs.
- `TestConstants`, `GovConstants`: shared values. A suite aliases the ones it
  uses (`uint64 internal constant ASSET_ID = TestConstants.ASSET_ID`) and keeps
  a local literal only where the value is what it tests.

`Stubs` (ERC-1271 etch, accepting verifiers) uses cheatcodes. Harnesses that
subclass production contracts (`MASPHarness`, `MASPSpendHarness`,
`CommitmentTreeHarness`, `NullifierSetHarness`) live in `utils/`; mocks live in
`mocks/`, or in a subject's own `mocks/` when nothing else uses them.

Use these rather than restating a request, signature or batch in a suite: the
shapes are constrained by the pool (distinct nullifiers, the relayer fee leaf,
the anchor slot), and a copy drifts the first time one of them changes.

## Conventions

- Test names: `test_<subject>_<case>`, `test_revert_<Error>` or
  `test_revert_<subject>_<case>` for a revert, `testFuzz_<property>` for a fuzz
  test, `invariant_<property>` for an invariant, `check_<property>` for Halmos.
- Put `vm.expectRevert` immediately before the call under test. A helper that
  mints or pranks in between consumes it; that is why funding and calling are
  separate helpers (`_fundPayer`, `_depositCall`).
- Warp and roll to absolute values or from `vm.getBlockTimestamp()`: under
  `via_ir` the optimizer may cache `block.timestamp` within a call.
- Renaming or moving a test changes its `.gas-snapshot` key; refresh with
  `just snapshot`.
