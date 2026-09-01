// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ISwapAdapter } from "./ISwapAdapter.sol";

/// Minimal SwapRouter02 surface. Deployments:
/// - Mainnet / Arbitrum: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
/// - Base: 0x2626664c2603336E57B271c5C0b26F421741e481
///
/// SwapRouter02 takes no `deadline`; it is enforced at the wrapper layer.
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

/// Uniswap V3 single-hop and multi-hop adapter. The wrapper transfers
/// `amountIn` of `tokenIn` here; this contract approves the router, executes the
/// swap, resets the approval, and pushes the output back to the wrapper.
///
/// `swap` is restricted to the pinned `WRAPPER`: any other caller could drain
/// donated tokens by routing the output to themselves.
contract UniV3Adapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    /// Single-hop route: `abi.encode(uint24 fee, uint160 sqrtPriceLimitX96)`,
    /// 64 bytes. `sqrtPriceLimitX96 = 0` disables the pool slippage guard.
    /// Multi-hop routes use the packed path layout, which has no per-pool
    /// square-root price limit.
    uint256 private constant SINGLE_HOP_ROUTE_LEN = 64;

    ISwapRouter02 public immutable ROUTER;
    /// The only permitted `swap` caller; others revert `UnauthorizedCaller`.
    address public immutable WRAPPER;

    error RouterZero();
    error WrapperZero();
    error UnauthorizedCaller();
    error InsufficientOut(uint256 actualOut, uint256 minOut);

    constructor(address router, address wrapper) {
        if (router == address(0)) revert RouterZero();
        if (wrapper == address(0)) revert WrapperZero();
        ROUTER = ISwapRouter02(router);
        WRAPPER = wrapper;
    }

    /// Approve, swap, then reset. The trailing reset to zero keeps tokens that
    /// reject non-zero-to-non-zero approval changes, such as USDT, usable on the
    /// next swap.
    ///
    /// The output is taken to this adapter, measured as a balance delta across
    /// the router call rather than read from the router's return value, then
    /// pushed to the wrapper. `SwapWrapper` settles against this return value
    /// and uses it as the ceiling on what MASP may pull from its own balance, so
    /// it must be what the venue delivered: a router over-reporting the output,
    /// as it does for any fee-on-transfer `tokenOut`, would raise that ceiling
    /// above the swap's real output.
    ///
    /// This is what `reentrancy-balance` reports. The snapshot cannot go stale
    /// in a way that over-counts: the only permitted caller is the pinned
    /// `WRAPPER`, whose `swap` holds `nonReentrant` across the whole call, and
    /// `ROUTER` is immutable. A multi-hop `route` is unauthenticated calldata and
    /// may name a token that runs its own code mid-swap, but the delta credits
    /// only `tokenOut` that arrived here, and nothing but `ROUTER`, approved for
    /// `tokenIn` alone, can move it out.
    // slither-disable-next-line reentrancy-balance
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256, /* deadline: enforced by the calling wrapper */
        bytes calldata route
    ) external returns (uint256 actualOut) {
        if (msg.sender != WRAPPER) revert UnauthorizedCaller();
        IERC20 inToken = IERC20(tokenIn);
        IERC20 outToken = IERC20(tokenOut);
        inToken.forceApprove(address(ROUTER), amountIn);

        uint256 outBefore = outToken.balanceOf(address(this));
        if (route.length == SINGLE_HOP_ROUTE_LEN) {
            (uint24 fee, uint160 sqrtPriceLimitX96) = abi.decode(route, (uint24, uint160));
            // The router's reported output is ignored; `actualOut` is the
            // measured balance delta.
            // slither-disable-next-line unused-return
            ROUTER.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: sqrtPriceLimitX96
                })
            );
        } else {
            // As above: the reported output is ignored in favour of the delta.
            // slither-disable-next-line unused-return
            ROUTER.exactInput(
                ISwapRouter02.ExactInputParams({
                    path: route, recipient: address(this), amountIn: amountIn, amountOutMinimum: minOut
                })
            );
        }
        actualOut = outToken.balanceOf(address(this)) - outBefore;

        inToken.forceApprove(address(ROUTER), 0);

        // Defense in depth: the router enforces `minOut`, but the wrapper
        // settles against the measured delta, so that is checked too.
        if (actualOut < minOut) revert InsufficientOut(actualOut, minOut);

        outToken.safeTransfer(msg.sender, actualOut);
    }
}
