// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { UniV4Adapter } from "../../src/swap/UniV4Adapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockUniversalRouter } from "./mocks/MockUniversalRouter.sol";

contract UniV4AdapterTest is Test {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockUniversalRouter internal router;
    UniV4Adapter internal adapter;

    address internal caller = address(this);

    /// Route layout: `abi.encode(uint24 fee, int24 tickSpacing)`.
    bytes internal route = abi.encode(uint24(500), int24(10));

    function setUp() public {
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        router = new MockUniversalRouter();
        adapter = new UniV4Adapter(address(router), caller);
    }

    function _fund(address tokenIn, uint256 amountIn, uint256 routerOut) internal {
        MockERC20(tokenIn).mint(address(adapter), amountIn);
        router.setNextOut(routerOut);
    }

    /// `tokenIn < tokenOut`, so the swap runs zeroForOne.
    function testSwapZeroForOne() public {
        (address lo, address hi) = _sorted();
        _fund(lo, 1_000e18, 990e18);
        uint256 actualOut = adapter.swap(lo, hi, 1_000e18, 990e18, block.timestamp + 1, route);
        assertEq(actualOut, 990e18);
        assertEq(MockERC20(hi).balanceOf(caller), 990e18, "caller got tokenOut");
        assertEq(MockERC20(hi).balanceOf(address(adapter)), 0, "adapter keeps no dust");
    }

    /// The reverse direction must produce the same sorted `PoolKey` with
    /// `zeroForOne = false`. The mock asserts the ordering, so a bug here
    /// surfaces as a decode failure rather than a silent mispricing.
    function testSwapOneForZero() public {
        (address lo, address hi) = _sorted();
        _fund(hi, 1_000e18, 980e18);
        uint256 actualOut = adapter.swap(hi, lo, 1_000e18, 980e18, block.timestamp + 1, route);
        assertEq(actualOut, 980e18);
        assertEq(MockERC20(lo).balanceOf(caller), 980e18);
    }

    function testRevertsOnInsufficientOut() public {
        (address lo, address hi) = _sorted();
        _fund(lo, 1_000e18, 800e18);
        vm.expectRevert(bytes("MockUniversalRouter: too little received"));
        adapter.swap(lo, hi, 1_000e18, 990e18, block.timestamp + 1, route);
    }

    /// `deadline` is genuinely forwarded here, unlike `UniV3Adapter` where
    /// SwapRouter02 takes none.
    function testRevertsOnExpiredDeadline() public {
        (address lo, address hi) = _sorted();
        _fund(lo, 1_000e18, 990e18);
        vm.warp(1000);
        vm.expectRevert(bytes("MockUniversalRouter: expired"));
        adapter.swap(lo, hi, 1_000e18, 990e18, 999, route);
    }

    /// Both amounts are narrowed to `uint128` by the router's calldata layout,
    /// so each is bounds-checked at its cast and reports the offending value.
    function testRevertsOnAmountInAboveUint128() public {
        (address lo, address hi) = _sorted();
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(UniV4Adapter.AmountTooLarge.selector, tooBig));
        adapter.swap(lo, hi, tooBig, 1, block.timestamp + 1, route);
    }

    function testRevertsOnMinOutAboveUint128() public {
        (address lo, address hi) = _sorted();
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(UniV4Adapter.AmountTooLarge.selector, tooBig));
        adapter.swap(lo, hi, 1_000e18, tooBig, block.timestamp + 1, route);
    }

    function testConstructorRejectsZeroRouter() public {
        vm.expectRevert(UniV4Adapter.RouterZero.selector);
        new UniV4Adapter(address(0), address(uint160(1)));
    }

    function testConstructorRejectsZeroWrapper() public {
        vm.expectRevert(UniV4Adapter.WrapperZero.selector);
        new UniV4Adapter(address(router), address(0));
    }

    /// `swap` is pinned to the wrapper. Without that, any caller could route
    /// tokens donated to the adapter to themselves.
    function testRevertsOnUnauthorizedCaller() public {
        (address lo, address hi) = _sorted();
        _fund(lo, 1_000e18, 990e18);
        vm.prank(address(0xBAD));
        vm.expectRevert(UniV4Adapter.UnauthorizedCaller.selector);
        adapter.swap(lo, hi, 1_000e18, 990e18, block.timestamp + 1, route);
    }

    function _sorted() internal view returns (address lo, address hi) {
        (lo, hi) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
    }
}
