// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISwapRouter02 } from "../../../src/swap/UniV3Adapter.sol";

/// Public-mint hook on the test ERC20 mocks. Both `MockERC20` and
/// `MockWETH9` expose `_mint` via a public `mint` shim, so the router
/// can synthesize `amountOut` on demand without holding inventory.
interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// Test stub for UniV3 SwapRouter02. Pulls `amountIn` of `tokenIn` via
/// `transferFrom` (mirroring router behaviour) and pushes `amountOut`
/// of `tokenOut` to the recipient via direct mint (so dev sessions
/// don't need router liquidity seeding).
///
/// Output resolution priority:
///   1. `nextOut` if non-zero — fixed override (used by e2e slippage tests).
///   2. `rate[tokenIn][tokenOut]` linear rate — `amountIn * rate / 1e18`.
///   3. revert (no rate configured).
contract MockSwapRouter02 is ISwapRouter02 {
    uint256 public nextOut;
    mapping(address => mapping(address => uint256)) public rate;

    error NoRate();

    function setNextOut(uint256 v) external {
        nextOut = v;
    }

    function setRate(address tokenIn, address tokenOut, uint256 ratePer1e18) external {
        rate[tokenIn][tokenOut] = ratePer1e18;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = _resolveOut(p.tokenIn, p.tokenOut, p.amountIn);
        require(amountOut >= p.amountOutMinimum, "MockSwapRouter02: too little received");
        IMintable(p.tokenOut).mint(p.recipient, amountOut);
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 amountOut) {
        // Decode first/last token from the packed path: [token0 | fee | ... | tokenN].
        address tokenIn = _firstToken(p.path);
        address tokenOut = _lastToken(p.path);
        IERC20(tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = _resolveOut(tokenIn, tokenOut, p.amountIn);
        require(amountOut >= p.amountOutMinimum, "MockSwapRouter02: too little received");
        IMintable(tokenOut).mint(p.recipient, amountOut);
    }

    function _resolveOut(address tokenIn, address tokenOut, uint256 amountIn) private view returns (uint256) {
        if (nextOut > 0) return nextOut;
        uint256 r = rate[tokenIn][tokenOut];
        if (r == 0) revert NoRate();
        return (amountIn * r) / 1e18;
    }

    function _firstToken(bytes calldata path) internal pure returns (address t) {
        require(path.length >= 20, "bad path");
        t = address(bytes20(path[0:20]));
    }

    function _lastToken(bytes calldata path) internal pure returns (address t) {
        require(path.length >= 20, "bad path");
        t = address(bytes20(path[path.length - 20:path.length]));
    }
}
