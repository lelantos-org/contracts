// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ISwapAdapter } from "./ISwapAdapter.sol";

/// Minimal UniversalRouter surface. Addresses per chain:
///   Mainnet:  0x66a9893cC07d91D95644AEDD05D03f95e1dBA8Af
///   Arbitrum: 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3
///   Base:     0x6fF5693b99212Da76ad316178A184AB56D299b43
/// Unlike SwapRouter02, `execute` returns nothing, so callers measure a balance
/// delta rather than trusting a router-reported output.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// A V4 pool's identity. `currency0 < currency1` is required by the
/// PoolManager. `hooks` is part of the key but this adapter always sets it to
/// the zero address; see `UniV4Adapter`.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// `IV4Router.ExactInputSingleParams` **as deployed**. Upstream revisions after
/// March 2026 add a `minHopPriceX36` field between `amountOutMinimum` and
/// `hookData`; the routers live on mainnet, Arbitrum and Base all predate that
/// change, so this five-field layout is what they decode. Encoding the newer
/// layout against them produces calldata they cannot decode.
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// Command and action opcodes, transcribed from the deployed UniversalRouter
/// (`Commands.sol`, `v4-periphery/src/libraries/Actions.sol`). Hand-copied
/// rather than imported: pulling v4-core and v4-periphery in as submodules for
/// one adapter is not worth the dependency weight. `UniV4Adapter.fork.t.sol` is
/// what proves these match the live routers.
library V4Commands {
    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SETTLE = 0x0b;
    uint8 internal constant TAKE_ALL = 0x0f;
}

/// Uniswap V4 single-hop adapter, routed through the UniversalRouter's
/// `V4_SWAP` command. The wrapper transfers `amountIn` of `tokenIn` here; this
/// contract forwards it to the router, runs the swap, and pushes the output
/// back to the wrapper.
///
/// `swap` is restricted to the pinned `WRAPPER`. Without that restriction, any
/// caller could drain donated tokens by routing the output to themselves.
///
/// Only vanilla pools are reachable: `hooks` is pinned to `address(0)` and is
/// not part of the route. `route` is unauthenticated calldata on the
/// `SwapWrapper.swap` path, so accepting an arbitrary `hooks` address would let
/// a caller name a contract that the PoolManager then calls mid-swap. Vetted
/// hook pools would need an explicit allowlist, not a wider route blob.
contract UniV4Adapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    IUniversalRouter public immutable ROUTER;
    /// The only permitted `swap` caller; others revert `UnauthorizedCaller`.
    address public immutable WRAPPER;

    error RouterZero();
    error WrapperZero();
    error UnauthorizedCaller();
    error AmountTooLarge(uint256 value);
    error InsufficientOut(uint256 actualOut, uint256 minOut);

    constructor(address router, address wrapper) {
        if (router == address(0)) revert RouterZero();
        if (wrapper == address(0)) revert WrapperZero();
        ROUTER = IUniversalRouter(router);
        WRAPPER = wrapper;
    }

    /// Route layout: `abi.encode(uint24 fee, int24 tickSpacing)`, 64 bytes.
    /// Currency ordering is derived from the token addresses rather than
    /// encoded, so the route cannot disagree with `tokenIn`/`tokenOut`.
    ///
    /// `deadline` is forwarded to the router, which enforces it; the wrapper
    /// checks it too.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        bytes calldata route
    ) external returns (uint256 actualOut) {
        if (msg.sender != WRAPPER) revert UnauthorizedCaller();

        bytes[] memory inputs = _encodeSwap(tokenIn, tokenOut, amountIn, minOut, route);

        IERC20(tokenIn).safeTransfer(address(ROUTER), amountIn);

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        ROUTER.execute(abi.encodePacked(V4Commands.V4_SWAP), inputs, deadline);
        actualOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;

        // Defense in depth: the router enforces `minOut` twice already, but the
        // wrapper settles against this return value, so the measured delta is
        // checked too.
        if (actualOut < minOut) revert InsufficientOut(actualOut, minOut);

        IERC20(tokenOut).safeTransfer(msg.sender, actualOut);
    }

    /// Builds the single `V4_SWAP` input: the action sequence plus one
    /// ABI-encoded parameter blob per action.
    ///
    /// Split out of `swap` because this encoding is the delicate part of the
    /// adapter — every byte of it is dictated by the deployed router — and it
    /// keeps the swap's own control flow readable.
    function _encodeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata route)
        private
        pure
        returns (bytes[] memory inputs)
    {
        (uint24 fee, int24 tickSpacing) = abi.decode(route, (uint24, int24));
        bool zeroForOne = tokenIn < tokenOut;

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: PoolKey({
                    currency0: zeroForOne ? tokenIn : tokenOut,
                    currency1: zeroForOne ? tokenOut : tokenIn,
                    fee: fee,
                    tickSpacing: tickSpacing,
                    hooks: address(0)
                }),
                zeroForOne: zeroForOne,
                amountIn: _toUint128(amountIn),
                amountOutMinimum: _toUint128(minOut),
                hookData: ""
            })
        );
        // Settle the input from the router's own balance, funded by the caller
        // just after this returns. `payerIsUser = false` names the router as
        // payer, which keeps the whole flow off Permit2 and needs no approval.
        //
        // The amount is the exact `amountIn`, deliberately not
        // `ActionConstants.CONTRACT_BALANCE`. The UniversalRouter is a shared
        // public contract, so anyone can send it tokens; settling its whole
        // balance would over-pay the PoolManager debt and leave an unclaimed
        // credit, reverting the unlock with `CurrencyNotSettled`. A 1 wei
        // donation would otherwise brick every swap for that token.
        params[1] = abi.encode(tokenIn, amountIn, false);
        // Take the full output credit to this adapter, with `minOut` re-checked
        // by the router on top of the swap's own `amountOutMinimum`.
        params[2] = abi.encode(tokenOut, minOut);

        inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(V4Commands.SWAP_EXACT_IN_SINGLE, V4Commands.SETTLE, V4Commands.TAKE_ALL), params
        );
    }

    /// The router's calldata layout narrows both amounts to `uint128`, so the
    /// bound is checked at the cast rather than left to a distant guard.
    function _toUint128(uint256 v) private pure returns (uint128) {
        if (v > type(uint128).max) revert AmountTooLarge(v);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(v);
    }
}
