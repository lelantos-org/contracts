// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockSwapAdapter } from "./mocks/MockSwapAdapter.sol";
import { MockMASPSwap } from "./mocks/MockMASPSwap.sol";
import { SwapTestBase } from "./SwapTestBase.sol";

/// Binding between the leg-1 withdraw proof and the leg-2 deposit.
/// `swap` is permissionless, so `pi_w.payer` names the sole address permitted
/// to drive the swap, and the measured MASP pull is bounded below by `minOut`
/// so `deposit_d` cannot name a different asset or a smaller amount.
contract SwapWrapperBindingTest is SwapTestBase {
    uint64 internal constant ASSET_C = 3;
    address internal constant VICTIM_NOTE = address(0xBEEF);
    address internal constant ATTACKER_NOTE = address(0xBAD);
    /// Address the withdraw proof authorizes to drive the swap.
    address internal constant SWAP_DRIVER = address(0xD21E);

    MockERC20 internal tokenC;

    /// This suite needs a third asset to express a cross-asset binding attack.
    function _registerExtraAssets() internal override {
        tokenC = new MockERC20("Token C", "TKC", 18);
        pool.registerAsset(ASSET_C, address(tokenC), SCALE);
        wrapper.prepareToken(IERC20(address(tokenC)));
    }

    function _baseArgs(uint256 grossIn, uint256 minOut, uint64 depositIn)
        internal
        view
        returns (SwapWrapper.SwapArgs memory a)
    {
        a.p_w = _emptyProof();
        a.tp_w = _emptyProof();
        // The originating proof names only the wrapper; no public input
        // identifies the caller of `swap`.
        a.pi_w.publicAssetId = ASSET_A;
        a.pi_w.publicOut = uint64(grossIn / SCALE);
        a.pi_w.recipient = address(wrapper);
        a.pi_w.relayer = address(wrapper);
        a.pi_w.payer = SWAP_DRIVER;

        a.deposit_d.chainId = block.chainid;
        a.deposit_d.publicAssetId = ASSET_B;
        a.deposit_d.publicIn = depositIn;
        a.deposit_d.payer = address(wrapper);
        a.deposit_d.recipient = VICTIM_NOTE;
        a.deposit_d.outCm = bytes32(uint256(1));

        a.adapter = address(adapter);
        a.route = abi.encode(uint24(500), uint160(0));
        a.deadline = type(uint256).max;
        a.tokenIn = address(tokenA);
        a.tokenOut = address(tokenB);
        a.amountIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        a.minOut = minOut;
    }

    /// Replaying the withdraw proof verbatim under a substituted `deposit_d`
    /// must not redirect the output note.
    function test_revert_frontRunnerCannotRedirectOutputNote() public {
        uint256 grossIn = 1_000 * SCALE;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 actualOut = minOut + (minOut * FEE_BPS) / 10_000;

        tokenA.mint(address(pool), grossIn);
        tokenB.mint(address(adapter), actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _baseArgs(grossIn, minOut, minPublicIn);
        // Identical proof and public inputs; only the deposit changes.
        a.deposit_d.recipient = ATTACKER_NOTE;
        a.deposit_d.outCm = bytes32(uint256(0xA77ACC));

        vm.prank(address(0xDEADBEEF)); // arbitrary caller, not the victim
        vm.expectRevert(
            abi.encodeWithSelector(SwapWrapper.UnauthorizedSwapCaller.selector, address(0xDEADBEEF), a.pi_w.payer)
        );
        wrapper.swap(a);
    }

    /// The address named by `pi_w.payer` drives the swap normally.
    function test_authorizedCallerSucceeds() public {
        uint256 grossIn = 1_000 * SCALE;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 actualOut = minOut + (minOut * FEE_BPS) / 10_000;

        tokenA.mint(address(pool), grossIn);
        tokenB.mint(address(adapter), actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _baseArgs(grossIn, minOut, minPublicIn);

        vm.prank(SWAP_DRIVER);
        wrapper.swap(a);

        assertEq(pool.lastDepositRecipient(), VICTIM_NOTE, "output note recipient");
        assertEq(pool.lastDepositAssetId(), ASSET_B, "escrowed asset");
    }

    /// `deposit_d.publicAssetId` must denominate the pull in `tokenOut`. Any
    /// other token held by the wrapper must not be escrowable.
    function test_revert_depositAssetMustMatchTokenOut() public {
        uint256 grossIn = 1_000 * SCALE;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 actualOut = minOut + (minOut * FEE_BPS) / 10_000;

        tokenA.mint(address(pool), grossIn);
        tokenB.mint(address(adapter), actualOut);
        // Token C was donated to the wrapper.
        tokenC.mint(address(wrapper), 5_000 * SCALE);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _baseArgs(grossIn, minOut, minPublicIn);
        a.deposit_d.publicAssetId = ASSET_C; // not tokenOut
        a.deposit_d.recipient = ATTACKER_NOTE;

        vm.prank(SWAP_DRIVER);
        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.PullBelowMin.selector, 0, minOut));
        wrapper.swap(a);

        assertEq(tokenC.balanceOf(address(wrapper)), 5_000 * SCALE, "donated token C must stay put");
    }

    /// Escrowing less than the requested output, routing the remainder to the
    /// treasury as dust, must be rejected.
    function test_revert_depositCannotUnderEscrowOutput() public {
        uint256 grossIn = 1_000 * SCALE;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 actualOut = minOut + (minOut * FEE_BPS) / 10_000;

        tokenA.mint(address(pool), grossIn);
        tokenB.mint(address(adapter), actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _baseArgs(grossIn, minOut, minPublicIn);
        a.deposit_d.publicIn = 1; // escrow a negligible amount, rest to treasury

        uint256 pulled = uint256(1) * SCALE;
        pulled += (pulled * FEE_BPS) / 10_000;

        vm.prank(SWAP_DRIVER);
        vm.expectRevert(abi.encodeWithSelector(MaspEscrowSatellite.PullBelowMin.selector, pulled, minOut));
        wrapper.swap(a);
    }
}
