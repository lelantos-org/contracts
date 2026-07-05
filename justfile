set shell := ["bash", "-uc"]

# Path to circuits/build/. Override for non-sibling layouts:
#   just --set CIRCUITS_BUILD /abs/path gen-proof-deposit
CIRCUITS_BUILD := justfile_directory() / "../circuits/build"

# Anvil dev defaults — public key #0, chain matches foundry.toml.
ANVIL_RPC := "http://127.0.0.1:8545"
ANVIL_KEY := "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

default:
    @just --list

# === build ===

build:
    forge build

build-sizes:
    forge build --sizes

# Enforce EIP-170 (24,576 B runtime) under the deploy profile that is
# actually shipped to mainnet. Default profile (optimizer_runs=1M) bloats
# MASP past the limit; deploy profile (optimizer_runs=10k) keeps margin.
# Exits non-zero on violation — wired into CI.
size:
    FOUNDRY_PROFILE=deploy forge build --sizes --skip test --skip script

clean:
    forge clean

install:
    forge install

version:
    forge --version

# === test ===

test:
    forge test -vvv

test-match pattern:
    forge test -vvv --match-test {{pattern}}

# Heavy nightly fuzz + invariant sweep. Uses [profile.fuzz] in foundry.toml
# (fuzz runs = 10k, invariant runs = 1024 / depth = 256).
test-fuzz:
    FOUNDRY_PROFILE=fuzz forge test -vvv --match-path "test/fuzz/**"
    FOUNDRY_PROFILE=fuzz forge test -vvv --match-path "test/invariant/**"

snapshot:
    forge snapshot

# === format ===

fmt:
    forge fmt

fmt-check:
    forge fmt --check

# === CI ===

ci: version build test fmt-check size

# === fixtures ===

# Regenerate fixtures consumed by DeployTest.s.sol + tests.
gen-fixtures: gen-asset-registry gen-proof-deposit-batch

gen-asset-registry:
    npm run --silent gen-asset-registry

gen-proof-deposit-batch:
    test -f "{{CIRCUITS_BUILD}}/tree_update_batch_final.zkey" || \
      (echo "missing {{CIRCUITS_BUILD}}/tree_update_batch_final.zkey — run 'cd ../circuits && just rebuild-batch'" && exit 1)
    CIRCUITS_BUILD="{{CIRCUITS_BUILD}}" npm run --silent gen-proof-deposit-batch

# Regenerate proof_transfer.json using the @lelantos-org/circuits@0.6.4 zkeys:
#   2x2       — node_modules/@lelantos-org/circuits/build/
#   TUB       — TUB_CIRCUITS_BUILD (default: ../../e2e/circuits from npm release)
# Override TUB_CIRCUITS_BUILD if the e2e circuits dir is elsewhere.
TUB_CIRCUITS_BUILD := env_var_or_default("TUB_CIRCUITS_BUILD", justfile_directory() / "../../e2e/circuits")

gen-proof-transfer:
    test -f "{{TUB_CIRCUITS_BUILD}}/tree_update_batch_final.zkey" || \
      (echo "missing {{TUB_CIRCUITS_BUILD}}/tree_update_batch_final.zkey — run 'just fetch-circuits' in e2e/" && exit 1)
    CIRCUITS_BUILD="{{CIRCUITS_BUILD}}" \
      TX_CIRCUITS_BUILD="{{justfile_directory()}}/node_modules/@lelantos-org/circuits/build" \
      TUB_CIRCUITS_BUILD="{{TUB_CIRCUITS_BUILD}}" \
      npm run --silent gen-proof-transfer

# === deploy: anvil ===

anvil:
    anvil --chain-id 31337

# Deploy Verifier + MASP + 3 MockERC20s to a running anvil. Requires
# test/fixtures/asset_registry.json (run `just gen-fixtures` first).
deploy-anvil:
    forge script script/DeployTest.s.sol:DeployTest \
      --rpc-url {{ANVIL_RPC}} --private-key {{ANVIL_KEY}} --broadcast -vvv

# Anvil swap-stack deploy. Run AFTER deploy-anvil and export its
# KEY=value output (MASP, PERMIT2, TOKEN_1..3) into env first, e.g.:
#   eval "$(just deploy-anvil | e2e/deploy/extract-addresses.sh)"
#   just deploy-test-swap
deploy-test-swap:
    forge script script/DeployTestSwap.s.sol:DeployTestSwap \
      --rpc-url {{ANVIL_RPC}} --private-key {{ANVIL_KEY}} --broadcast -vvv

# === deploy: mainnet ===

# Mainnet (or any non-ephemeral chain) deploy. Reads dependency addresses
# from $MAINNET_CONFIG (default script/config/mainnet.json). Pass --rpc-url
# and a real signer (--private-key, --ledger, --keystore, ...).
deploy-mainnet *args:
    FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy --broadcast -vvv {{args}}

# Simulation only (no broadcast). Same args as `deploy-mainnet`.
dry-run-mainnet *args:
    FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy -vvv {{args}}

# Mainnet swap-stack deploy (UniV3Adapter + SwapWrapper). Reads
# $SWAP_CONFIG (default script/config/mainnet.swap.json). Run AFTER
# deploy-mainnet — config must list deployed MASP address.
deploy-swap *args:
    FOUNDRY_PROFILE=deploy forge script script/DeploySwap.s.sol:DeploySwap --broadcast -vvv {{args}}

# Simulation only (no broadcast). Same args as `deploy-swap`.
dry-run-swap *args:
    FOUNDRY_PROFILE=deploy forge script script/DeploySwap.s.sol:DeploySwap -vvv {{args}}
