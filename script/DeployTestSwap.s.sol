// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UniV3Adapter } from "../src/swap/UniV3Adapter.sol";
import { SwapWrapper } from "../src/swap/SwapWrapper.sol";
import { MockQuoterV2 } from "../test/swap/mocks/MockQuoterV2.sol";
import { MockSwapRouter02 } from "../test/swap/mocks/MockSwapRouter02.sol";

import { BaseSwapDeploy } from "./base/BaseSwapDeploy.s.sol";

/// Test/anvil swap stack: deploys `MockQuoterV2`, `MockSwapRouter02`,
/// `UniV3Adapter`, `SwapWrapper`, then seeds the linear-rate table across
/// the 4 UniV3 fee tiers. Run AFTER `DeployTest.s.sol` — reads its
/// KEY=value output via env vars.
///
/// Required env (populated from DeployTest output):
///   MASP                — MASP address
///   PERMIT2             — Permit2 address
///   TOKEN_1, TOKEN_2, TOKEN_3 — registered token addresses (fixture order
///                                0=WETH, 1=mDAI, 2=mWBTC)
///
/// Optional:
///   MASP_OWNER, MASP_TREASURY — wrapper owner / treasury (defaults match
///                                DeployTest)
///
/// Assumes the 3-asset fixture (test/fixtures/asset_registry.json). For
/// a different asset count update `_swapRate` accordingly.
contract DeployTestSwap is BaseSwapDeploy {
    function run() external returns (address quoter, address adapter, address mockRouter, address wrapper) {
        address masp = vm.envAddress("MASP");
        address permit2 = vm.envAddress("PERMIT2");
        address owner = vm.envOr("MASP_OWNER", tx.origin);
        address treasury = vm.envOr("MASP_TREASURY", 0x000000000000000000000000000000000000dEaD);

        address[] memory tokens = new address[](3);
        tokens[0] = vm.envAddress("TOKEN_1");
        tokens[1] = vm.envAddress("TOKEN_2");
        tokens[2] = vm.envAddress("TOKEN_3");
        require(tokens.length == 3, "fixture assumes 3 assets");

        _requireCode(masp, "MASP has no code");
        _requireCode(permit2, "Permit2 has no code");

        vm.startBroadcast();

        MockQuoterV2 q = new MockQuoterV2();
        MockSwapRouter02 r = new MockSwapRouter02();
        (UniV3Adapter a, SwapWrapper w) = _deploySwapStack(masp, permit2, address(r), owner, treasury);

        // Linear-rate seeding for every directed pair across all 4 UniV3
        // fee tiers. Output scales with amountIn so the demo UI shows
        // sensible numbers ("1 WETH → ~3000 mDAI"). Real DEX behaviour
        // (price impact, tier divergence) intentionally skipped.
        uint24[4] memory fees = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
        uint256 gasEstimate = 80_000;
        for (uint256 i; i < tokens.length; ++i) {
            w.prepareToken(IERC20(tokens[i]));
            for (uint256 j; j < tokens.length; ++j) {
                if (i == j) continue;
                uint256 rt = _swapRate(i, j);
                r.setRate(tokens[i], tokens[j], rt);
                for (uint256 k; k < fees.length; ++k) {
                    q.setRate(tokens[i], tokens[j], fees[k], rt, gasEstimate);
                }
            }
        }

        vm.stopBroadcast();

        quoter = address(q);
        adapter = address(a);
        mockRouter = address(r);
        wrapper = address(w);

        console2.log(string.concat("UNIV3_QUOTER=", vm.toString(quoter)));
        console2.log(string.concat("UNIV3_ADAPTER=", vm.toString(adapter)));
        console2.log(string.concat("MOCK_SWAP_ROUTER=", vm.toString(mockRouter)));
        console2.log(string.concat("SWAP_WRAPPER=", vm.toString(wrapper)));
    }

    /// Per-pair linear rate `amountOut(1e18 amountIn) = ratePer1e18`.
    /// Indexes match the asset_registry fixture: 0=WETH(18), 1=mDAI(18),
    /// 2=mWBTC(8). Logical prices: 1 ETH = 3000 DAI; 1 ETH = 0.05 BTC;
    /// 1 BTC = 60000 DAI. Rates account for the WETH/mDAI vs mWBTC
    /// decimals delta (10×) so a natural-language input ("1.0 WETH")
    /// yields the headline output.
    function _swapRate(uint256 fromIdx, uint256 toIdx) private pure returns (uint256) {
        if (fromIdx == 0 && toIdx == 1) return 3_000e18; // WETH → mDAI
        if (fromIdx == 1 && toIdx == 0) return 333_333_333_333_333; // mDAI → WETH
        if (fromIdx == 0 && toIdx == 2) return 5_000_000; // WETH → mWBTC (0.05 BTC, 8 decimals)
        if (fromIdx == 2 && toIdx == 0) return 2e29; // mWBTC → WETH (decimals delta 8→18)
        if (fromIdx == 1 && toIdx == 2) return 1_666; // mDAI → mWBTC
        if (fromIdx == 2 && toIdx == 1) return 6e32; // mWBTC → mDAI
        return 0;
    }
}
