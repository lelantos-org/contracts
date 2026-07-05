// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ISwapAdapter } from "./ISwapAdapter.sol";

/// Minimal SwapRouter02 surface. Address per chain:
///   Mainnet/Arbitrum: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
///   Base:             0x2626664c2603336E57B271c5C0b26F421741e481
/// SwapRouter02 omits `deadline`; enforced at the wrapper layer.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// UniV3 single-hop and multi-hop adapter. The wrapper transfers `amountIn`
/// of `tokenIn` here; this contract approves the router, executes, and
/// resets the approval.
///
/// `swap` is restricted to the pinned `WRAPPER`; otherwise any caller could
/// drain donated tokens by routing output to themselves.
contract UniV3Adapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    /// Single-hop route: `abi.encode(uint24 fee, uint160 sqrtPriceLimitX96)`,
    /// 64 bytes. `sqrtPriceLimitX96 = 0` disables the pool slippage guard.
    /// Multi-hop routes use the packed path layout (no per-pool sqrt limit).
    uint256 private constant SINGLE_HOP_ROUTE_LEN = 64;

    ISwapRouter02 public immutable ROUTER;
    /// Allowed `swap` caller; others revert `UnauthorizedCaller`.
    address public immutable WRAPPER;

    error RouterZero();
    error WrapperZero();
    error UnauthorizedCaller();

    constructor(address router, address wrapper) {
        if (router == address(0)) revert RouterZero();
        if (wrapper == address(0)) revert WrapperZero();
        ROUTER = ISwapRouter02(router);
        WRAPPER = wrapper;
    }

    /// Approve, swap, reset. Trailing reset to 0 keeps USDT-style tokens
    /// (reject non-zero→non-zero approval) working next swap.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256, /* deadline — enforced by caller wrapper */
        bytes calldata route
    ) external returns (uint256 actualOut) {
        if (msg.sender != WRAPPER) revert UnauthorizedCaller();
        IERC20 inToken = IERC20(tokenIn);
        inToken.forceApprove(address(ROUTER), amountIn);

        if (route.length == SINGLE_HOP_ROUTE_LEN) {
            (uint24 fee, uint160 sqrtPriceLimitX96) = abi.decode(route, (uint24, uint160));
            actualOut = ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: msg.sender,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: sqrtPriceLimitX96
                })
            );
        } else {
            actualOut = ROUTER.exactInput(
                ISwapRouter02.ExactInputParams({
                    path: route, recipient: msg.sender, amountIn: amountIn, amountOutMinimum: minOut
                })
            );
        }

        inToken.forceApprove(address(ROUTER), 0);
    }
}
