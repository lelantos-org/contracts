// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/Script.sol";

import { UniV3Adapter } from "../src/swap/UniV3Adapter.sol";
import { UniV4Adapter } from "../src/swap/UniV4Adapter.sol";
import { SwapWrapper } from "../src/swap/SwapWrapper.sol";
import { MockQuoterV2 } from "../test/swap/mocks/MockQuoterV2.sol";
import { MockSwapRouter02 } from "../test/swap/mocks/MockSwapRouter02.sol";
import { MockUniversalRouter } from "../test/swap/mocks/MockUniversalRouter.sol";
import { MockV4Quoter } from "../test/swap/mocks/MockV4Quoter.sol";

import { BaseSwapDeploy } from "./base/BaseSwapDeploy.s.sol";

/// The rate-seeding surface shared by both venues' mock quoters
/// (`MockQuoterV2`, `MockV4Quoter`) and mock routers (`MockSwapRouter02`,
/// `MockUniversalRouter`), so one seeding loop covers both.
interface ISeedableQuoter {
    function setRate(address tokenIn, address tokenOut, uint24 fee, uint256 ratePer1e18, uint256 gasEstimate) external;
}

interface ISeedableRouter {
    function setRate(address tokenIn, address tokenOut, uint256 ratePer1e18) external;
}

/// Test/anvil swap stack: deploys the UniV3 mocks (`MockQuoterV2`,
/// `MockSwapRouter02`) and the UniV4 mocks (`MockV4Quoter`,
/// `MockUniversalRouter`), both adapters and `SwapWrapper`, then seeds the
/// linear-rate tables across the four canonical fee tiers. Run after
/// `DeployTest.s.sol`, whose KEY=value output supplies the env vars below.
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
    uint256 private constant GAS_ESTIMATE = 80_000;

    /// Grouped rather than returned as a tuple to keep `run` clear of the
    /// stack-depth limit, which two venues' worth of addresses would exceed.
    struct Deployed {
        address univ3Quoter;
        address univ3Adapter;
        address mockSwapRouter;
        address univ4Quoter;
        address univ4Adapter;
        address mockUniversalRouter;
        address wrapper;
    }

    function run() external returns (Deployed memory d) {
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
        MockV4Quoter q4 = new MockV4Quoter();
        MockUniversalRouter r4 = new MockUniversalRouter();
        (UniV3Adapter a, UniV4Adapter a4, SwapWrapper w) =
            _deploySwapStack(masp, permit2, address(r), address(r4), owner, treasury);

        // Output scales linearly with `amountIn`, so the demo UI shows
        // plausible numbers; price impact and per-tier divergence are not
        // modelled. Both venues get the same rate, so the metaquoter race is a
        // genuine tie and either venue may win it.
        _seedVenue(ISeedableQuoter(address(q)), ISeedableRouter(address(r)), tokens);
        _seedVenue(ISeedableQuoter(address(q4)), ISeedableRouter(address(r4)), tokens);
        _prepareTokens(w, tokens);

        vm.stopBroadcast();

        d = Deployed({
            univ3Quoter: address(q),
            univ3Adapter: address(a),
            mockSwapRouter: address(r),
            univ4Quoter: address(q4),
            univ4Adapter: address(a4),
            mockUniversalRouter: address(r4),
            wrapper: address(w)
        });

        console2.log(string.concat("UNIV3_QUOTER=", vm.toString(d.univ3Quoter)));
        console2.log(string.concat("UNIV3_ADAPTER=", vm.toString(d.univ3Adapter)));
        console2.log(string.concat("MOCK_SWAP_ROUTER=", vm.toString(d.mockSwapRouter)));
        console2.log(string.concat("UNIV4_QUOTER=", vm.toString(d.univ4Quoter)));
        console2.log(string.concat("UNIV4_ADAPTER=", vm.toString(d.univ4Adapter)));
        console2.log(string.concat("MOCK_UNIVERSAL_ROUTER=", vm.toString(d.mockUniversalRouter)));
        console2.log(string.concat("SWAP_WRAPPER=", vm.toString(d.wrapper)));
    }

    /// Seeds one venue's rate tables for every directed pair across the four
    /// canonical fee tiers.
    ///
    /// Both venues' mocks expose the same two `setRate` shapes, so one
    /// implementation serves both — called once per venue rather than holding
    /// all four mock handles live at once, which exceeds the stack limit.
    function _seedVenue(ISeedableQuoter quoter, ISeedableRouter router, address[] memory tokens) private {
        uint24[4] memory fees = [uint24(100), uint24(500), uint24(3000), uint24(10000)];
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < tokens.length; ++j) {
                if (i == j) continue;
                uint256 rt = _swapRate(i, j);
                router.setRate(tokens[i], tokens[j], rt);
                for (uint256 k; k < fees.length; ++k) {
                    quoter.setRate(tokens[i], tokens[j], fees[k], rt, GAS_ESTIMATE);
                }
            }
        }
    }

    /// Per-pair linear rate `amountOut(1e18 amountIn) = ratePer1e18`. Indices
    /// match the asset_registry fixture: 0 = WETH (18), 1 = mDAI (18),
    /// 2 = mWBTC (8). Modelled prices: 1 ETH = 3000 DAI, 1 ETH = 0.05 BTC,
    /// 1 BTC = 60000 DAI, adjusted for the decimals delta between mWBTC and the
    /// 18-decimal tokens.
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
