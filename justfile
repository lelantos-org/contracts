set shell := ["bash", "-euo", "pipefail", "-c"]

# === deploy ===

# Deploy profile keeps via_ir but lowers optimizer_runs so MASP fits under
# EIP-170. See the [profile.deploy] comment in foundry.toml.

DEPLOY_PROFILE := "deploy"
ECHIDNA_PROFILE := "echidna"
# Two targets, deliberately separate contracts rather than one wider one.
# `EchidnaMasp` covers the plain-asset state machine; `EchidnaMaspYield` covers
# the indexed-asset accounting, whose setup (a venue, a vault, two ids over one
# ERC-20) and whose properties have nothing in common with it. Sharing a
# contract would mean every sequence paying for both.
ECHIDNA_CONTRACTS := "EchidnaMasp EchidnaMaspYield"
# Must stay in step with `libraries` in [profile.echidna] (foundry.toml).
ECHIDNA_YIELDOPS_ADDR := "0x000000000000000000000000000000000000eC1d"
# Generated, gitignored, and deliberately NOT under out/: a default-profile
# `forge build` prunes stale artifacts from out/, which silently deletes a
# config written to out/echidna/ between the generate step and the run.
SOLC_VERSION := "0.8.36"
MASP_SCRIPT := "script/Deploy.s.sol:Deploy"
SWAP_SCRIPT := "script/DeploySwap.s.sol:DeploySwap"
TEST_SCRIPT := "script/DeployTest.s.sol:DeployTest"
TEST_SWAP_SCRIPT := "script/DeployTestSwap.s.sol:DeployTestSwap"
TEST_YIELD_SCRIPT := "script/DeployTestYield.s.sol:DeployTestYield"
YIELD_SCRIPT := "script/DeployYield.s.sol:DeployYield"
GOV_SCRIPT := "script/DeployGovernance.s.sol:DeployGovernance"
HANDOVER_SCRIPT := "script/HandoverOwnership.s.sol:HandoverOwnership"

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
#
# `--skip Echidna` is required on top of `--skip test`, which is only an alias
# for `.t.sol`: the Echidna property contracts live at test/echidna/*.sol and so
# are built and measured like deployable code. `forge build --sizes` enforces
# EIP-3860 (49,152 B initcode) alongside EIP-170, and EchidnaMasp (~64 kB) and
# EchidnaMaspYield (~61 kB) exceed it by construction — each one instantiates a
# whole pool plus its mocks in a constructor. Echidna deploys them itself and
# never through a transaction, so the initcode limit does not apply to them;
# measuring them here only fails the gate on contracts it is not about.
[doc('Check runtime sizes against EIP-170 under the deploy profile')]
[group('build')]
size:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge build --sizes --skip test --skip script --skip Echidna


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
    # test/yield/ holds YieldSolvency.invariant.t.sol — seven invariants over
    # the indexed-asset accounting, including the "no free money" one that
    # catches a rounding leak or a refund priced off a stale index. It is an
    # invariant suite by everything except its directory, and the two globs
    # above miss it, so until this line it only ever ran at the default 256
    # runs / depth 64 and never at the nightly depth its subject warrants.
    FOUNDRY_PROFILE=fuzz forge test -vvv --match-path "test/yield/**"

# Echidna. Same subject as test/invariant/, different engine: Echidna keeps a
# corpus on disk between runs, so a nightly job compounds instead of restarting
# from a fixed seed. test/echidna/EchidnaMasp.sol has the detail.
#
# The generated-config dance exists because MASP links against the YieldOps
# library and Echidna cannot deploy-and-link one the way Foundry does.
# [profile.echidna] pre-links it at ECHIDNA_YIELDOPS_ADDR at compile time; this
# recipe then reads YieldOps' creation code out of the build and hands it to
# Echidna's `deployBytecodes` so that address actually holds code. Generated
# rather than committed so the blob cannot go stale against a YieldOps change —
# it is rebuilt from the current artifact on every run.
[doc('Run the Echidna property suites (corpus persists in test/echidna/corpus)')]
[group('test')]
echidna limit="50000":
    #!/usr/bin/env bash
    set -euo pipefail
    FOUNDRY_PROFILE={{ ECHIDNA_PROFILE }} forge build --build-info --skip script
    # Every config is generated up front, before any run. crytic-compile
    # re-runs `forge build` scoped to whichever target it is compiling, and
    # Foundry prunes artifacts outside that dependency graph — so running
    # Echidna on the first contract deletes the second's artifact, and
    # generating its config afterwards fails on the missing ABI.
    for c in {{ ECHIDNA_CONTRACTS }}; do just _echidna-config "$c"; done
    for c in {{ ECHIDNA_CONTRACTS }}; do
        echo "=== echidna: $c (property mode) ==="
        FOUNDRY_PROFILE={{ ECHIDNA_PROFILE }} echidna "test/echidna/$c.sol" \
            --contract "$c" \
            --config "test/echidna/$c.generated.yaml" \
            --test-limit {{ limit }}
    done

# Optimization mode: maximise a value instead of asserting it. A property run
# answers "does this ever break"; this answers "how far can it drift" — the
# question a bounded rounding residue cannot be told from a real leak by. Most
# valuable on the yield target, where every conversion between normalized units
# and assets is a mulDiv with a rounding direction. Reports the largest value
# found rather than passing or failing, so it is a report to read, not a gate.
[doc('Run the Echidna suites in optimization mode')]
[group('test')]
echidna-optimize limit="50000":
    #!/usr/bin/env bash
    set -euo pipefail
    FOUNDRY_PROFILE={{ ECHIDNA_PROFILE }} forge build --build-info --skip script
    # Every config is generated up front, before any run. crytic-compile
    # re-runs `forge build` scoped to whichever target it is compiling, and
    # Foundry prunes artifacts outside that dependency graph — so running
    # Echidna on the first contract deletes the second's artifact, and
    # generating its config afterwards fails on the missing ABI.
    for c in {{ ECHIDNA_CONTRACTS }}; do just _echidna-config "$c"; done
    for c in {{ ECHIDNA_CONTRACTS }}; do
        echo "=== echidna: $c (optimization mode) ==="
        # `|| true` is required, not laziness. Echidna exits non-zero in
        # optimization mode whatever it finds: an optimization target is never
        # "solved", so it is reported as an open test the way a failing
        # property would be. Measured — property mode on the same contract
        # exits 0, optimization mode exits 1 with both maxima at 0. Without
        # this, `set -e` aborts the loop after the first contract, and in CI
        # the step would fail the job every night for reporting good news.
        FOUNDRY_PROFILE={{ ECHIDNA_PROFILE }} echidna "test/echidna/$c.sol" \
            --contract "$c" \
            --config "test/echidna/$c.optimize.generated.yaml" \
            --test-limit {{ limit }} || true
    done

# Merge echidna.yaml with the YieldOps bytecode placement, once per test mode,
# for the named contract. Internal to the two recipes above.
#
# Two files per contract rather than one because Echidna's `prefix` selects the
# targets for whichever mode is running: under `testMode: optimization` it reads
# every `echidna_`-prefixed function as an optimization target and aborts with
# "Optimization \"echidna_...\" does not return int256". Each config therefore
# names its own prefix and blacklists the other mode's functions, so neither set
# is fuzzed as if it were a state transition.
[private]
_echidna-config contract:
    #!/usr/bin/env bash
    set -euo pipefail
    CONTRACT="{{ contract }}" python3 - <<'PY'
    import json, os, pathlib

    contract = os.environ["CONTRACT"]

    artifact = json.load(open("out/YieldOps.sol/YieldOps.json"))
    # Creation code, not runtime: `deployBytecodes` executes it as a contract
    # creation at the given address, and solc's library call-protection guard
    # (the `address(this) == <deploy address>` check at the top of every
    # library) is only filled in by that constructor. Placing runtime code
    # directly would leave the guard comparing against zero, so every
    # delegatecall from MASP would revert.
    code = artifact["bytecode"]["object"]
    assert code.startswith("0x") and len(code) > 2, "YieldOps has no creation bytecode"
    assert not artifact["bytecode"].get("linkReferences"), "YieldOps is itself unlinked"
    code = code[2:]  # echidna decodes this as bare base16; a 0x prefix is a parse error

    base = pathlib.Path("echidna.yaml").read_text()
    placement = (
        "\n# Generated by `just _echidna-config` — do not edit.\n"
        "# YieldOps creation code, run at the address [profile.echidna] pre-linked\n"
        "# into MASP. Regenerated from the current artifact on every run.\n"
        f'deployBytecodes: [["{{ ECHIDNA_YIELDOPS_ADDR }}", "{code}"]]\n'
        f"corpusDir: test/echidna/corpus/{contract}\n"
    )

    # Read the two target sets out of the ABI rather than listing them here.
    # Echidna does not validate `filterFunctions` — a name that matches nothing
    # is accepted in silence — so a hardcoded list would go stale the first
    # time a property is added or renamed, and nothing would say so.
    target_abi = json.load(open(f"out/{contract}.sol/{contract}.json"))["abi"]
    names = sorted(e["name"] for e in target_abi if e.get("type") == "function")
    PROPERTIES = [n for n in names if n.startswith("echidna_")]
    OPTIMIZERS = [n for n in names if n.startswith("optimize_")]
    assert PROPERTIES, f"no echidna_ properties found in {contract}"
    assert OPTIMIZERS, f"no optimize_ targets found in {contract}"

    def blacklist(names):
        entries = ", ".join(f'"{contract}.{n}()"' for n in names)
        return "filterBlacklist: true\n" f"filterFunctions: [{entries}]\n"

    written = []
    for path, extra in (
        (f"test/echidna/{contract}.generated.yaml", blacklist(OPTIMIZERS)),
        (
            f"test/echidna/{contract}.optimize.generated.yaml",
            "testMode: optimization\nprefix: optimize_\n" + blacklist(PROPERTIES),
        ),
    ):
        out = pathlib.Path(path)
        out.write_text(base + placement + "\n" + extra)
        written.append(out.name)
    print(
        f"echidna configs -> {', '.join(written)} "
        f"({len(PROPERTIES)} properties, {len(OPTIMIZERS)} optimization targets, "
        f"YieldOps {len(code) // 2} bytes)"
    )
    PY

[doc('Refresh .gas-snapshot')]
[group('test')]
snapshot:
    forge snapshot

# === quint (model-based testing) ===

# Traces are generated offline and committed; replaying them is plain Foundry.
# So `just test` and the `test` CI job need neither node nor quint, and only
# these recipes do. The tool lives in lib/quint-sol-connect (a submodule), and
# the submodule commit is the version pin.

[doc('Install the quint toolchain into lib/quint-sol-connect')]
[group('quint')]
[working-directory('lib/quint-sol-connect')]
quint-install:
    npm ci

# One invocation per file: `quint typecheck` takes a single input and rejects a
# multi-file glob with "Unknown arguments".
[doc('Typecheck the Quint specs themselves')]
[group('quint')]
quint-spec:
    #!/usr/bin/env bash
    set -euo pipefail
    for f in spec/*.qnt; do
        echo "typecheck $f"
        lib/quint-sol-connect/node_modules/.bin/quint typecheck "$f"
    done

# Rewrites test/fixtures/quint/** and test/quint/generated/**, both committed.
# The seed is pinned in quint-connect.config.mjs, so an unchanged spec
# regenerates byte-identically and `quint-diff` below is the gate on that.
[doc('Regenerate Quint trace fixtures and generated Solidity')]
[group('quint')]
quint-gen *specs:
    node lib/quint-sol-connect/bin/quint-sol-connect.mjs gen {{ specs }}

# No quint, no regeneration: re-derives the schema hash from the config and
# compares it against every committed fixture. Catches a config or submodule
# bump that was not followed by `just quint-gen`.
[doc('Fail if committed traces drifted from the config')]
[group('quint')]
quint-check:
    node lib/quint-sol-connect/bin/quint-sol-connect.mjs check

[doc('Prove regeneration is a no-op on unchanged specs')]
[group('quint')]
quint-diff: quint-gen
    git diff --exit-code -- test/fixtures/quint test/quint/generated

[doc('Replay the committed Quint traces')]
[group('quint')]
quint-test *args:
    forge test -vvv --match-path "test/quint/**" {{ args }}

# Nightly counterpart: fresh randomness rather than the pinned seed.
#
# Both outputs go to git-ignored scratch paths, and neither touches the
# committed suite. Fixtures land under test/fixtures/ so the existing
# fs_permissions read grant covers them; the per-trace contract lands in
# test/quint/fresh/ so forge compiles it, named <Name>FreshTraces so it cannot
# collide with the committed one. `just quint-check` and `just quint-diff` stay
# meaningful after a fresh run precisely because it writes nowhere they look.
[doc('Generate fresh random traces and replay them')]
[group('quint')]
quint-fresh:
    rm -rf test/fixtures/quint-fresh test/quint/fresh
    node lib/quint-sol-connect/bin/quint-sol-connect.mjs gen --fresh \
        --out test/fixtures/quint-fresh --sol-out test/quint/fresh \
        --traces 64 --steps 200
    forge test -vvv --match-path "test/quint/fresh/**"

# === symbolic ===

# Halmos proves a property for every input in a bounded state space, where the
# fuzzer samples it. The suite under test/symbolic/ restates properties the
# fuzz and invariant suites already cover, so a regression those would only
# sometimes catch fails deterministically here.
#
# Halmos shells out to `forge build --ast` itself and inherits FOUNDRY_PROFILE,
# so the profile is set here rather than passed through: it selects the
# artifacts `forge-build-out` in halmos.toml points at. Everything else —
# solver, timeouts, loop bounds, which contracts are in scope — lives in
# halmos.toml; per-test overrides go in NatSpec (`@custom:halmos --...`).
#
# Extra args are forwarded, e.g. `just halmos -v` or `just halmos --statistics`.
[doc('Prove the symbolic suite with halmos')]
[group('symbolic')]
halmos *args:
    FOUNDRY_PROFILE=halmos halmos {{ args }}

# The pattern is a regex matched against the `check_` functions in
# test/symbolic/, but halmos prepends its own `(check|invariant)_` prefix to it
# unless the regex starts with `^`. So `just halmos-match unitFee` works and
# `just halmos-match check_unitFee` silently matches nothing — write
# `just halmos-match '^check_unitFee'` when anchoring.
[doc('Run symbolic tests matching a name pattern')]
[group('symbolic')]
halmos-match pattern *args:
    FOUNDRY_PROFILE=halmos halmos --match-test {{ pattern }} {{ args }}

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

# Mirrors the `slither` job in .github/workflows/ci.yml. Slither parses
# `out/build-info` rather than compiling itself, so the build must come first
# (and `ast = true` in foundry.toml must stay set — see the note there).
# `--fail-medium` is what the action's `fail-on: medium` resolves to.
# `--no-dynamic-test-linking` is required: foundry 1.8 turned dynamic test
# linking on by default, which injects synthetic `foundry-pp/DeployHelperN.sol`
# sources into the build info. Those have no file on disk, so crytic-compile
# aborts with `InvalidCompilation: Unknown file: foundry-pp/...`. Slither wants
# the real sources anyway.
# `forge clean` first: an incremental build rewrites build-info only for what it
# recompiled, leaving entries with no `output` key, and crytic-compile dies on
# `KeyError: 'output'`. CI checks out fresh, so only local runs hit this.
[doc('Run Slither (mirrors the CI job)')]
[group('ci')]
slither:
    forge clean
    forge build --build-info --no-dynamic-test-linking
    slither . --config-file slither.config.json --ignore-compile --fail-medium

# Aderyn (Cyfrin) is an AST-level analyzer run alongside Slither: the two
# detector sets only partly overlap, and Aderyn is a single static binary, so it
# costs a couple of seconds. Scope and detector exclusions live in aderyn.toml;
# individual false positives are suppressed at the site with
# `// aderyn-fp-next-line(<detector>)`, so a detector keeps firing on new code.
#
# Aderyn always exits 0, even holding high-severity findings, so the JSON report
# is what gates: any High fails this recipe. Lows are written to the report but
# not enforced — `centralization-risk` alone fires on every owner-gated setter
# here, and gating on it would be gating on the admin model.
#
# Unlike `slither`, this needs no `forge build`: Aderyn drives solc itself and
# reads remappings out of foundry.toml.
[doc('Run Aderyn and fail on any High finding (mirrors the CI job)')]
[group('ci')]
aderyn:
    #!/usr/bin/env bash
    set -euo pipefail
    aderyn . -o aderyn-report.md
    aderyn . -o aderyn-report.json
    python3 - <<'PY'
    import json, sys

    report = json.load(open("aderyn-report.json"))
    highs = report["high_issues"]["issues"]
    if not highs:
        print(f"aderyn: no high findings ({report['issue_count']['low']} low, see aderyn-report.md)")
        sys.exit(0)
    total = sum(len(i["instances"]) for i in highs)
    print(f"aderyn: {total} high finding(s) across {len(highs)} detector(s)\n", file=sys.stderr)
    for issue in highs:
        print(f"  [{issue['detector_name']}] {issue['title']}", file=sys.stderr)
        for inst in issue["instances"]:
            print(f"    {inst['contract_path']}:{inst['line_no']}", file=sys.stderr)
    print(
        "\nFix it, or — if it is a false positive — annotate the flagged line with"
        "\n  // aderyn-fp-next-line(<detector-name>)"
        "\nand say why in the line above. Full report: aderyn-report.md",
        file=sys.stderr,
    )
    sys.exit(1)
    PY

[doc('Everything CI runs, in order')]
[group('ci')]
ci: version build test fmt-check size quint-check

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
# `eval "$(just deploy-anvil | grep -oE '^[A-Z_0-9]+=0x[0-9a-fA-F]{40}')"`.
[doc('Deploy the swap stack to a running anvil')]
[group('deploy')]
deploy-test-swap:
    forge script {{ TEST_SWAP_SCRIPT }} {{ ANVIL_FLAGS }}

# Anvil yield-stack deploy: a MockERC4626 + ERC4626Venue per fixture asset,
# registered as new yield ids (1,2,3 -> 4,5,6). Run AFTER deploy-anvil and
# export its KEY=value output (MASP, TOKEN_1..3) into env first, e.g.
# `eval "$(just deploy-anvil | grep -oE '^[A-Z_0-9]+=0x[0-9a-fA-F]{40}')"`.
# Registration is permanent, so this runs once per MASP.
[doc('Deploy the yield stack to a running anvil')]
[group('deploy')]
deploy-test-yield:
    forge script {{ TEST_YIELD_SCRIPT }} {{ ANVIL_FLAGS }}

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

# Mainnet swap-stack deploy (UniV3Adapter + optional UniV4Adapter + SwapWrapper).
# Reads $SWAP_CONFIG
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

# Mainnet yield deploy (one ERC4626Venue per configured asset, then the owner
# registration binding each to a new asset id). Reads $YIELD_CONFIG
# (default script/config/mainnet.yield.json). Run AFTER deploy-mainnet — the
# config must list the deployed MASP address and real ERC-4626 vaults.
# Must be broadcast by the pool's owner: `addYieldAsset` is `onlyOwner`.
[doc('Deploy yield venues to a real chain (broadcasts)')]
[group('deploy')]
deploy-yield *args:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge script {{ YIELD_SCRIPT }} --broadcast -vvv {{ args }}

# Simulation only (no broadcast). Same args as `deploy-yield`. Worth running
# first: a venue binding is permanent, so a wrong vault retires the asset id.
[doc('Simulate the yield deploy without broadcasting')]
[group('deploy')]
dry-run-yield *args:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge script {{ YIELD_SCRIPT }} -vvv {{ args }}

# === deploy: governance ===

# Governance-stack deploy (token + timelock + governor + burner + admin).
# Reads $GOV_CONFIG (default script/config/mainnet.gov.json). Run AFTER
# deploy-mainnet and deploy-swap — the config must name both deployed
# addresses. The deployer's timelock admin is renounced as the last
# transaction, so a failed run is recoverable but a completed one is final.
#
# This does NOT hand the pool over; see `handover`.
[doc('Deploy the governance stack to a real chain (broadcasts)')]
[group('deploy')]
deploy-gov *args:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge script {{ GOV_SCRIPT }} --broadcast -vvv {{ args }}

# Simulation only (no broadcast). Same args as `deploy-gov`. Always run this
# first: several configured values (quorum in particular) cannot be fixed
# afterwards without the very governance they configure.
[doc('Simulate the governance deploy without broadcasting')]
[group('deploy')]
dry-run-gov *args:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge script {{ GOV_SCRIPT }} -vvv {{ args }}

# Move MASP + SwapWrapper under governance. Signed by the CURRENT owner EOA.
# Requires $PROTOCOL_ADMIN and $FEE_BURNER from the deploy-gov output.
#
# One-way and unrecoverable: `Ownable` is single-step, so a wrong address takes
# the pool's whole admin surface with it. Do not run until real delegated
# weight exists and a dry-run proposal has passed end to end on a testnet
# clone — a timelock-owned pool with nobody delegated has no administrator.
[doc('Hand MASP + SwapWrapper to governance (broadcasts, one-way)')]
[group('deploy')]
handover *args:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge script {{ HANDOVER_SCRIPT }} --broadcast -vvv {{ args }}

# Simulation only. Always run before `handover`.
[doc('Simulate the ownership handover without broadcasting')]
[group('deploy')]
dry-run-handover *args:
    FOUNDRY_PROFILE={{ DEPLOY_PROFILE }} forge script {{ HANDOVER_SCRIPT }} -vvv {{ args }}
