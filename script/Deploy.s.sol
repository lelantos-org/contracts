// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ExitTerms } from "../src/libs/ExitTerms.sol";
import { BaseDeploy } from "./base/BaseDeploy.s.sol";

/// Mainnet (or any non-ephemeral chain) deploy. Deploys only the contracts
/// owned by this repo: `TreeUpdateBatchGroth16Verifier`,
/// `BatchedGroth16Verifier`, `MASP`, and, when `wrappedNative` is configured,
/// `NativeAdapter`. External dependencies (Permit2, the chain's wrapped native
/// coin, and the registered ERC-20 tokens) come from a JSON config
/// (`MAINNET_CONFIG`, default `script/config/mainnet.json`). Reverts if any
/// required address has no code at deploy time.
///
/// Config schema:
///   {
///     "permit2":        "0x...",   required, must have code
///     "wrappedNative":  "0x...",   optional, address(0) skips the NativeAdapter deploy
///     "depositBps":  [0, 0, 0],       parallel to ids
///     "withdrawBps": [20, 20, 20],    parallel to ids
///     "treasury": "0x...",
///     "owner":       "0x...",   pool owner (the governance Timelock in production)
///     "proxyAdmin":  "0x...",   may queue/cancel/activate upgrades and pause
///     "upgradeDelay": 2592000,  30d exit window; immutable once deployed; at
///                               most `ExitTerms.DELAY` (30d)
///     "maxPause":     604800,   7d ceiling on a single guardian pause
///     "ids":      [1, 2, 3],
///     "tokens":   ["0x...", ...], parallel to ids, must have code
///     "scales":   ["1e10", "1", "1"]  parallel to ids
///   }
///
/// Fee guidance: rates are per asset and per leg, with no pool-wide fallback;
/// a zero in these arrays is a zero rate, not "unset". Both are capped at
/// `MAX_FEE_BPS` (2000 = 20%) and set at registration; only
/// `setAssetFee(id, depositBps, withdrawBps)` changes them afterwards. The two
/// legs are not protected equally: a deposit rate is snapshotted into the
/// escrow digest at submit, while a withdraw rate is read at execution and is
/// not bound by anything the spender signed, so a withdraw raise is queued for
/// `ExitTerms.DELAY` before `commitExitTerms` can apply it.
///
/// Scale guidance: `publicIn = baseUnits / scale` must fit `uint48` (~2.81e14).
/// 18-decimal tokens require `scale >= 1e10` (cap ~2.8M tokens); 6- and
/// 8-decimal tokens fit with `scale = 1`. Notes commit value in circuit units,
/// so an asset's scale is fixed for the lifetime of every note held in it.
contract Deploy is BaseDeploy {
    string constant DEFAULT_CONFIG = "script/config/mainnet.json";

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
        string memory path = vm.envOr("MAINNET_CONFIG", DEFAULT_CONFIG);
        string memory j = vm.readFile(path);

        MaspParams memory p;
        p.permit2 = vm.parseJsonAddress(j, ".permit2");
        p.wrappedNative = vm.parseJsonAddress(j, ".wrappedNative");
        p.treasury = vm.parseJsonAddress(j, ".treasury");
        p.owner = vm.parseJsonAddress(j, ".owner");
        p.proxyAdmin = vm.parseJsonAddress(j, ".proxyAdmin");
        p.upgradeDelay = vm.parseJsonUint(j, ".upgradeDelay");
        p.maxPause = vm.parseJsonUint(j, ".maxPause");
        // The exit window is immutable once deployed; a zero or very short
        // value makes upgrades effectively immediate.
        require(p.upgradeDelay >= 7 days, "upgradeDelay too short");
        // Both mirror the proxy constructor, failing the script before broadcast.
        // Together they also bound `maxPause` below `ExitTerms.DELAY`.
        require(p.upgradeDelay <= ExitTerms.DELAY, "upgradeDelay exceeds the exit-term notice");
        require(p.maxPause > 0, "maxPause unset");
        require(p.maxPause < p.upgradeDelay, "maxPause must be shorter than upgradeDelay");
        require(p.proxyAdmin != address(0), "proxyAdmin unset");

        uint256[] memory rawIds = vm.parseJsonUintArray(j, ".ids");
        address[] memory tokenList = vm.parseJsonAddressArray(j, ".tokens");
        p.scales = vm.parseJsonUintArray(j, ".scales");

        uint256 n = rawIds.length;
        require(tokenList.length == n, "config length mismatch");
        require(p.scales.length == n, "config length mismatch");

        // Parsed as uint256 (the cheatcode has no uint16 array form) and
        // narrowed here after a range check; a value above the fee ceiling
        // reverts in `_addAsset`.
        uint256[] memory rawDeposit = vm.parseJsonUintArray(j, ".depositBps");
        uint256[] memory rawWithdraw = vm.parseJsonUintArray(j, ".withdrawBps");
        require(rawDeposit.length == n, "config length mismatch");
        require(rawWithdraw.length == n, "config length mismatch");
        p.depositBps = new uint16[](n);
        p.withdrawBps = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            require(rawDeposit[i] <= type(uint16).max, "depositBps overflow");
            require(rawWithdraw[i] <= type(uint16).max, "withdrawBps overflow");
            p.depositBps[i] = uint16(rawDeposit[i]);
            p.withdrawBps[i] = uint16(rawWithdraw[i]);
        }

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
}
