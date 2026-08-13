// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Test stub for UniV3 QuoterV2. Two modes per `(tokenIn, tokenOut, fee)`:
///   1. legacy fixed (`set`)  — `amountOut` constant regardless of input.
///   2. linear rate (`setRate`) — `amountOut = amountIn * ratePer1e18 / 1e18`.
/// Fixed mode wins when both are set so existing e2e tests that pin a
/// specific output keep deterministic behaviour. Tiers with neither
/// configured revert via `NoPool`, mirroring the real QuoterV2.
contract MockQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    struct PoolQuote {
        uint256 amountOut;
        uint256 ratePer1e18;
        uint256 gasEstimate;
        bool isSet;
    }

    /// Keyed by `keccak256(tokenIn, tokenOut, fee)`.
    mapping(bytes32 key => PoolQuote quote) public quotes;

    error NoPool();

    /// Legacy fixed-output setter (kept for e2e back-compat).
    function set(address tokenIn, address tokenOut, uint24 fee, uint256 amountOut, uint256 gasEstimate) external {
        bytes32 k = _key(tokenIn, tokenOut, fee);
        PoolQuote storage q = quotes[k];
        q.amountOut = amountOut;
        q.gasEstimate = gasEstimate;
        q.isSet = true;
    }

    /// Linear-rate setter. `ratePer1e18` is `amountOut` for `amountIn = 1e18`.
    function setRate(address tokenIn, address tokenOut, uint24 fee, uint256 ratePer1e18, uint256 gasEstimate) external {
        bytes32 k = _key(tokenIn, tokenOut, fee);
        PoolQuote storage q = quotes[k];
        q.ratePer1e18 = ratePer1e18;
        q.gasEstimate = gasEstimate;
        q.isSet = true;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams calldata p)
        external
        view
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        PoolQuote memory q = quotes[_key(p.tokenIn, p.tokenOut, p.fee)];
        if (!q.isSet) revert NoPool();
        amountOut = q.amountOut > 0 ? q.amountOut : (p.amountIn * q.ratePer1e18) / 1e18;
        return (amountOut, 0, 0, q.gasEstimate);
    }

    function _key(address tokenIn, address tokenOut, uint24 fee) private pure returns (bytes32) {
        return keccak256(abi.encode(tokenIn, tokenOut, fee));
    }
}
