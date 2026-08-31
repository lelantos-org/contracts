// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { UniV4Adapter } from "../../../src/swap/UniV4Adapter.sol";

/// Deployed V4Quoter lens. Reverts internally and catches, so it must be
/// called as `eth_call` — which is what a non-state-changing forge test does.
interface IV4Quoter {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// Fork test against the **real** Base UniversalRouter.
///
/// This is the only check that the adapter's hand-transcribed command, action
/// and `ExactInputSingleParams` encoding actually matches what the deployed
/// router decodes. `test/swap/UniV4Adapter.t.sol` runs against a mock that
/// asserts the same layout this adapter writes, so the two would agree even if
/// both were wrong; only a real router can settle it.
///
/// Skipped unless `FORK_TESTS=1` and `BASE_RPC_URL` are set.
contract UniV4AdapterForkTest is Test {
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant V4_QUOTER = 0x0d5e0F971ED27FBfF6c2837bf31316121532048D;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint24 constant FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint256 constant AMOUNT_IN = 1 ether;

    UniV4Adapter internal adapter;

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.rpcUrl("base"));
        adapter = new UniV4Adapter(UNIVERSAL_ROUTER, address(this));
    }

    /// The UniversalRouter is a shared public contract, so anyone can send it
    /// tokens. If the adapter settled the router's whole balance rather than
    /// exactly what it transferred, a 1 wei donation would over-settle the
    /// PoolManager debt and leave an unclaimed credit, reverting every swap for
    /// that token.
    function testForkSwapSurvivesRouterDonation() public {
        deal(WETH, UNIVERSAL_ROUTER, IERC20(WETH).balanceOf(UNIVERSAL_ROUTER) + 1 wei);
        _swapOneWeth();
    }

    /// Quote through the real lens, swap through the real router, and require
    /// the executed output to land within 1% of the quote.
    function testForkSwapMatchesQuote() public {
        _swapOneWeth();
    }

    function _swapOneWeth() internal {
        bool zeroForOne = WETH < USDC;
        (address lo, address hi) = zeroForOne ? (WETH, USDC) : (USDC, WETH);

        (uint256 quoted,) = IV4Quoter(V4_QUOTER)
            .quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: IV4Quoter.PoolKey({
                        currency0: lo, currency1: hi, fee: FEE, tickSpacing: TICK_SPACING, hooks: address(0)
                    }),
                    zeroForOne: zeroForOne,
                    exactAmount: uint128(AMOUNT_IN),
                    hookData: ""
                })
            );
        assertGt(quoted, 0, "quoter returned nothing - pool may have moved");

        deal(WETH, address(adapter), AMOUNT_IN);

        // Measured as a delta, not an absolute balance: a fork carries whatever
        // state these addresses already had at that block.
        uint256 selfBefore = IERC20(USDC).balanceOf(address(this));

        uint256 minOut = (quoted * 99) / 100;
        uint256 actualOut =
            adapter.swap(WETH, USDC, AMOUNT_IN, minOut, block.timestamp + 1, abi.encode(FEE, TICK_SPACING));

        assertGe(actualOut, minOut, "executed below quote-derived floor");
        assertEq(IERC20(USDC).balanceOf(address(this)) - selfBefore, actualOut, "output pushed to caller");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "adapter keeps no dust");
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0, "input fully consumed");
    }
}
