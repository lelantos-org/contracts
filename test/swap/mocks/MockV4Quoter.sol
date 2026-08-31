// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Test stub for the deployed `V4Quoter` lens, mirroring `MockQuoterV2`.
///
/// Rates are keyed by `(tokenIn, tokenOut, fee)` — tick spacing is not part of
/// the key, since the anvil stack seeds one rate per canonical tier and the
/// adapter derives spacing from the fee.
contract MockV4Quoter {
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

    struct Rate {
        uint256 ratePer1e18;
        uint256 gasEstimate;
    }

    mapping(address => mapping(address => mapping(uint24 => Rate))) public rates;

    error NoPool();

    function setRate(address tokenIn, address tokenOut, uint24 fee, uint256 ratePer1e18, uint256 gasEstimate) external {
        rates[tokenIn][tokenOut][fee] = Rate(ratePer1e18, gasEstimate);
    }

    /// Reverts with `NoPool` for an unseeded tier, mirroring the real lens,
    /// which reverts when the pool is not initialized. The metaquoter drops
    /// reverting tiers from its fan-out.
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        view
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        address tokenIn = params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1;
        address tokenOut = params.zeroForOne ? params.poolKey.currency1 : params.poolKey.currency0;
        Rate memory r = rates[tokenIn][tokenOut][params.poolKey.fee];
        if (r.ratePer1e18 == 0) revert NoPool();
        amountOut = (uint256(params.exactAmount) * r.ratePer1e18) / 1e18;
        gasEstimate = r.gasEstimate;
    }
}
