// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { GenericCallWrapper } from "../../../src/generic/GenericCallWrapper.sol";
import { IMASPPool } from "../../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../../src/libs/PubInputs.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// DeFi stand-in the executor calls. Pulls its input from the caller against an
/// allowance and mints whatever output the test asks for.
contract MockRouter {
    error RouterFailed();

    /// Pulls `amountIn` of `tokenIn`, mints `amountOut` of `tokenOut` to the caller.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IMintable(tokenOut).mint(msg.sender, amountOut);
    }

    /// Pulls `amountIn` of `tokenIn`, mints two outputs, as a liquidity removal.
    function split(address tokenIn, uint256 amountIn, address outA, uint256 aOut, address outB, uint256 bOut) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IMintable(outA).mint(msg.sender, aOut);
        IMintable(outB).mint(msg.sender, bOut);
    }

    function fail() external pure {
        revert RouterFailed();
    }

    /// Reverts with a payload far past the executor's bubbling cap.
    function bomb() external pure {
        bytes memory junk = new bytes(10_000);
        assembly {
            revert(add(junk, 0x20), mload(junk))
        }
    }

    /// Reverts with no payload.
    function silent() external pure {
        revert();
    }

    function burnGas() external pure {
        while (true) { }
    }
}

/// Pulls a token from whoever approved it, for the stale-approval attack.
contract MockDrainer {
    function drain(IERC20 token, address from) external {
        token.transferFrom(from, address(this), token.balanceOf(from));
    }
}

/// Reaches the wrapper and the pool through a contract of its own, since both
/// are denied as direct targets.
contract MockReentrant {
    function cancel(GenericCallWrapper wrapper, uint256 id, uint64 assetId) external {
        PubInputs.FeeNote memory feeNote;
        wrapper.cancelEscrow(id, 0, bytes32(0), [uint256(0), 0], assetId, 0, 0, feeNote);
    }

    function cancelOnPool(IMASPPool pool, address payer, uint256 id, uint64 assetId) external {
        PubInputs.FeeNote memory feeNote;
        pool.cancelDeposit(id, 0, bytes32(0), [uint256(0), 0], assetId, 0, payer, 0, feeNote);
    }

    function prepare(GenericCallWrapper wrapper, IERC20 token) external {
        wrapper.prepareToken(token);
    }
}

/// Sends tokens to an address mid-execution, as a donation.
contract MockDonor {
    function donate(address token, address to, uint256 amount) external {
        IMintable(token).mint(to, amount);
    }
}
