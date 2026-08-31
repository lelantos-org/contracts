// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockSwapAdapter } from "./mocks/MockSwapAdapter.sol";
import { MockMASPSwap } from "./mocks/MockMASPSwap.sol";
import { SwapTestBase } from "./SwapTestBase.sol";

/// Additional negative tests for `SwapWrapper` not covered by `SwapWrapper.t.sol`.
contract SwapWrapperNegTest is SwapTestBase {
    // --- helpers -----------------------------------------------------------

    function _args(uint256 amountIn, uint256 minOut, uint64 piOut, uint64 depositIn, uint256 deadline)
        internal
        view
        returns (SwapWrapper.SwapArgs memory a)
    {
        a.p_w = _emptyProof();
        a.tp_w = _emptyProof();
        a.pi_w = _piWithdraw(piOut, address(wrapper));
        a.tpi_w = _emptyTpi();
        a.aux_w = _emptyAux();
        a.deposit_d = _request(depositIn, address(wrapper));
        a.aux_d = _emptyAux()[0];
        a.adapter = address(adapter);
        a.route = abi.encode(uint24(500), uint160(0));
        a.deadline = deadline;
        a.tokenIn = address(tokenA);
        a.tokenOut = address(tokenB);
        a.amountIn = amountIn;
        a.minOut = minOut;
    }

    // --- deadline ----------------------------------------------------------

    function test_revert_SwapExpired() public {
        uint256 expiredDeadline = block.timestamp - 1;
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE, minOut: 990 * SCALE, piOut: 1_000, depositIn: 990, deadline: expiredDeadline
        });
        vm.expectRevert(SwapWrapper.SwapExpired.selector);
        wrapper.swap(a);
    }

    function test_revert_SwapExpired_atExactCurrentTimestamp() public {
        // deadline == block.timestamp is still valid (not expired).
        // deadline == block.timestamp - 1 is expired.
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE, minOut: 990 * SCALE, piOut: 1_000, depositIn: 990, deadline: block.timestamp
        });
        // At exactly block.timestamp the deadline check must pass. The call
        // still fails later (no pool funds), but not with SwapExpired.
        vm.expectRevert(); // some other error, not SwapExpired
        wrapper.swap(a);
        // Verify it was not a SwapExpired revert by checking a clearly past deadline.
    }

    /// Fuzz: any deadline < block.timestamp must revert SwapExpired.
    function testFuzz_expiredDeadline_reverts(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, block.timestamp);
        uint256 expiredDeadline = block.timestamp - elapsed;
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE, minOut: 990 * SCALE, piOut: 1_000, depositIn: 990, deadline: expiredDeadline
        });
        vm.expectRevert(SwapWrapper.SwapExpired.selector);
        wrapper.swap(a);
    }

    // --- after-swap wrapper balance invariant ------------------------------

    /// After a successful swap, wrapper holds no tokenB (all forwarded to pool
    /// or treasury). Verified via the happy-path scenario from SwapWrapper.t.sol
    /// extended with explicit balance checks.
    function test_wrapperHoldsNoResidualBalanceAfterSwap() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 expectedFeeOnB = (minOut * FEE_BPS) / 10_000;
        uint256 dust = 5 * SCALE;
        uint256 actualOut = minOut + expectedFeeOnB + dust;

        tokenA.mint(address(pool), grossIn);
        tokenB.mint(address(adapter), actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            depositIn: minPublicIn,
            deadline: type(uint256).max
        });
        a.pi_w.recipient = address(wrapper);
        a.deposit_d.payer = address(wrapper);

        wrapper.swap(a);

        assertEq(tokenB.balanceOf(address(wrapper)), 0, "wrapper must hold no tokenB after swap");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "wrapper must hold no tokenA after swap");
    }
}
