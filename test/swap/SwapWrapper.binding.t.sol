// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { IMASPSwap } from "../../src/swap/IMASPSwap.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockSwapAdapter } from "./mocks/MockSwapAdapter.sol";
import { MockMASPSwap } from "./mocks/MockMASPSwap.sol";

/// Binding between the leg-1 withdraw proof and the leg-2 deposit intent.
/// `swap` is permissionless, so `pi_w.payer` names the sole address permitted
/// to drive the swap, and the measured MASP pull is bounded below by `minOut`
/// so `intent_d` cannot name a different asset or a smaller amount.
contract SwapWrapperBindingTest is Test {
    uint64 internal constant ASSET_A = 1;
    uint64 internal constant ASSET_B = 2;
    uint64 internal constant ASSET_C = 3;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant OWNER = address(0xC0FFEE);
    address internal constant TREASURY = address(0xFEE);
    address internal constant VICTIM_NOTE = address(0xBEEF);
    address internal constant ATTACKER_NOTE = address(0xBAD);
    /// Address the withdraw proof authorizes to drive the swap.
    address internal constant SWAP_DRIVER = address(0xD21E);

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;
    IAllowanceTransfer internal permit2;
    MockMASPSwap internal pool;
    MockSwapAdapter internal adapter;
    SwapWrapper internal wrapper;

    function setUp() public {
        permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        tokenC = new MockERC20("Token C", "TKC", 18);

        pool = new MockMASPSwap(permit2);
        pool.registerAsset(ASSET_A, address(tokenA), SCALE);
        pool.registerAsset(ASSET_B, address(tokenB), SCALE);
        pool.registerAsset(ASSET_C, address(tokenC), SCALE);
        pool.setFeeBps(FEE_BPS);

        adapter = new MockSwapAdapter();
        wrapper = new SwapWrapper(pool, permit2, OWNER, TREASURY);

        vm.prank(OWNER);
        wrapper.setAdapterAllowed(address(adapter), true);

        wrapper.prepareToken(IERC20(address(tokenB)));
        wrapper.prepareToken(IERC20(address(tokenC)));
    }

    function _emptyProof() internal pure returns (IMASPSwap.Proof memory) {
        return IMASPSwap.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    function _baseArgs(uint256 grossIn, uint256 minOut, uint64 intentIn)
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

        a.intent_d.chainId = block.chainid;
        a.intent_d.publicAssetId = ASSET_B;
        a.intent_d.publicIn = intentIn;
        a.intent_d.payer = address(wrapper);
        a.intent_d.recipient = VICTIM_NOTE;
        a.intent_d.outCm = bytes32(uint256(1));

        a.adapter = address(adapter);
        a.route = abi.encode(uint24(500), uint160(0));
        a.deadline = type(uint256).max;
        a.tokenIn = address(tokenA);
        a.tokenOut = address(tokenB);
        a.amountIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        a.minOut = minOut;
    }

    /// Replaying the withdraw proof verbatim under a substituted `intent_d`
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
        // Identical proof and public inputs; only the deposit intent changes.
        a.intent_d.recipient = ATTACKER_NOTE;
        a.intent_d.outCm = bytes32(uint256(0xA77ACC));

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

        assertEq(pool.lastIntentRecipient(), VICTIM_NOTE, "output note recipient");
        assertEq(pool.lastIntentAssetId(), ASSET_B, "escrowed asset");
    }

    /// `intent_d.publicAssetId` must denominate the pull in `tokenOut`. Any
    /// other token held by the wrapper must not be escrowable.
    function test_revert_intentAssetMustMatchTokenOut() public {
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
        a.intent_d.publicAssetId = ASSET_C; // not tokenOut
        a.intent_d.recipient = ATTACKER_NOTE;

        vm.prank(SWAP_DRIVER);
        vm.expectRevert(abi.encodeWithSelector(SwapWrapper.MaspPullBelowMinOut.selector, 0, minOut));
        wrapper.swap(a);

        assertEq(tokenC.balanceOf(address(wrapper)), 5_000 * SCALE, "donated token C must stay put");
    }

    /// Escrowing less than the requested output, routing the remainder to the
    /// treasury as dust, must be rejected.
    function test_revert_intentCannotUnderEscrowOutput() public {
        uint256 grossIn = 1_000 * SCALE;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 actualOut = minOut + (minOut * FEE_BPS) / 10_000;

        tokenA.mint(address(pool), grossIn);
        tokenB.mint(address(adapter), actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _baseArgs(grossIn, minOut, minPublicIn);
        a.intent_d.publicIn = 1; // escrow a negligible amount, rest to treasury

        uint256 pulled = uint256(1) * SCALE;
        pulled += (pulled * FEE_BPS) / 10_000;

        vm.prank(SWAP_DRIVER);
        vm.expectRevert(abi.encodeWithSelector(SwapWrapper.MaspPullBelowMinOut.selector, pulled, minOut));
        wrapper.swap(a);
    }
}
