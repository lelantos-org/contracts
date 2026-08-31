// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ExactInputSingleParams, IUniversalRouter, V4Commands } from "../../../src/swap/UniV4Adapter.sol";

/// Public-mint hook on the test ERC20 mocks, matching `MockSwapRouter02`.
interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// Test stub for the UniversalRouter's `V4_SWAP` path.
///
/// Unlike `MockSwapRouter02`, this mock **decodes and asserts the full
/// command/action/params encoding** rather than accepting whatever it is
/// handed. That is the point of it: a permissive mock would pass even if the
/// adapter's V4 calldata were wrong in every field, since the mock and the
/// adapter would simply share the same mistaken assumption. Every constant
/// checked below was read off the deployed mainnet UniversalRouter's verified
/// source.
///
/// Output resolution mirrors `MockSwapRouter02`: `nextOut` override, else the
/// linear `rate` table, else revert.
contract MockUniversalRouter is IUniversalRouter {
    uint256 public nextOut;
    mapping(address => mapping(address => uint256)) public rate;

    error NoRate();

    function setNextOut(uint256 v) external {
        nextOut = v;
    }

    function setRate(address tokenIn, address tokenOut, uint256 ratePer1e18) external {
        rate[tokenIn][tokenOut] = ratePer1e18;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        require(block.timestamp <= deadline, "MockUniversalRouter: expired");
        require(commands.length == 1, "MockUniversalRouter: one command expected");
        require(uint8(commands[0]) == V4Commands.V4_SWAP, "MockUniversalRouter: not V4_SWAP");
        require(inputs.length == 1, "MockUniversalRouter: one input expected");

        (bytes memory actions, bytes[] memory params) = abi.decode(inputs[0], (bytes, bytes[]));
        require(actions.length == 3, "MockUniversalRouter: three actions expected");
        require(
            uint8(actions[0]) == V4Commands.SWAP_EXACT_IN_SINGLE, "MockUniversalRouter: action0 != SWAP_EXACT_IN_SINGLE"
        );
        require(uint8(actions[1]) == V4Commands.SETTLE, "MockUniversalRouter: action1 != SETTLE");
        require(uint8(actions[2]) == V4Commands.TAKE_ALL, "MockUniversalRouter: action2 != TAKE_ALL");
        require(params.length == 3, "MockUniversalRouter: three params expected");

        ExactInputSingleParams memory sp = abi.decode(params[0], (ExactInputSingleParams));
        require(sp.poolKey.currency0 < sp.poolKey.currency1, "MockUniversalRouter: currencies unsorted");
        require(sp.poolKey.hooks == address(0), "MockUniversalRouter: hooks must be zero");
        require(sp.poolKey.tickSpacing != 0, "MockUniversalRouter: zero tickSpacing");
        require(sp.hookData.length == 0, "MockUniversalRouter: hookData must be empty");

        address tokenIn = sp.zeroForOne ? sp.poolKey.currency0 : sp.poolKey.currency1;
        address tokenOut = sp.zeroForOne ? sp.poolKey.currency1 : sp.poolKey.currency0;

        (address settleCurrency, uint256 settleAmount, bool payerIsUser) =
            abi.decode(params[1], (address, uint256, bool));
        require(settleCurrency == tokenIn, "MockUniversalRouter: settle currency mismatch");
        // Exact amount, not CONTRACT_BALANCE: settling the router's whole
        // balance over-pays the PoolManager debt when anyone donates to the
        // shared router, which reverts the real unlock with `CurrencyNotSettled`.
        require(settleAmount == sp.amountIn, "MockUniversalRouter: settle amount must be exact");
        require(!payerIsUser, "MockUniversalRouter: payerIsUser must be false");

        (address takeCurrency, uint256 takeMin) = abi.decode(params[2], (address, uint256));
        require(takeCurrency == tokenOut, "MockUniversalRouter: take currency mismatch");

        // The adapter transfers the input in before calling, so the router must
        // be holding at least what it is about to settle.
        require(IERC20(tokenIn).balanceOf(address(this)) >= sp.amountIn, "MockUniversalRouter: input not transferred");

        uint256 amountOut = _resolveOut(tokenIn, tokenOut, sp.amountIn);
        require(amountOut >= sp.amountOutMinimum, "MockUniversalRouter: too little received");
        require(amountOut >= takeMin, "MockUniversalRouter: V4TooLittleReceived");

        // TAKE_ALL credits `msgSender()`, which for a direct `execute` call is
        // the adapter.
        IMintable(tokenOut).mint(msg.sender, amountOut);
    }

    function _resolveOut(address tokenIn, address tokenOut, uint256 amountIn) private view returns (uint256) {
        if (nextOut > 0) return nextOut;
        uint256 r = rate[tokenIn][tokenOut];
        if (r == 0) revert NoRate();
        return (amountIn * r) / 1e18;
    }
}
