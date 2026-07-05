// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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

    function setNextActualOut(uint256 v) external {
        nextActualOut = v;
    }

    function setSiphonMode(bool v) external {
        siphonMode = v;
    }

    function swap(address, address tokenOut, uint256, uint256 minOut, uint256, bytes calldata)
        external
        returns (uint256 actualOut)
    {
        actualOut = nextActualOut;
        if (actualOut < minOut) {
            // Mirror real adapter behaviour: revert when output insufficient.
            revert("MockSwapAdapter: insufficient out");
        }
        if (!siphonMode) {
            IERC20(tokenOut).transfer(msg.sender, actualOut);
        }
    }
}
