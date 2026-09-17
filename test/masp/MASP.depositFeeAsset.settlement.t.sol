// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { Fees } from "../../src/libs/Fees.sol";

import { DepositFeeAssetTestBase } from "./DepositFeeAssetTestBase.sol";

/// Cross-asset relayer fee after submit: flush binds the fee leaf to
/// `feeAssetId`, and cancel refunds the note in its own token, exactly across
/// fee-asset scales. Fixture and helpers in `DepositFeeAssetTestBase`.
contract MASPDepositFeeAssetSettlementTest is DepositFeeAssetTestBase {
    // --- flush --------------------------------------------------------------

    /// Flush binds the fee leaf to the submitted `feeAssetId` and accrues only
    /// the principal's treasury fee; the fee token stays as backing.
    function test_flush_crossAsset_settles() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, FEE_ID, 0x700);

        vm.expectEmit(address(masp));
        emit MASP.DepositFlushed(id, d.outCm);
        _flush(id, _tpi(d, FEE_ID), submittedAt);

        assertEq(masp.escrowed(id), bytes32(0), "escrow drained");
        uint256 inAmt = uint256(PUBLIC_IN) * SCALE;
        assertEq(masp.accruedFee(IERC20(address(token))), (inAmt * FEE_BPS) / 10_000, "treasury fee in token");
        assertEq(masp.accruedFee(IERC20(address(feeToken))), 0, "nothing accrued in the fee token");
        assertEq(feeToken.balanceOf(address(masp)), _feeTokenPull(), "fee token backs the relayer note");
    }

    /// A yield principal's flush settles its unit fee alone; the plain note in
    /// another token touches neither yield book.
    function test_flush_yieldPrincipal_plainFee() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(YIELD_ID, FEE_ID, 0x780);

        _flush(id, _tpi(d, FEE_ID), submittedAt);

        uint256 unitFee = Fees.unitFee(PUBLIC_IN, FEE_BPS);
        assertEq(masp.yieldState(YIELD_ID).totalNormalized, PUBLIC_IN, "principal units remain");
        assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, unitFee, "unit fee moved to the treasury");
        assertEq(masp.accruedFee(IERC20(address(feeToken))), 0, "nothing accrued in the fee token");
        assertEq(feeToken.balanceOf(address(masp)), _feeTokenPull(), "fee token backs the relayer note");
    }

    /// A flusher naming any other asset for the fee leaf reconstructs a
    /// different digest: the deposit asset, asset 0, or another registered one.
    function test_revert_flush_feeLeafAssetTampered() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, FEE_ID, 0x700);
        uint64[3] memory wrong = [PLAIN_ID, uint64(0), DISABLED_ID];
        for (uint256 k = 0; k < wrong.length; ++k) {
            PubInputs.TreeUpdateBatch memory tpi = _tpi(d, wrong[k]);
            vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
            _flush(id, tpi, submittedAt);
        }
    }

    // --- cancel -------------------------------------------------------------

    /// A two-token escrow refunds in both tokens, the relayer note separately,
    /// and leaves the pool holding neither.
    function test_cancel_crossAsset_refundsBothTokens() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, FEE_ID, 0x800);
        _passCancelDelay(submittedAt);
        uint256 tokenBefore = token.balanceOf(payer);
        uint256 feeBefore = feeToken.balanceOf(payer);

        vm.expectEmit(address(masp));
        emit MASP.DepositCanceled(id, payer, _principalPull(PUBLIC_IN), FEE_ID, _feeTokenPull());
        (uint256 refunded, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(refunded, _principalPull(PUBLIC_IN), "principal refund excludes the note");
        assertEq(feeRefunded, _feeTokenPull(), "note refunded in its own token");
        assertEq(token.balanceOf(payer) - tokenBefore, refunded, "token delivered");
        assertEq(feeToken.balanceOf(payer) - feeBefore, feeRefunded, "fee token delivered");
        assertEq(token.balanceOf(address(masp)), 0, "no token left behind");
        assertEq(feeToken.balanceOf(address(masp)), 0, "no fee token left behind");
        assertEq(masp.escrowed(id), bytes32(0), "escrow cleared");
    }

    /// Disabling the fee asset after submit does not strand the escrow.
    function test_cancel_crossAsset_afterFeeAssetDisabled() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, FEE_ID, 0x880);
        _passCancelDelay(submittedAt);
        vm.prank(OWNER);
        masp.setAssetDisabled(FEE_ID, true);

        (, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(feeRefunded, _feeTokenPull(), "note refunded");
        assertEq(feeToken.balanceOf(address(masp)), 0, "no fee token left behind");
    }

    /// The single-token cancel pays one refund; `feeRefunded` is zero.
    function test_cancel_sameAsset_singleRefund() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, PLAIN_ID, 0x900);
        _passCancelDelay(submittedAt);
        uint256 total = _principalPull(PUBLIC_IN) + uint256(FEE_IN) * SCALE;
        uint256 feeBefore = feeToken.balanceOf(payer);

        vm.expectEmit(address(masp));
        emit MASP.DepositCanceled(id, payer, total, PLAIN_ID, 0);
        (uint256 refunded, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(refunded, total, "whole pull in one token");
        assertEq(feeRefunded, 0, "no second refund");
        assertEq(feeToken.balanceOf(payer), feeBefore, "fee token untouched");
    }

    /// Cancel resupplies `feeAssetId`; any other value mismatches the digest.
    function test_revert_cancel_feeAssetTampered() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, FEE_ID, 0xa00);
        _passCancelDelay(submittedAt);
        d.feeAssetId = PLAIN_ID;
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        _cancel(d, id, submittedAt);
    }

    /// A yield principal refunds through `YieldOps.cancel` with no note units,
    /// capped at its principal pull; the plain note refunds its fixed value.
    function test_cancel_yieldPrincipal_plainFee() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(YIELD_ID, FEE_ID, 0xb00);
        _passCancelDelay(submittedAt);
        uint256 feeBefore = feeToken.balanceOf(payer);

        vm.expectEmit(address(masp));
        emit MASP.DepositCanceled(id, payer, _yieldPrincipalPull(PUBLIC_IN), FEE_ID, _feeTokenPull());
        (uint256 refunded, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(refunded, _yieldPrincipalPull(PUBLIC_IN), "principal refund at a flat index");
        assertEq(feeRefunded, _feeTokenPull(), "plain note refunded in the fee token");
        assertEq(feeToken.balanceOf(payer) - feeBefore, _feeTokenPull(), "fee token delivered");
        assertEq(masp.yieldState(YIELD_ID).totalNormalized, 0, "every unit burned");
    }

    // --- pricing across scales ----------------------------------------------

    /// For any amounts and fee-asset scale, the two-token path pulls exactly
    /// `inAmt + fee` of the deposit token and `feeIn * feeScale` of the fee
    /// token, and cancel returns exactly those amounts.
    function testFuzz_crossAsset_pullAndRefundExact(uint64 publicIn, uint64 feeIn, uint256 feeScale) public {
        publicIn = uint64(bound(publicIn, 1, type(uint48).max));
        feeIn = uint64(bound(feeIn, 1, type(uint48).max));
        feeScale = bound(feeScale, 1, 1e18);
        vm.prank(OWNER);
        masp.addAsset(FUZZ_FEE_ID, IERC20(address(feeToken)), feeScale, FEE_BPS, FEE_BPS);

        _fund(payer);
        _allowBoth(payer, type(uint160).max, type(uint160).max);
        PubInputs.DepositRequest memory d = _requestPaying(payer, PLAIN_ID, FUZZ_FEE_ID, 0xd00);
        d.publicIn = publicIn;
        d.feeIn = feeIn;
        uint32 submittedAt = uint32(vm.getBlockNumber());
        uint256 tokenBefore = token.balanceOf(payer);
        uint256 feeBefore = feeToken.balanceOf(payer);

        uint256 id = _depositAuthorized(d);

        uint256 feePull = uint256(feeIn) * feeScale;
        assertEq(tokenBefore - token.balanceOf(payer), _principalPull(publicIn), "deposit token pull");
        assertEq(feeBefore - feeToken.balanceOf(payer), feePull, "fee token pull");

        _passCancelDelay(submittedAt);
        (uint256 refunded, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(refunded, _principalPull(publicIn), "deposit token refund");
        assertEq(feeRefunded, feePull, "fee token refund");
        assertEq(token.balanceOf(payer), tokenBefore, "payer whole in token");
        assertEq(feeToken.balanceOf(payer), feeBefore, "payer whole in fee token");
    }
}
