// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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

    function testSingleHopRoute() public {
        _fund(1_000e18, 990e18);
        bytes memory route = abi.encode(uint24(500), uint160(0));
        uint256 actualOut =
            adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 990e18, type(uint256).max, route);
        assertEq(actualOut, 990e18);
        assertEq(tokenOut.balanceOf(caller), 990e18, "caller got tokenOut");
        assertEq(tokenIn.allowance(address(adapter), address(router)), 0, "approval reset");
    }

    function testMultiHopRoute() public {
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

    function testRevertsOnInsufficientOut() public {
        _fund(1_000e18, 800e18); // router returns 800
        bytes memory route = abi.encode(uint24(500), uint160(0));
        vm.expectRevert(bytes("MockSwapRouter02: too little received"));
        adapter.swap(address(tokenIn), address(tokenOut), 1_000e18, 990e18, type(uint256).max, route);
    }

    function testConstructorRejectsZeroRouter() public {
        vm.expectRevert(UniV3Adapter.RouterZero.selector);
        new UniV3Adapter(address(0), address(uint160(1)));
    }
}
