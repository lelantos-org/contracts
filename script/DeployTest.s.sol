// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../src/MASP.sol";
import { Groth16Verifier } from "../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";
import { MockERC20 } from "../test/mocks/MockERC20.sol";
import { MockWETH9 } from "../test/mocks/MockWETH9.sol";

import { NativeAdapter } from "../src/native/NativeAdapter.sol";

import { BaseDeploy } from "./base/BaseDeploy.s.sol";

/// Test/anvil deploy: spins up the local MASP stack — Groth16Verifier,
/// TreeUpdateBatchGroth16Verifier, Permit2 (canonical or freshly deployed),
/// MockWETH9, MockERC20s, MASP, and NativeAdapter. For mainnet (or any chain
/// where the dependencies already exist) use `Deploy.s.sol` instead.
///
/// Swap stack (UniV3Adapter + SwapWrapper + mock router/quoter) is deployed
/// separately by `DeployTestSwap.s.sol` — run it after this script.
///
/// Deploys Groth16Verifier + MASP with N tokens registered at ids 1..N.
/// Asset generators are read from test/fixtures/asset_registry.json (produced
/// by `circuits/just gen-asset-registry`). Any registry slot whose `symbols`
/// entry matches the chain's wrapped-native symbol (env `WRAPPED_NATIVE_SYMBOL`,
/// default `WETH`) is deployed as `MockWETH9` (so the token has the real
/// `deposit() payable` / `withdraw(uint256)` ABI) and is also handed to the
/// `NativeAdapter`, which is what bridges native coin in and out of the
/// ERC-20-only pool. All other slots are plain `MockERC20`. Chain-agnostic — invoke with any `--rpc-url` (see
/// justfile `deploy-anvil`).
contract DeployTest is BaseDeploy {
    string constant REGISTRY_FIXTURE = "test/fixtures/asset_registry.json";

    function run()
        external
        returns (
            address verifierAddr,
            address treeUpdateBatchVerifierAddr,
            address maspAddr,
            address permit2Addr,
            address nativeAdapterAddr,
            address[] memory tokenAddrs
        )
    {
        string memory j = vm.readFile(REGISTRY_FIXTURE);

        uint256[] memory rawIds = vm.parseJsonUintArray(j, ".ids");
        uint256[] memory scales = vm.parseJsonUintArray(j, ".scales");
        string[] memory names = vm.parseJsonStringArray(j, ".names");
        string[] memory symbols = vm.parseJsonStringArray(j, ".symbols");
        uint256[] memory decs = vm.parseJsonUintArray(j, ".decimals");

        uint256 n = rawIds.length;
        require(scales.length == n, "registry length mismatch");
        require(names.length == n && symbols.length == n, "registry length mismatch");
        require(decs.length == n, "registry length mismatch");

        MaspParams memory p;
        p.scales = scales;
        p.ids = new uint64[](n);
        p.tokens = new IERC20[](n);
        tokenAddrs = new address[](n);

        vm.startBroadcast();

        // Permit2: prefer canonical address (deployed via deterministic
        // CREATE2 on most chains). Allow override via PERMIT2 env var. If
        // neither has code (local anvil, custom chain), deploy a fresh one.
        // Real-deploy Permit2 (constructor runs → DOMAIN_SEPARATOR cached
        // for actual deploy address + chainid). The etch-based helper in
        // lib/permit2/test/utils/DeployPermit2.sol skips the constructor
        // and bakes a DS bound to whatever address produced the captured
        // runtime bytecode → InvalidSigner on EIP-712 verify.
        // Permit2 is solc 0.8.17, MASP is ^0.8.30 — fetch precompiled
        // bytecode and deploy via assembly create to avoid version clash.
        permit2Addr = vm.envOr("PERMIT2", address(0));
        if (permit2Addr == address(0) || permit2Addr.code.length == 0) {
            bytes memory permit2Code = vm.getCode("Permit2.sol:Permit2");
            address deployed;
            // forge-lint: disable-next-line(asm-keccak256)
            assembly {
                deployed := create(0, add(permit2Code, 0x20), mload(permit2Code))
            }
            require(deployed != address(0), "Permit2 deploy failed");
            permit2Addr = deployed;
        }
        p.permit2 = permit2Addr;

        for (uint256 i; i < n; ++i) {
            p.ids[i] = uint64(rawIds[i]);
            address tokenAddr;
            if (_isWrappedNative(symbols[i])) {
                MockWETH9 w = new MockWETH9();
                tokenAddr = address(w);
                p.wrappedNative = tokenAddr;
            } else {
                tokenAddr = address(new MockERC20(names[i], symbols[i], uint8(decs[i])));
            }
            p.tokens[i] = IERC20(tokenAddr);
            tokenAddrs[i] = tokenAddr;
        }

        // Fee parameters. Defaults: 25 bps (0.25%) per leg, treasury =
        // MASP_TREASURY env var, owner = MASP_OWNER env var (or tx.origin
        // under broadcast).
        p.feeBps = uint16(vm.envOr("MASP_FEE_BPS", uint256(25)));
        p.treasury = vm.envOr("MASP_TREASURY", 0x000000000000000000000000000000000000dEaD);
        p.owner = vm.envOr("MASP_OWNER", tx.origin);

        (Groth16Verifier v, TreeUpdateBatchGroth16Verifier tub, MASP masp, NativeAdapter na) = _deployMaspCore(p);

        vm.stopBroadcast();

        verifierAddr = address(v);
        treeUpdateBatchVerifierAddr = address(tub);
        maspAddr = address(masp);
        // address(0) when the fixture registry names no wrapped-native symbol.
        nativeAdapterAddr = address(na);

        _logCoreKv(
            verifierAddr,
            treeUpdateBatchVerifierAddr,
            maspAddr,
            permit2Addr,
            p.wrappedNative,
            nativeAdapterAddr,
            p.ids,
            tokenAddrs
        );
    }

    /// Strict equality on registry-supplied symbol — contract pairs the
    /// wrapped-native token to its `IWrappedNative.deposit/withdraw` ABI by
    /// address only, so the label here is purely human-facing. Reads symbol
    /// from env `WRAPPED_NATIVE_SYMBOL` (default `WETH` for Ethereum-like
    /// chains; set to `WBNB` for BSC, etc.).
    function _isWrappedNative(string memory symbol) private view returns (bool) {
        string memory target = vm.envOr("WRAPPED_NATIVE_SYMBOL", string("WETH"));
        return keccak256(bytes(symbol)) == keccak256(bytes(target));
    }
}
