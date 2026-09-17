// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { UniV3Adapter } from "../../src/swap/UniV3Adapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockSwapRouter02 } from "./mocks/MockSwapRouter02.sol";

contract UniV3AdapterTest is Test {
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    MockSwapRouter02 internal router;
    UniV3Adapter internal adapter;

    address internal caller = address(this);

    function setUp() public {
        tokenIn = new MockERC20("In", "IN", 18);
        tokenOut = new MockERC20("Out", "OUT", 18);
        router = new MockSwapRouter02();
        adapter = new UniV3Adapter(address(router), caller);
    }

    function _fund(uint256 amountIn, uint256 routerOut) internal {
        tokenIn.mint(address(adapter), amountIn);
        tokenOut.mint(address(router), routerOut);
        router.setNextOut(routerOut);
    }

    function test_singleHopRoute() public {
        _fund(1_000e18, 990e18);
        bytes memory route = abi.encode(uint24(500), uint160(0));
        uint256 actualOut =
            adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 990e18, type(uint256).max, route);
        assertEq(actualOut, 990e18);
        assertEq(tokenOut.balanceOf(caller), 990e18, "caller got tokenOut");
        assertEq(tokenIn.allowance(address(adapter), address(router)), 0, "approval reset");
    }

    function test_multiHopRoute() public {
        _fund(1_000e18, 980e18);
        // path: tokenIn | fee0 | mid | fee1 | tokenOut
        bytes memory route =
            abi.encodePacked(address(tokenIn), uint24(500), address(0xBADBABE), uint24(3000), address(tokenOut));
        uint256 actualOut =
            adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 980e18, type(uint256).max, route);
        assertEq(actualOut, 980e18);
        assertEq(tokenOut.balanceOf(caller), 980e18);
        assertEq(tokenIn.allowance(address(adapter), address(router)), 0);
    }

    function test_revert_insufficientOut() public {
        _fund(1_000e18, 800e18); // router returns 800
        bytes memory route = abi.encode(uint24(500), uint160(0));
        vm.expectRevert(bytes("MockSwapRouter02: too little received"));
        adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 990e18, type(uint256).max, route);
    }

    function test_constructorRejectsZeroRouter() public {
        vm.expectRevert(UniV3Adapter.RouterZero.selector);
        new UniV3Adapter(address(0), address(uint160(1)));
    }

    function test_constructorRejectsZeroWrapper() public {
        vm.expectRevert(UniV3Adapter.WrapperZero.selector);
        new UniV3Adapter(address(router), address(0));
    }

    /// A single-hop fill stopped early by `sqrtPriceLimitX96` pulls part of the
    /// input. The remainder would be stranded on the adapter, so the swap
    /// reverts even though the output clears `minOut`.
    function test_revert_partialFillSingleHop() public {
        _fund(1_000e18, 990e18);
        router.setConsumeBps(5_000);
        bytes memory route = abi.encode(uint24(500), uint160(1));
        vm.expectRevert(abi.encodeWithSelector(UniV3Adapter.PartialFill.selector, 500e18, 1_000e18));
        adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 990e18, type(uint256).max, route);
    }

    /// As above, for a multi-hop path that runs out of liquidity.
    function test_revert_partialFillMultiHop() public {
        _fund(1_000e18, 980e18);
        router.setConsumeBps(9_999);
        bytes memory route = _path(address(tokenIn), address(tokenOut));
        vm.expectRevert(abi.encodeWithSelector(UniV3Adapter.PartialFill.selector, 999.9e18, 1_000e18));
        adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 980e18, type(uint256).max, route);
    }

    /// A multi-hop path must start at `tokenIn`, or the router would spend a
    /// token the adapter never measures.
    function test_revert_pathFirstTokenMismatch() public {
        _fund(1_000e18, 980e18);
        bytes memory route = _path(address(tokenOut), address(tokenOut));
        vm.expectRevert(UniV3Adapter.BadPath.selector);
        adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 980e18, type(uint256).max, route);
    }

    /// A multi-hop path must end at `tokenOut`, or the output would arrive in a
    /// token the balance delta never reads.
    function test_revert_pathLastTokenMismatch() public {
        _fund(1_000e18, 980e18);
        bytes memory route = _path(address(tokenIn), address(0xBADBABE));
        vm.expectRevert(UniV3Adapter.BadPath.selector);
        adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 980e18, type(uint256).max, route);
    }

    /// A path must be `token || [fee || token] * hops` with at least one hop.
    /// Every other length but the 64-byte single-hop encoding is rejected, even
    /// when both ends name the right tokens.
    function test_revert_malformedPathLength() public {
        _fund(1_000e18, 980e18);
        bytes[4] memory routes = [
            abi.encodePacked(address(tokenIn)),
            abi.encodePacked(address(tokenIn), address(tokenOut)),
            abi.encodePacked(address(tokenIn), uint24(500), uint8(0), address(tokenOut)),
            abi.encodePacked(address(tokenIn), uint24(500), address(tokenOut), uint24(3000))
        ];
        for (uint256 i; i < routes.length; ++i) {
            vm.expectRevert(UniV3Adapter.BadPath.selector);
            adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 980e18, type(uint256).max, routes[i]);
        }
    }

    /// Two-hop packed path `first || fee || mid || fee || last`.
    function _path(address first, address last) internal pure returns (bytes memory) {
        return abi.encodePacked(first, uint24(500), address(0xBADBABE), uint24(3000), last);
    }

    /// `swap` is pinned to the wrapper. Without that, any caller could route
    /// tokens donated to the adapter to themselves.
    function test_revert_unauthorizedCaller() public {
        _fund(1_000e18, 990e18);
        bytes memory route = abi.encode(uint24(500), uint160(0));
        vm.prank(address(0xBAD));
        vm.expectRevert(UniV3Adapter.UnauthorizedCaller.selector);
        adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 990e18, type(uint256).max, route);
    }
}
