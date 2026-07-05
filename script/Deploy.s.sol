// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../src/MASP.sol";
import { Groth16Verifier } from "../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";

import { BaseDeploy } from "./base/BaseDeploy.s.sol";

/// Mainnet (or any non-ephemeral chain) deploy. Deploys only the contracts
/// owned by this repo: `Groth16Verifier`, `TreeUpdateBatchGroth16Verifier`,
/// and `MASP`. All external dependencies — Permit2, the chain's wrapped
/// native coin (WETH/WBNB/etc.), and the registered ERC20 tokens — are
/// passed in via a JSON config (`MAINNET_CONFIG`, default
/// `script/config/mainnet.json`). Refuses to run if any required address
/// has no code at deploy time.
///
/// Config schema:
///   {
///     "permit2":        "0x...",   required, must have code
///     "wrappedNative":  "0x...",   optional, address(0) disables withdrawNative
///     "feeBps":   25,
///     "treasury": "0x...",
///     "owner":    "0x...",
///     "ids":      [1, 2, 3],
///     "tokens":   ["0x...", ...], parallel to ids, must have code
///     "scales":   ["1e10", "1", "1"]  parallel to ids
///   }
///
/// Scale guidance: `publicIn = baseUnits / scale` must fit `uint48` (~2.81e14).
/// 18-decimal tokens require `scale >= 1e10` (cap ≈ 2.8M tokens); 6/8-decimal
/// tokens fit with `scale = 1`. Notes commit value in circuit units, so scale
/// is immutable for the lifetime of any held note — set correctly at deploy.
contract Deploy is BaseDeploy {
    string constant DEFAULT_CONFIG = "script/config/mainnet.json";

    function run()
        external
        returns (
            address verifierAddr,
            address treeUpdateBatchVerifierAddr,
            address maspAddr,
            address permit2Addr,
            address[] memory tokenAddrs
        )
    {
        string memory path = vm.envOr("MAINNET_CONFIG", DEFAULT_CONFIG);
        string memory j = vm.readFile(path);

        MaspParams memory p;
        p.permit2 = vm.parseJsonAddress(j, ".permit2");
        p.wrappedNative = vm.parseJsonAddress(j, ".wrappedNative");
        p.feeBps = uint16(vm.parseJsonUint(j, ".feeBps"));
        p.treasury = vm.parseJsonAddress(j, ".treasury");
        p.owner = vm.parseJsonAddress(j, ".owner");

        uint256[] memory rawIds = vm.parseJsonUintArray(j, ".ids");
        address[] memory tokenList = vm.parseJsonAddressArray(j, ".tokens");
        p.scales = vm.parseJsonUintArray(j, ".scales");

        uint256 n = rawIds.length;
        require(tokenList.length == n, "config length mismatch");
        require(p.scales.length == n, "config length mismatch");

        _requireCode(p.permit2, "permit2 has no code");
        if (p.wrappedNative != address(0)) _requireCode(p.wrappedNative, "wrappedNative has no code");

        p.ids = new uint64[](n);
        p.tokens = new IERC20[](n);
        tokenAddrs = new address[](n);
        for (uint256 i; i < n; ++i) {
            _requireCode(tokenList[i], "token has no code");
            p.ids[i] = uint64(rawIds[i]);
            p.tokens[i] = IERC20(tokenList[i]);
            tokenAddrs[i] = tokenList[i];
        }

        vm.startBroadcast();
        (Groth16Verifier v, TreeUpdateBatchGroth16Verifier tub, MASP masp) = _deployMaspCore(p);
        vm.stopBroadcast();

        verifierAddr = address(v);
        treeUpdateBatchVerifierAddr = address(tub);
        maspAddr = address(masp);
        permit2Addr = p.permit2;

        _logCoreKv(verifierAddr, treeUpdateBatchVerifierAddr, maspAddr, permit2Addr, p.wrappedNative, p.ids, tokenAddrs);
    }
}
