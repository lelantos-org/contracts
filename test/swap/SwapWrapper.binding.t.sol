// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { SwapIntent } from "./SwapIntent.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { SwapTestBase } from "./SwapTestBase.sol";
import { ScriptedBalanceToken } from "./mocks/ScriptedBalanceToken.sol";

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
    /// `test_intentHash_crossLanguageVector`'s expected hash.
    uint256 internal constant INTENT_VECTOR =
        17_537_988_237_215_357_429_810_858_075_676_193_989_150_518_723_851_377_084_809_783_452_071_645_726_238;

    MockERC20 internal tokenC;

    /// This suite needs a third asset to express a cross-asset binding attack.
    function _registerExtraAssets() internal override {
        tokenC = new MockERC20("Token C", "TKC", 18);
        pool.registerAsset(ASSET_C, address(tokenC), SCALE);
        wrapper.prepareToken(IERC20(address(tokenC)));
    }

    /// `_defaultSwapArgs` for a withdraw of `grossIn`, swapping all it nets and
    /// driven by `SWAP_DRIVER`. The originating proof names only the wrapper; no
    /// public input identifies the caller of `swap`.
    function _baseArgs(uint256 grossIn, uint256 minOut, uint64 depositIn)
        internal
        view
        returns (SwapWrapper.SwapArgs memory a)
    {
        a = _defaultSwapArgs(_netOfFee(grossIn), minOut, uint64(grossIn / SCALE), depositIn);
        a.pi_w.payer = SWAP_DRIVER;
        // This suite's output note has always left the fee-note commitment
        // unset; kept so the bound payloads its tests replay stay unchanged.
        a.deposit_d.feeCm = bytes32(0);
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

        SwapWrapper.SwapArgs memory a = SwapIntent.bind(_baseArgs(grossIn, minOut, minPublicIn));
        // Identical proof and public inputs; only the deposit changes.
        a.deposit_d.recipient = ATTACKER_NOTE;
        a.deposit_d.outCm = bytes32(uint256(0xA77ACC));

        vm.prank(address(0xDEADBEEF)); // arbitrary caller, not the victim
        vm.expectRevert(
            abi.encodeWithSelector(SwapWrapper.UnauthorizedSwapCaller.selector, address(0xDEADBEEF), a.pi_w.payer)
        );
        wrapper.swap(a);
    }

    /// The payer itself (a relayer's Bundler, and so any of its operators)
    /// cannot change what the proof committed to: the output and refund notes,
    /// their payloads, the floor, the output token, the deadline or the refund
    /// owner.
    function test_revert_payerCannotChangeTheIntent() public {
        uint256 grossIn = 1_000 * SCALE;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;

        for (uint256 field; field < 12; ++field) {
            SwapWrapper.SwapArgs memory a = SwapIntent.bind(_baseArgs(grossIn, minOut, minPublicIn));
            _tamper(a, field);

            vm.prank(SWAP_DRIVER);
            vm.expectRevert(SwapWrapper.IntentMismatch.selector);
            wrapper.swap(a);
        }
    }

    /// One field of the intent, rewritten as a malicious driver would. Every
    /// replacement still passes `_validate`'s other checks, so only the intent
    /// hash can reject it. The output token moves with its deposit asset, as the
    /// token binding would otherwise reject it first.
    function _tamper(SwapWrapper.SwapArgs memory a, uint256 field) internal view {
        if (field == 0) a.deposit_d.recipient = ATTACKER_NOTE;
        else if (field == 1) a.deposit_d.outCm = bytes32(uint256(0xA77ACC));
        else if (field == 2) a.minOut = 1;
        else if (field == 3) a.refundTo = address(0xBAD);
        else if (field == 4) a.deadline = a.deadline - 1;
        else if (field == 5) a.aux_d.ciphertext = hex"0bad";
        else if (field == 6) a.fee_aux_d.clueRx = 1;
        else if (field == 7) a.deposit_d.feeIn = 1;
        else if (field == 8) a.refund_d.recipient = ATTACKER_NOTE;
        else if (field == 9) a.refund_d.outCm = bytes32(uint256(0xA77ACC));
        else if (field == 10) a.refund_aux_d.ciphertext = hex"0bad";
        else (a.tokenOut, a.deposit_d.publicAssetId) = (address(tokenC), ASSET_C);
    }

    /// The contract's calldata encoding and the independent `memory` one in
    /// `SwapIntent` agree on non-empty payloads: a payload bound by the latter
    /// lands.
    function test_intentHash_contractAgreesWithIndependentEncoding() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 minOut = 990 * SCALE;
        uint256 actualOut = minOut + (minOut * FEE_BPS) / 10_000;
        tokenA.mint(address(pool), grossIn);
        tokenB.mint(address(adapter), actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _baseArgs(grossIn, minOut, 990);
        a.aux_d.ciphertext = hex"0102030405";
        a.fee_aux_d.ciphertext = hex"0607";

        vm.prank(SWAP_DRIVER);
        wrapper.swap(SwapIntent.bind(a));
    }

    /// Cross-language vector. The SDK (`swapIntentHash`) and the relayer
    /// (`swap_intent_hash`) pin the same literal payload to the same value; a
    /// change to the encoding must update all three.
    function test_intentHash_crossLanguageVector() public pure {
        SwapWrapper.SwapArgs memory a;
        a.refundTo = address(0x4EF0);
        a.tokenOut = address(0xB0B0);
        a.minOut = 990e10;
        a.adapter = address(0xADA7);
        a.deadline = 1_900_000_000;
        a.deposit_d.chainId = 31_337;
        a.deposit_d.publicAssetId = 2;
        a.deposit_d.publicIn = 990;
        a.deposit_d.payer = address(0x5A5A);
        a.deposit_d.recipient = address(0xBEEF);
        a.deposit_d.outCm = bytes32(uint256(1));
        a.deposit_d.cvDep = [uint256(2), 3];
        a.deposit_d.rcv = 4;
        a.deposit_d.feeAssetId = 2;
        a.deposit_d.feeIn = 5;
        a.deposit_d.feeCm = bytes32(uint256(6));
        a.deposit_d.feeCvDep = [uint256(7), 8];
        a.deposit_d.feeRcv = 9;
        a.aux_d = AuxValidation.Output({ clueRx: 10, clueRy: 11, ephPubX: 12, ephPubY: 13, ciphertext: hex"0102" });
        a.fee_aux_d =
            AuxValidation.Output({ clueRx: 14, clueRy: 15, ephPubX: 16, ephPubY: 17, ciphertext: hex"030405" });
        a.refund_d.chainId = 31_337;
        a.refund_d.publicAssetId = 1;
        a.refund_d.publicIn = 995;
        a.refund_d.payer = address(0x5A5A);
        a.refund_d.recipient = address(0xBEEF);
        a.refund_d.outCm = bytes32(uint256(0x12));
        a.refund_d.cvDep = [uint256(19), 20];
        a.refund_d.rcv = 21;
        a.refund_d.feeAssetId = 1;
        a.refund_d.feeIn = 22;
        a.refund_d.feeCm = bytes32(uint256(0x17));
        a.refund_d.feeCvDep = [uint256(24), 25];
        a.refund_d.feeRcv = 26;
        a.refund_aux_d = AuxValidation.Output({ clueRx: 27, clueRy: 28, ephPubX: 29, ephPubY: 30, ciphertext: hex"06" });
        a.refund_fee_aux_d =
            AuxValidation.Output({ clueRx: 31, clueRy: 32, ephPubX: 33, ephPubY: 34, ciphertext: hex"0708" });
        assertEq(SwapIntent.hash(a), INTENT_VECTOR, "cross-language vector");
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
        wrapper.swap(SwapIntent.bind(a));

        assertEq(pool.lastDepositRecipient(), VICTIM_NOTE, "output note recipient");
        assertEq(pool.lastDepositAssetId(), ASSET_B, "escrowed asset");
    }

    /// `deposit_d.publicAssetId` must denominate the pull in `tokenOut`. Any
    /// other token held by the wrapper must not be escrowable: `_validate`
    /// rejects the mismatched asset before leg 1, so no pull is attempted.
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
        vm.expectRevert(SwapWrapper.TokenOutMismatch.selector);
        wrapper.swap(SwapIntent.bind(a));

        assertEq(tokenC.balanceOf(address(wrapper)), 5_000 * SCALE, "donated token C must stay put");
    }

    // --- token binding --------------------------------------------------------

    /// The audit's sweep. The payer names a `tokenIn` whose `balanceOf` it
    /// scripts, `[0, 1, 1, 0, 0]`, with a passed deadline and a refund note in
    /// token C, which the wrapper holds and which `prepareToken` armed. Unbound,
    /// the venue leg fails `SwapExpired`, the refund escrows `refund_d` pulling
    /// the wrapper's real C while every bound and the leftover check read the
    /// script, and the attacker's note is minted from all of it. `tokenIn` is now
    /// bound to the withdraw proof's asset, so the swap reverts before leg 1.
    function test_revert_tokenInNotWithdrawAssetScriptedSweep() public {
        uint256 donated = 5_000 * SCALE;
        tokenC.mint(address(wrapper), donated);
        tokenA.mint(address(pool), SCALE);
        pool.setNextWithdrawAmount(SCALE);

        uint256[] memory script = new uint256[](5);
        (script[1], script[2]) = (1, 1);
        ScriptedBalanceToken fake = new ScriptedBalanceToken(script);

        SwapWrapper.SwapArgs memory a = _baseArgs(SCALE, SCALE, 1);
        a.tokenIn = address(fake);
        a.amountIn = 1;
        a.deadline = block.timestamp - 1;
        a.refund_d.publicAssetId = ASSET_C;
        a.refund_d.publicIn = uint64(donated / SCALE);
        a.refund_d.recipient = ATTACKER_NOTE;
        a.refundTo = SWAP_DRIVER;

        vm.prank(SWAP_DRIVER);
        vm.expectRevert(SwapWrapper.TokenInMismatch.selector);
        wrapper.swap(SwapIntent.bind(a));

        assertEq(tokenC.balanceOf(address(wrapper)), donated, "donated token C must stay put");
        assertEq(tokenC.balanceOf(address(pool)), 0, "no C escrowed");
    }

    /// `tokenOut` must be the registry token of the output note's asset. Any
    /// other token would make `actualOut`, the pull bounds and the leftover
    /// check measure a balance the pool never moves.
    function test_revert_tokenOutNotDepositAsset() public {
        SwapWrapper.SwapArgs memory a = _baseArgs(1_000 * SCALE, 990 * SCALE, 990);
        a.tokenOut = address(tokenC); // deposit_d stays in ASSET_B

        vm.prank(SWAP_DRIVER);
        vm.expectRevert(SwapWrapper.TokenOutMismatch.selector);
        wrapper.swap(SwapIntent.bind(a));
    }

    /// The refund note must be denominated in `tokenIn`: the refund pull is
    /// bounded by what leg 1 delivered in that token, so a refund in another
    /// token would escrow a balance the wrapper holds for someone else.
    function test_revert_refundAssetNotTokenIn() public {
        tokenC.mint(address(wrapper), 5_000 * SCALE);

        SwapWrapper.SwapArgs memory a = _baseArgs(1_000 * SCALE, 990 * SCALE, 990);
        a.refund_d.publicAssetId = ASSET_C;

        vm.prank(SWAP_DRIVER);
        vm.expectRevert(SwapWrapper.TokenInMismatch.selector);
        wrapper.swap(SwapIntent.bind(a));

        assertEq(tokenC.balanceOf(address(wrapper)), 5_000 * SCALE, "donated token C must stay put");
    }

    /// The refund binding compares tokens, not asset ids: a refund note under a
    /// second registry entry for `tokenIn` is accepted and the refund lands in it.
    function test_refundAssetMayDifferInIdButShareTokenIn() public {
        uint64 assetA2 = 4;
        pool.registerAsset(assetA2, address(tokenA), SCALE);

        uint256 grossIn = 1_000 * SCALE;
        tokenA.mint(address(pool), grossIn);
        pool.setNextWithdrawAmount(grossIn);

        SwapWrapper.SwapArgs memory a = _baseArgs(grossIn, 990 * SCALE, 990);
        a.deadline = block.timestamp - 1;
        a.refund_d.publicAssetId = assetA2;

        vm.prank(SWAP_DRIVER);
        vm.expectEmit(true, true, false, false, address(wrapper));
        emit SwapWrapper.SwapRefunded(address(adapter), address(tokenA), 0, 0, 0, SwapWrapper.SwapExpired.selector);
        (uint256 actualOut,) = wrapper.swap(SwapIntent.bind(a));

        assertEq(actualOut, 0, "nothing swapped");
        assertEq(pool.lastDepositAssetId(), assetA2, "refund escrowed under the second id");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "wrapper keeps no A");
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
        wrapper.swap(SwapIntent.bind(a));
    }
}
