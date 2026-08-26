// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockERC20 } from "../test/mocks/MockERC20.sol";
import { MockWETH9 } from "../test/mocks/MockWETH9.sol";

import { BaseDeploy } from "./base/BaseDeploy.s.sol";

/// Test/anvil deploy of the local MASP stack: the two verifiers, Permit2
/// (canonical or freshly deployed), MockWETH9, MockERC20s, MASP and
/// NativeAdapter. Use `Deploy.s.sol` on a chain where the dependencies already
/// exist. The swap stack is deployed separately, by `DeployTestSwap.s.sol`,
/// which must run after this script.
///
/// Tokens are registered at ids 1..N from `test/fixtures/asset_registry.json`
/// (produced by `circuits/just gen-asset-registry`). A registry slot whose
/// `symbols` entry matches the chain's wrapped-native symbol (env
/// `WRAPPED_NATIVE_SYMBOL`, default `WETH`) is deployed as `MockWETH9`, giving
/// it the real `deposit() payable` / `withdraw(uint256)` ABI, and is handed to
/// the `NativeAdapter` that bridges native coin in and out of the ERC-20-only
/// pool. Every other slot is a plain `MockERC20`. Chain-agnostic: invoke with
/// any `--rpc-url` (see justfile `deploy-anvil`).
contract DeployTest is BaseDeploy {
    string constant REGISTRY_FIXTURE = "test/fixtures/asset_registry.json";

    function run()
        external
        returns (
            address treeUpdateBatchVerifierAddr,
            address spendVerifierAddr,
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

        // Permit2: prefer the canonical CREATE2 address, overridable via the
        // PERMIT2 env var; deploy a fresh instance when neither has code, as on
        // a local anvil. The deploy runs the constructor, so DOMAIN_SEPARATOR is
        // cached for the real address and chain id; the etch-based helper in
        // lib/permit2/test/utils/DeployPermit2.sol skips it and bakes a
        // separator bound to whatever address produced the captured runtime
        // bytecode, which fails EIP-712 verification with InvalidSigner.
        // Permit2 pins solc 0.8.17 and MASP 0.8.30, so the bytecode is fetched
        // precompiled and deployed with `create`.
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

        MaspCore memory core = _deployMaspCore(p);

        vm.stopBroadcast();

        treeUpdateBatchVerifierAddr = address(core.tubVerifier);
        spendVerifierAddr = address(core.spendVerifier);
        maspAddr = address(core.masp);
        permit2Addr = p.permit2;
        // address(0) when the chain has no wrapped-native token configured.
        nativeAdapterAddr = address(core.nativeAdapter);

        _logCoreKv(core, p, tokenAddrs);
    }

    /// Strict equality against the registry-supplied symbol. The contracts pair
    /// the wrapped-native token to its `IWrappedNative` ABI by address, so this
    /// label only selects which fixture slot gets a `MockWETH9`. The target
    /// symbol comes from env `WRAPPED_NATIVE_SYMBOL` (default `WETH`; set
    /// `WBNB` on BSC).
    function _isWrappedNative(string memory symbol) private view returns (bool) {
        string memory target = vm.envOr("WRAPPED_NATIVE_SYMBOL", string("WETH"));
        return keccak256(bytes(symbol)) == keccak256(bytes(target));
    }
}
