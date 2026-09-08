// Generates the shipped ABI sources from the Foundry build in `out/`.
//
// Each entry below is resolved by its *source path*, not by artifact file
// name: `out/` is keyed on basename, so a `Verifier.sol` in `lib/` would
// otherwise be indistinguishable from ours. Every artifact's
// `metadata.settings.compilationTarget` is checked against the expected
// source path before its ABI is emitted.
//
// Output (all git-ignored, regenerated on every build):
//   src/abis/<Contract>.ts   — `as const` ABI, for viem/wagmi type inference
//   src/index.ts             — barrel of named `<contract>Abi` exports
//   json/<Contract>.json     — plain ABI array, for non-TS consumers
//
// `dist/` is wiped here too. tsc does not prune its own outDir, so a renamed or
// dropped contract would otherwise leave a stale module behind — and the `./*`
// subpath export would keep it importable and publishable.

import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pkgDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = join(pkgDir, "..", "..");
const outDir = join(repoRoot, "out");

/**
 * @type {Array<{ source: string, contract: string, export: string }>}
 * `source` is the path under the repo root; `contract` the name inside it;
 * `export` the camelCase symbol the package exposes.
 *
 * `UpgradeStorage` is omitted: it declares only internal functions, so its
 * artifact carries an empty ABI. `TimelockController` is omitted because it is
 * unmodified OpenZeppelin and ships with that package.
 */
const CONTRACTS = [
    { source: "src/MASP.sol", contract: "MASP", export: "maspAbi" },
    { source: "src/AssetRegistry.sol", contract: "AssetRegistry", export: "assetRegistryAbi" },
    { source: "src/CommitmentTree.sol", contract: "CommitmentTree", export: "commitmentTreeAbi" },
    { source: "src/FeeConfig.sol", contract: "FeeConfig", export: "feeConfigAbi" },
    { source: "src/NullifierSet.sol", contract: "NullifierSet", export: "nullifierSetAbi" },
    { source: "src/DelayedUpgradeProxy.sol", contract: "DelayedUpgradeProxy", export: "delayedUpgradeProxyAbi" },
    { source: "src/OwnableInit.sol", contract: "OwnableInit", export: "ownableInitAbi" },
    { source: "src/governance/LelantosToken.sol", contract: "LelantosToken", export: "lelantosTokenAbi" },
    { source: "src/governance/LelantosGovernor.sol", contract: "LelantosGovernor", export: "lelantosGovernorAbi" },
    { source: "src/governance/ProtocolAdmin.sol", contract: "ProtocolAdmin", export: "protocolAdminAbi" },
    { source: "src/burn/FeeBurner.sol", contract: "FeeBurner", export: "feeBurnerAbi" },
    { source: "src/yield/YieldIndex.sol", contract: "YieldIndex", export: "yieldIndexAbi" },
    { source: "src/yield/YieldOps.sol", contract: "YieldOps", export: "yieldOpsAbi" },
    { source: "src/yield/IYieldVenue.sol", contract: "IYieldVenue", export: "yieldVenueAbi" },
    { source: "src/yield/ERC4626Venue.sol", contract: "ERC4626Venue", export: "erc4626VenueAbi" },
    { source: "src/MaspEscrowSatellite.sol", contract: "MaspEscrowSatellite", export: "maspEscrowSatelliteAbi" },
    { source: "src/native/NativeAdapter.sol", contract: "NativeAdapter", export: "nativeAdapterAbi" },
    { source: "src/swap/SwapWrapper.sol", contract: "SwapWrapper", export: "swapWrapperAbi" },
    { source: "src/swap/UniV3Adapter.sol", contract: "UniV3Adapter", export: "uniV3AdapterAbi" },
    { source: "src/swap/UniV4Adapter.sol", contract: "UniV4Adapter", export: "uniV4AdapterAbi" },
    { source: "src/swap/ISwapAdapter.sol", contract: "ISwapAdapter", export: "swapAdapterAbi" },
    { source: "src/interfaces/IMASPPool.sol", contract: "IMASPPool", export: "imaspPoolAbi" },
    { source: "src/interfaces/IVerifier.sol", contract: "IVerifier", export: "verifierInterfaceAbi" },
    { source: "src/interfaces/IBatchVerifier.sol", contract: "IBatchVerifier", export: "batchVerifierInterfaceAbi" },
    { source: "src/interfaces/IWrappedNative.sol", contract: "IWrappedNative", export: "wrappedNativeAbi" },
    { source: "src/verifiers/Verifier.sol", contract: "Groth16Verifier", export: "groth16VerifierAbi" },
    {
        source: "src/verifiers/TreeUpdateBatchVerifier.sol",
        contract: "TreeUpdateBatchGroth16Verifier",
        export: "treeUpdateBatchVerifierAbi",
    },
    {
        source: "src/verifiers/BatchedGroth16Verifier.sol",
        contract: "BatchedGroth16Verifier",
        export: "batchedGroth16VerifierAbi",
    },
];

/**
 * Contracts under `src/` that are intentionally not published, and why.
 *
 * Every other `src/` contract with a non-empty ABI must appear in `CONTRACTS`;
 * `assertNoDrift` fails the build otherwise. Without that check a newly added
 * contract is simply absent from the package, which is not visible until a
 * consumer needs it.
 */
const EXCLUDED = new Map([
    ["src/UpgradeStorage.sol:UpgradeStorage", "internal-only library; empty ABI"],
    ["src/SnarkCompression.sol:SnarkCompression", "proof plumbing; not a consumer surface"],
    ["src/libs/AuxValidation.sol:AuxValidation", "proof plumbing; not a consumer surface"],
    ["src/burn/FeeBurner.sol:IFeeSweeper", "helper interface declared alongside its consumer"],
    ["src/interfaces/IProtocolAdmin.sol:IProtocolAdmin", "admin plumbing; not a consumer surface"],
    ["src/interfaces/IProtocolAdmin.sol:IPoolAdmin", "admin plumbing; not a consumer surface"],
    ["src/interfaces/IProtocolAdmin.sol:IWrapperAdmin", "admin plumbing; not a consumer surface"],
    ["src/swap/UniV3Adapter.sol:ISwapRouter02", "external router surface, transcribed locally"],
    ["src/swap/UniV4Adapter.sol:IUniversalRouter", "external router surface, transcribed locally"],
    ["src/yield/YieldOps.sol:IERC4626Asset", "helper interface declared alongside its consumer"],
]);

/** Duplicate names silently overwrite an output file or break the barrel. */
function assertUnique() {
    for (const key of ["contract", "export"]) {
        const seen = new Set();
        for (const entry of CONTRACTS) {
            if (seen.has(entry[key])) throw new Error(`duplicate ${key} "${entry[key]}" in CONTRACTS`);
            seen.add(entry[key]);
        }
    }
}

/**
 * Fails when a `src/` contract with a non-empty ABI is neither published nor
 * listed in `EXCLUDED`. Walks the Foundry build rather than the source tree, so
 * it sees exactly what solc produced.
 */
function assertNoDrift() {
    const known = new Set([...CONTRACTS.map((e) => `${e.source}:${e.contract}`), ...EXCLUDED.keys()]);
    const missing = [];
    for (const dir of readdirSync(outDir, { withFileTypes: true })) {
        if (!dir.isDirectory()) continue;
        for (const file of readdirSync(join(outDir, dir.name))) {
            if (!file.endsWith(".json")) continue;
            let artifact;
            try {
                artifact = JSON.parse(readFileSync(join(outDir, dir.name, file), "utf8"));
            } catch {
                continue;
            }
            if (!artifact.abi?.length) continue;
            for (const [source, contract] of Object.entries(artifact.metadata?.settings?.compilationTarget ?? {})) {
                if (!source.startsWith("src/")) continue;
                if (!known.has(`${source}:${contract}`)) missing.push(`${source}:${contract}`);
            }
        }
    }
    if (missing.length) {
        throw new Error(
            `these src/ contracts are neither published nor excluded:\n  ${[...new Set(missing)].sort().join("\n  ")}\n` +
                "add them to CONTRACTS, or to EXCLUDED with a reason",
        );
    }
}

function artifactPath({ source, contract }) {
    return join(outDir, source.split("/").pop(), `${contract}.json`);
}

function loadAbi(entry) {
    const path = artifactPath(entry);
    let artifact;
    try {
        artifact = JSON.parse(readFileSync(path, "utf8"));
    } catch (cause) {
        throw new Error(`missing artifact ${path} — run \`forge build\` first`, { cause });
    }
    const target = artifact.metadata?.settings?.compilationTarget ?? {};
    if (target[entry.source] !== entry.contract) {
        throw new Error(
            `${path} was compiled from ${JSON.stringify(target)}, expected ` +
                `{"${entry.source}":"${entry.contract}"} — basename collision with a lib/ or test/ contract`,
        );
    }
    if (!Array.isArray(artifact.abi)) throw new Error(`${path} has no abi array`);
    return { abi: artifact.abi, solc: artifact.metadata?.compiler?.version ?? "unknown" };
}

assertUnique();
assertNoDrift();

const srcDir = join(pkgDir, "src");
const abisDir = join(srcDir, "abis");
const jsonDir = join(pkgDir, "json");
const distDir = join(pkgDir, "dist");
for (const dir of [srcDir, jsonDir, distDir]) rmSync(dir, { recursive: true, force: true });
mkdirSync(abisDir, { recursive: true });
mkdirSync(jsonDir, { recursive: true });

const solcVersions = new Set();
const barrel = [
    "// GENERATED by scripts/generate.mjs from the Foundry build — do not edit.",
    "",
];

for (const entry of CONTRACTS) {
    const { abi, solc } = loadAbi(entry);
    solcVersions.add(solc);
    const body = [
        `// GENERATED from ${entry.source}:${entry.contract} (solc ${solc}) — do not edit.`,
        "",
        `export const ${entry.export} = ${JSON.stringify(abi, null, 4)} as const;`,
        "",
    ].join("\n");
    writeFileSync(join(abisDir, `${entry.contract}.ts`), body);
    writeFileSync(join(jsonDir, `${entry.contract}.json`), `${JSON.stringify(abi, null, 2)}\n`);
    barrel.push(`export { ${entry.export} } from "./abis/${entry.contract}.js";`);
}

barrel.push("");
writeFileSync(join(srcDir, "index.ts"), barrel.join("\n"));

console.log(
    `generated ${CONTRACTS.length} ABIs (solc ${[...solcVersions].join(", ")}) ` +
        `into packages/abi/{src,json}`,
);
