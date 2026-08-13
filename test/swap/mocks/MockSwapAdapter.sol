// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISwapAdapter } from "../../../src/swap/ISwapAdapter.sol";

/// Test-only swap adapter. The harness pre-funds it with `tokenOut`; on
/// `swap` it accepts the incoming `tokenIn` and pushes back a configurable
/// `actualOut` of `tokenOut`. Lets tests model happy paths, dust, and
/// slippage reverts without a real DEX.
contract MockSwapAdapter is ISwapAdapter {
    /// Amount of `tokenOut` the next `swap` call will push back. Tests
    /// set this before invoking the wrapper.
    uint256 public nextActualOut;
    /// If true, the next call returns without sending any `tokenOut`,
    /// simulating a faulty venue.
    bool public siphonMode;
    /// `tokenIn` pushed back to the caller, modelling a venue that consumes
    /// less than it was handed. The wrapper's closing leftover invariant is
    /// what must catch it.
    uint256 public refundIn;
    /// `tokenOut` delivered on top of the reported `actualOut`, modelling a
    /// venue whose return value understates what it sent.
    uint256 public extraOut;
    /// If true, skip the internal `minOut` check so the call returns a short
    /// output instead of reverting — that hands the decision to the wrapper.
    bool public ignoreMinOut;

    function setNextActualOut(uint256 v) external {
        nextActualOut = v;
    }

    function setSiphonMode(bool v) external {
        siphonMode = v;
    }

    function setRefundIn(uint256 v) external {
        refundIn = v;
    }

    function setExtraOut(uint256 v) external {
        extraOut = v;
    }

    function setIgnoreMinOut(bool v) external {
        ignoreMinOut = v;
    }

    function swap(address tokenIn, address tokenOut, uint256, uint256 minOut, uint256, bytes calldata)
        external
        returns (uint256 actualOut)
    {
        actualOut = nextActualOut;
        if (actualOut < minOut && !ignoreMinOut) {
            // Mirror real adapter behaviour: revert when output insufficient.
            revert("MockSwapAdapter: insufficient out");
        }
        if (!siphonMode) {
            IERC20(tokenOut).transfer(msg.sender, actualOut + extraOut);
        }
        if (refundIn != 0) IERC20(tokenIn).transfer(msg.sender, refundIn);
    }
}
