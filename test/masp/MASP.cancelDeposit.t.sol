// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { deployPoolUniform, realVerifierStack, singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";
import { FeeMath } from "../utils/FeeMath.sol";

contract MASPCancelDepositTest is Test {
    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant TREASURY = TestConstants.TREASURY;
    address internal constant OWNER = TestConstants.OWNER;
    address permit2;
    MockERC20 token;
    MASP masp;

    address payer = TestConstants.ESCROW_PAYER;
    address recipient = address(0xb0b);
    address bystander = address(0xdead);
    /// EOA payer with no code, so the permissionless cancel path applies.
    address eoaPayer = address(0xEA0A);

    function setUp() public {
        (IVerifier tub, IBatchVerifier bv, ISignatureTransfer p2) = realVerifierStack();
        permit2 = address(p2);
        token = new MockERC20("M", "M", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        masp = deployPoolUniform(tub, bv, p2, ids, tokens, scales, FEE_BPS, TREASURY, OWNER);

        Stubs.installPermissiveERC1271(payer);
    }

    uint256 private _nextNonce;

    struct _Preimage {
        uint48 publicIn;
        uint16 fbps;
        bytes32 inner;
        uint32 submittedAt;
    }

    mapping(uint256 => _Preimage) internal _pre;

    function _submit(uint64 publicIn) internal returns (uint256 id, uint256 inAmt, uint256 fee) {
        inAmt = uint256(publicIn) * SCALE;
        fee = FeeMath.fee(inAmt, FEE_BPS);
        token.mint(payer, inAmt + fee);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);

        PubInputs.DepositRequest memory d =
            DepositFixture.request(ASSET_ID, publicIn, payer, recipient, bytes32(uint256(0x111 + _nextNonce)));
        MASP.Permit2Sig memory sig = DepositFixture.sig(_nextNonce++);

        id = masp.deposit(d, sig, SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
        _pre[id] =
            _Preimage({ publicIn: uint48(publicIn), fbps: FEE_BPS, inner: d.inner, submittedAt: uint32(block.number) });
    }

    /// Deposits with a codeless payer via the standing-allowance path, so no
    /// signature is needed. `deposit`'s fixture payer is an etched ERC-1271
    /// stub, which MASP classifies as a contract payer.
    function _submitEoa(uint64 publicIn) internal returns (uint256 id, uint256 inAmt, uint256 fee) {
        inAmt = uint256(publicIn) * SCALE;
        fee = FeeMath.fee(inAmt, FEE_BPS);
        token.mint(eoaPayer, inAmt + fee);

        vm.startPrank(eoaPayer);
        token.approve(address(permit2), type(uint256).max);
        IAllowanceTransfer(permit2).approve(address(token), address(masp), type(uint160).max, type(uint48).max);

        PubInputs.DepositRequest memory d =
            DepositFixture.request(ASSET_ID, publicIn, eoaPayer, recipient, bytes32(uint256(0x222 + _nextNonce++)));
        id = masp.depositAuthorized(d, SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
        vm.stopPrank();

        _pre[id] =
            _Preimage({ publicIn: uint48(publicIn), fbps: FEE_BPS, inner: d.inner, submittedAt: uint32(block.number) });
    }

    function _cancelEoaAs(address caller, uint256 id) internal {
        _Preimage memory p = _pre[id];
        vm.prank(caller);
        masp.cancelDeposit(
            id, p.publicIn, p.inner, ASSET_ID, p.fbps, eoaPayer, p.submittedAt, DepositFixture.feeNote(), 0
        );
    }

    /// The fixture payer is an etched ERC-1271 stub, so it has code and MASP
    /// treats it as a contract payer: only it may drive its own cancel.
    function _cancel(uint256 id) internal {
        _Preimage memory p = _pre[id];
        vm.prank(payer);
        masp.cancelDeposit(id, p.publicIn, p.inner, ASSET_ID, p.fbps, payer, p.submittedAt, DepositFixture.feeNote(), 0);
    }

    // --- happy path --------------------------------------------------------

    function test_happy_refundsAfterDelay() public {
        (uint256 id, uint256 inAmt, uint256 fee) = _submit(100);
        uint256 total = inAmt + fee;

        vm.roll(block.number + masp.cancelDelay());

        uint256 payerBefore = token.balanceOf(payer);
        uint256 poolBefore = token.balanceOf(address(masp));

        _cancel(id);

        assertEq(token.balanceOf(payer) - payerBefore, total, "payer refunded gross");
        assertEq(poolBefore - token.balanceOf(address(masp)), total, "pool drained gross");
        assertEq(masp.accruedFee(IERC20(address(token))), 0, "no accrual to reverse; fees accrue at flush only");

        assertEq(masp.escrowed(id), bytes32(0), "slot cleared");
    }

    /// An EOA payer keeps the permissionless rescue: a bystander may cancel,
    /// and the refund still goes to the digest-bound payer, not the caller.
    /// `deposit` is signature-based, so such a payer may never send a
    /// transaction of its own.
    function test_happy_eoaPayer_anyoneMayCancel_refundGoesToPayer() public {
        (uint256 id, uint256 inAmt, uint256 fee) = _submitEoa(100);
        uint256 total = inAmt + fee;
        vm.roll(block.number + masp.cancelDelay());

        uint256 bystanderBefore = token.balanceOf(bystander);
        _cancelEoaAs(bystander, id);

        assertEq(token.balanceOf(bystander), bystanderBefore, "bystander gets nothing");
        assertEq(token.balanceOf(eoaPayer), total, "payer gets refund");
    }

    /// Only a contract payer may cancel its own deposit: the refund returns to
    /// it, so it must be the caller that observes the refund.
    function test_revert_contractPayer_thirdPartyCannotCancel() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _Preimage memory p = _pre[id];

        vm.prank(bystander);
        vm.expectRevert(MASP.PayerNotSender.selector);
        masp.cancelDeposit(id, p.publicIn, p.inner, ASSET_ID, p.fbps, payer, p.submittedAt, DepositFixture.feeNote(), 0);
    }

    // --- reverts -----------------------------------------------------------

    function test_revert_CancelTooEarly() public {
        (uint256 id,,) = _submit(100);
        // No vm.roll, so still inside the delay window.
        uint256 expectedUnlock = block.number + masp.cancelDelay();
        vm.expectRevert(abi.encodeWithSelector(MASP.CancelTooEarly.selector, id, expectedUnlock));
        _cancel(id);
    }

    function test_revert_atExactBoundary_oneBlockShort() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay() - 1);
        uint256 expectedUnlock = block.number + 1;
        vm.expectRevert(abi.encodeWithSelector(MASP.CancelTooEarly.selector, id, expectedUnlock));
        _cancel(id);
    }

    function test_acceptsAtExactUnlock() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _cancel(id); // does not revert
    }

    function test_revert_DepositNotPending_unknownId() public {
        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, 999));
        // Any preimage works: the contract reverts on the empty slot before
        // checking the digest.
        masp.cancelDeposit(
            999,
            0,
            bytes32(0),
            0,
            0,
            address(0),
            0,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeInner: bytes32(0) }),
            0
        );
    }

    function test_revert_replayCancel() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _cancel(id);

        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, id));
        _cancel(id);
    }

    // --- digest binding ------------------------------------------------------

    function test_revert_DigestMismatch_wrongPayer() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _Preimage memory p = _pre[id];
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.cancelDeposit(
            id, p.publicIn, p.inner, ASSET_ID, p.fbps, bystander, p.submittedAt, DepositFixture.feeNote(), 0
        );
    }

    function test_revert_DigestMismatch_wrongSubmittedAt() public {
        // A forged earlier submittedAt cannot bypass the delay: the digest
        // check runs before the delay check reads the value.
        (uint256 id,,) = _submit(100);
        _Preimage memory p = _pre[id];
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.cancelDeposit(
            id, p.publicIn, p.inner, ASSET_ID, p.fbps, payer, p.submittedAt - 1, DepositFixture.feeNote(), 0
        );
    }

    function test_revert_DigestMismatch_wrongFbps() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _Preimage memory p = _pre[id];
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.cancelDeposit(
            id, p.publicIn, p.inner, ASSET_ID, p.fbps + 1, payer, p.submittedAt, DepositFixture.feeNote(), 0
        );
    }

    function test_revert_DigestMismatch_wrongAsset() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _Preimage memory p = _pre[id];
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.cancelDeposit(
            id, p.publicIn, p.inner, ASSET_ID + 1, p.fbps, payer, p.submittedAt, DepositFixture.feeNote(), 0
        );
    }

    /// The note's `inner` is part of the preimage: it is one of the three words
    /// the batch circuit builds the leaf from, so a canceller cannot stand in
    /// another note for the one escrowed.
    function test_revert_DigestMismatch_wrongInner() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _Preimage memory p = _pre[id];
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.cancelDeposit(
            id,
            p.publicIn,
            bytes32(uint256(p.inner) + 1),
            ASSET_ID,
            p.fbps,
            payer,
            p.submittedAt,
            DepositFixture.feeNote(),
            0
        );
    }

    /// The amount is the second of those words, and what the refund is
    /// computed from: naming a larger one cannot drain the pool.
    function test_revert_DigestMismatch_wrongPublicIn() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _Preimage memory p = _pre[id];
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.cancelDeposit(
            id, p.publicIn + 1, p.inner, ASSET_ID, p.fbps, payer, p.submittedAt, DepositFixture.feeNote(), 0
        );
    }

    /// The relayer's note is bound word for word, like the depositor's: its
    /// `inner`, its amount and its asset. Each is tampered alone.
    function test_revert_DigestMismatch_wrongFeeNote() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _Preimage memory p = _pre[id];

        PubInputs.FeeNote[3] memory wrong;
        wrong[0] = DepositFixture.feeNote();
        wrong[0].feeInner = bytes32(uint256(wrong[0].feeInner) + 1);
        wrong[1] = DepositFixture.feeNote();
        wrong[1].feeIn = 1;
        wrong[2] = DepositFixture.feeNote();
        wrong[2].feeAssetId = ASSET_ID;

        for (uint256 k; k < wrong.length; ++k) {
            vm.prank(payer);
            vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
            masp.cancelDeposit(id, p.publicIn, p.inner, ASSET_ID, p.fbps, payer, p.submittedAt, wrong[k], 0);
        }

        // The untampered preimage still cancels: none of the attempts above
        // consumed the escrow.
        _cancel(id);
        assertEq(masp.escrowed(id), bytes32(0), "slot cleared");
    }

    /// The refund cap is part of the preimage. A plain escrow is submitted
    /// with none, so naming one is a different preimage.
    function test_revert_DigestMismatch_wrongPulled() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _Preimage memory p = _pre[id];
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.cancelDeposit(id, p.publicIn, p.inner, ASSET_ID, p.fbps, payer, p.submittedAt, DepositFixture.feeNote(), 1);
    }

    // --- accounting invariant ---------------------------------------------

    function test_accruedFee_zeroThroughCancelLifecycle() public {
        (uint256 id,,) = _submit(100);
        // Nothing accrues at submit: fees accrue at flush only.
        assertEq(masp.accruedFee(IERC20(address(token))), 0);

        vm.roll(block.number + masp.cancelDelay());
        _cancel(id);

        // Cancel has no fee bookkeeping to reverse.
        assertEq(masp.accruedFee(IERC20(address(token))), 0);
        assertEq(masp.sweep(IERC20(address(token))), 0, "nothing to sweep");
    }

    function test_sweep_unaffectedByCancel() public {
        // Two pending deposits; the first is cancelled. Neither accrued, so
        // sweep finds nothing and the second deposit's escrow is intact.
        (uint256 id1,,) = _submit(100);
        (, uint256 inAmt2, uint256 fee2) = _submit(100);

        vm.roll(block.number + masp.cancelDelay());
        _cancel(id1);

        assertEq(masp.sweep(IERC20(address(token))), 0, "no accrual without flush");
        assertEq(token.balanceOf(address(masp)), inAmt2 + fee2, "second deposit's escrow (principal + fee) untouched");
    }
}
