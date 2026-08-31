// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Pull-then-push swap adapter. The wrapper pre-transfers `amountIn` of
/// `tokenIn`; the adapter swaps and pushes `actualOut` of `tokenOut` back to
/// `msg.sender`, reverting if `actualOut < minOut`. `deadline` is forwarded as
/// defense-in-depth; the wrapper also enforces it.
interface ISwapAdapter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        bytes calldata route
    ) external returns (uint256 actualOut);
}
