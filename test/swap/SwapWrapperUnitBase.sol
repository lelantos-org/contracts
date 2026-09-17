// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";

import { SwapTestBase } from "./SwapTestBase.sol";

/// Funding and payload helpers shared by the `SwapWrapper` unit suites
/// (`SwapWrapper.t.sol`, `.admin`, `.leftover`, `.escrow`).
///
/// Kept apart from `SwapTestBase` because `SwapWrapperNegTest` declares its own
/// `_args` with a different signature; inheriting both would overload a name
/// these suites call with named arguments.
abstract contract SwapWrapperUnitBase is SwapTestBase {
    function _mintToPool(uint256 amt) internal {
        tokenA.mint(address(pool), amt);
    }

    function _fundAdapter(uint256 amt) internal {
        tokenB.mint(address(adapter), amt);
    }

    /// `_defaultSwapArgs` with the three fields the validation tests vary.
    function _args(
        uint256 amountIn,
        uint256 minOut,
        uint64 piOut,
        uint64 depositIn,
        address adapter_,
        address recipient,
        address payer
    ) internal view returns (SwapWrapper.SwapArgs memory a) {
        a = _defaultSwapArgs(amountIn, minOut, piOut, depositIn);
        a.pi_w.recipient = recipient;
        a.pi_w.relayer = recipient;
        a.deposit_d.payer = payer;
        a.adapter = adapter_;
    }

    /// Sets up the happy path, then lets the caller perturb the adapter. All
    /// amounts mirror `test_happyPathForwardsDustToTreasury`.
    function _armSwap() internal returns (SwapWrapper.SwapArgs memory a, uint256 actualOut) {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        actualOut = minOut + (minOut * FEE_BPS) / 10_000 + 7 * SCALE;

        _mintToPool(grossIn);
        _fundAdapter(actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            depositIn: minPublicIn,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
    }
}
