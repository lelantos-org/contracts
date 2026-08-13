set shell := ["bash", "-euo", "pipefail", "-c"]

# === deploy ===

# Deploy profile keeps via_ir but lowers optimizer_runs so MASP fits under
# EIP-170. See the [profile.deploy] comment in foundry.toml.

DEPLOY_PROFILE := "deploy"
SOLC_VERSION := "0.8.35"
MASP_SCRIPT := "script/Deploy.s.sol:Deploy"
SWAP_SCRIPT := "script/DeploySwap.s.sol:DeploySwap"
TEST_SCRIPT := "script/DeployTest.s.sol:DeployTest"
TEST_SWAP_SCRIPT := "script/DeployTestSwap.s.sol:DeployTestSwap"

# Anvil dev defaults — public key #0, chain matches foundry.toml.

ANVIL_RPC := "http://127.0.0.1:8545"
ANVIL_KEY := "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ANVIL_FLAGS := "--rpc-url " + ANVIL_RPC + " --private-key " + ANVIL_KEY + " --broadcast -vvv"

default:
    @just --list

# === build ===

[doc('Compile contracts')]
[group('build')]
build:
    forge build

[doc('Compile and print contract sizes')]
[group('build')]
build-sizes:
    forge build --sizes

# Enforce EIP-170 (24,576 B runtime) under the profile actually shipped:
# the default profile (optimizer_runs=1M) bloats MASP past the limit, the
# deploy profile (optimizer_runs=10k) keeps margin. Non-zero on violation.
[doc('Check runtime sizes against EIP-170 under the deploy profile')]
[group('build')]
size:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge build --sizes --skip test --skip script

[doc('Remove the Foundry build output')]
[group('build')]
clean:
    forge clean

[doc('Install forge dependencies')]
[group('build')]
install:
    forge install

[doc('Print the forge and pinned solc versions')]
[group('build')]
version:
    forge --version
    @echo "solc pinned to: {{ SOLC_VERSION }} (exact pragma in src/, test/, script/)"

# === abi package ===

# Regenerate + typecheck packages/abi (@lelantos-org/contracts) from the
# current build. packages/abi/{src,json,dist} are generated, not committed.
[doc('Rebuild the @lelantos-org/contracts ABI package')]
[group('abi')]
[working-directory('packages/abi')]
abi: build
    npm ci
    npm run build

[doc('Show what the ABI tarball would contain, without publishing')]
[group('abi')]
[working-directory('packages/abi')]
abi-pack: abi
    npm pack --dry-run

# === test ===

[doc('Run the test suite')]
[group('test')]
test:
    forge test -vvv

[doc('Run tests matching a name pattern')]
[group('test')]
test-match pattern:
    forge test -vvv --match-test {{ pattern }}

# Heavy nightly fuzz + invariant sweep. Uses [profile.fuzz] in foundry.toml
# (fuzz runs = 10k, invariant runs = 1024 / depth = 256).
[doc('Heavy nightly fuzz + invariant sweep')]
[group('test')]
test-fuzz:
    FOUNDRY_PROFILE=fuzz forge test -vvv --match-path "test/fuzz/**"
    FOUNDRY_PROFILE=fuzz forge test -vvv --match-path "test/invariant/**"

[doc('Refresh .gas-snapshot')]
[group('test')]
snapshot:
    forge snapshot

# === format ===

[doc('Format Solidity sources')]
[group('format')]
fmt:
    forge fmt

[doc('Fail if Solidity sources need formatting')]
[group('format')]
fmt-check:
    forge fmt --check

# === CI ===

[doc('Everything CI runs, in order')]
[group('ci')]
ci: version build test fmt-check size

# === deploy: anvil ===

[doc('Start a local anvil on chain 31337')]
[group('deploy')]
anvil:
    anvil --chain-id 31337

# Deploy Verifier + MASP + 3 MockERC20s to a running anvil. Reads the
# committed test/fixtures/asset_registry.json.
[doc('Deploy the test stack to a running anvil')]
[group('deploy')]
deploy-anvil:
    forge script {{ TEST_SCRIPT }} {{ ANVIL_FLAGS }}

# Anvil swap-stack deploy. Run AFTER deploy-anvil and export its KEY=value
# output (MASP, PERMIT2, TOKEN_1..3) into env first, e.g.
# `eval "$(just deploy-anvil | e2e/deploy/extract-addresses.sh)"`.
[doc('Deploy the swap stack to a running anvil')]
[group('deploy')]
deploy-test-swap:
    forge script {{ TEST_SWAP_SCRIPT }} {{ ANVIL_FLAGS }}

# === deploy: mainnet ===

# Mainnet (or any non-ephemeral chain) deploy. Reads dependency addresses
# from $MAINNET_CONFIG (default script/config/mainnet.json). Pass --rpc-url
# and a real signer (--private-key, --ledger, --keystore, ...).
[doc('Deploy MASP to a real chain (broadcasts)')]
[group('deploy')]
deploy-mainnet *args:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge script {{ MASP_SCRIPT }} --broadcast -vvv {{ args }}

# Simulation only (no broadcast). Same args as `deploy-mainnet`.
[doc('Simulate the MASP deploy without broadcasting')]
[group('deploy')]
dry-run-mainnet *args:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge script {{ MASP_SCRIPT }} -vvv {{ args }}

# Mainnet swap-stack deploy (UniV3Adapter + SwapWrapper). Reads $SWAP_CONFIG
# (default script/config/mainnet.swap.json). Run AFTER deploy-mainnet — the
# config must list the deployed MASP address.
[doc('Deploy the swap stack to a real chain (broadcasts)')]
[group('deploy')]
deploy-swap *args:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge script {{ SWAP_SCRIPT }} --broadcast -vvv {{ args }}

# Simulation only (no broadcast). Same args as `deploy-swap`.
[doc('Simulate the swap-stack deploy without broadcasting')]
[group('deploy')]
dry-run-swap *args:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge script {{ SWAP_SCRIPT }} -vvv {{ args }}
