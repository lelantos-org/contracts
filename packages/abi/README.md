# @lelantos-org/contracts

Canonical ABIs for the Lelantos MASP contracts, generated from the Foundry
build (`out/`) at release time. No bytecode, no addresses — ABIs only.

## Install

The package lives on GitHub Packages. `.npmrc` in the consuming repo:

```
@lelantos-org:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}
```

```
npm install @lelantos-org/contracts
```

## Use

Every ABI is exported `as const`, so viem/wagmi infer argument and return
types from it:

```ts
import { maspAbi } from "@lelantos-org/contracts";

const fee = await client.readContract({
    address: masp,
    abi: maspAbi,
    functionName: "feeBps",
}); // number
```

Non-TypeScript consumers can read the plain arrays instead:

```js
import maspAbi from "@lelantos-org/contracts/json/MASP.json" with { type: "json" };
```

## Exports

| Export | Source |
| --- | --- |
| `maspAbi` | `src/MASP.sol:MASP` |
| `assetRegistryAbi` | `src/AssetRegistry.sol:AssetRegistry` |
| `commitmentTreeAbi` | `src/CommitmentTree.sol:CommitmentTree` |
| `feeConfigAbi` | `src/FeeConfig.sol:FeeConfig` |
| `nullifierSetAbi` | `src/NullifierSet.sol:NullifierSet` |
| `swapWrapperAbi` | `src/swap/SwapWrapper.sol:SwapWrapper` |
| `uniV3AdapterAbi` | `src/swap/UniV3Adapter.sol:UniV3Adapter` |
| `imaspSwapAbi` | `src/swap/IMASPSwap.sol:IMASPSwap` |
| `swapAdapterAbi` | `src/swap/ISwapAdapter.sol:ISwapAdapter` |
| `verifierInterfaceAbi` | `src/interfaces/IVerifier.sol:IVerifier` |
| `wrappedNativeAbi` | `src/interfaces/IWrappedNative.sol:IWrappedNative` |
| `groth16VerifierAbi` | `src/verifiers/Verifier.sol:Groth16Verifier` |
| `treeUpdateBatchVerifierAbi` | `src/verifiers/TreeUpdateBatchVerifier.sol:TreeUpdateBatchGroth16Verifier` |

To add a contract, extend `CONTRACTS` in
[`scripts/generate.mjs`](scripts/generate.mjs).

## Release

`src/`, `json/`, and `dist/` are generated and git-ignored. Build locally
with `just abi` from the repo root (runs `forge build`, then the generator
and `tsc`).

Publishing is tag-driven: bump `version` in this `package.json`, then push a
tag `abi-v<version>` (e.g. `abi-v0.1.0`). `.github/workflows/publish-abi.yml`
rebuilds the contracts from source and publishes to GitHub Packages; it fails
if the tag and `package.json` versions disagree.
