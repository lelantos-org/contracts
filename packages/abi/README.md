# @lelantos-org/contracts

ABIs for the Lelantos MASP contracts, generated from the Foundry build (`out/`) at release time. The package contains ABIs only: no bytecode and no addresses.

## Install

The package is published to GitHub Packages. Add to `.npmrc` in the consuming repository:

```
@lelantos-org:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}
```

```
npm install @lelantos-org/contracts
```

## Usage

Every ABI is exported `as const`, so viem and wagmi infer argument and return types:

```ts
import { maspAbi } from "@lelantos-org/contracts";

const [depositBps, withdrawBps] = await client.readContract({
    address: masp,
    abi: maspAbi,
    functionName: "assetFees",
    args: [assetId],
}); // readonly [number, number]
```

The package is ESM and marked `sideEffects: false`. Each contract is also available as a subpath named after the Solidity contract, exporting the same symbol as the barrel:

```ts
import { maspAbi } from "@lelantos-org/contracts/MASP";
```

Plain JSON arrays are available under `json/`:

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
| `delayedUpgradeProxyAbi` | `src/DelayedUpgradeProxy.sol:DelayedUpgradeProxy` |
| `ownableInitAbi` | `src/OwnableInit.sol:OwnableInit` |
| `lelantosTokenAbi` | `src/governance/LelantosToken.sol:LelantosToken` |
| `lelantosGovernorAbi` | `src/governance/LelantosGovernor.sol:LelantosGovernor` |
| `feeBurnerAbi` | `src/burn/FeeBurner.sol:FeeBurner` |
| `yieldIndexAbi` | `src/yield/YieldIndex.sol:YieldIndex` |
| `yieldOpsAbi` | `src/yield/YieldOps.sol:YieldOps` |
| `yieldVenueAbi` | `src/yield/IYieldVenue.sol:IYieldVenue` |
| `erc4626VenueAbi` | `src/yield/ERC4626Venue.sol:ERC4626Venue` |
| `maspEscrowSatelliteAbi` | `src/MaspEscrowSatellite.sol:MaspEscrowSatellite` |
| `nativeAdapterAbi` | `src/native/NativeAdapter.sol:NativeAdapter` |
| `swapWrapperAbi` | `src/swap/SwapWrapper.sol:SwapWrapper` |
| `genericCallWrapperAbi` | `src/generic/GenericCallWrapper.sol:GenericCallWrapper` |
| `callExecutorAbi` | `src/generic/CallExecutor.sol:CallExecutor` |
| `uniV3AdapterAbi` | `src/swap/UniV3Adapter.sol:UniV3Adapter` |
| `uniV4AdapterAbi` | `src/swap/UniV4Adapter.sol:UniV4Adapter` |
| `swapAdapterAbi` | `src/swap/ISwapAdapter.sol:ISwapAdapter` |
| `imaspPoolAbi` | `src/interfaces/IMASPPool.sol:IMASPPool` |
| `verifierInterfaceAbi` | `src/interfaces/IVerifier.sol:IVerifier` |
| `batchVerifierInterfaceAbi` | `src/interfaces/IBatchVerifier.sol:IBatchVerifier` |
| `wrappedNativeAbi` | `src/interfaces/IWrappedNative.sol:IWrappedNative` |
| `groth16VerifierAbi` | `src/verifiers/Verifier.sol:Groth16Verifier` |
| `treeUpdateBatchVerifierAbi` | `src/verifiers/TreeUpdateBatchVerifier.sol:TreeUpdateBatchGroth16Verifier` |
| `batchedGroth16VerifierAbi` | `src/verifiers/BatchedGroth16Verifier.sol:BatchedGroth16Verifier` |

To add a contract, extend `CONTRACTS` in [`scripts/generate.mjs`](scripts/generate.mjs). The generator fails if a `src/` contract with a non-empty ABI is neither in `CONTRACTS` nor in `EXCLUDED`; `EXCLUDED` records the reason for each omission. `TimelockController` is unmodified OpenZeppelin and is not published here.

## Release

`src/`, `json/` and `dist/` are generated and git-ignored. Build locally with `just abi` from the repository root (`forge build`, the generator, then `tsc`).

Publishing is tag-driven:

1. Bump `version` in `package.json`.
2. Push a tag `abi-v<version>` (for example `abi-v0.1.0`).

`.github/workflows/publish-abi.yml` rebuilds the contracts from source and publishes to GitHub Packages. It fails if the tag and `package.json` versions differ.
