// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { deployPoolUniform, realVerifierStack, singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";
import { FeeMath } from "../utils/FeeMath.sol";

/// `deposit` happy path and revert coverage. Permit2 signature acceptance is
/// stubbed via an ERC-1271 contract at the payer address (any signature bytes
/// are valid), so tests focus on contract-level invariants.
contract MASPDepositTest is Test {
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

    function setUp() public {
        (IVerifier tub, IBatchVerifier bv, ISignatureTransfer p2) = realVerifierStack();
        permit2 = address(p2);
        token = new MockERC20("M", "M", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        masp = deployPoolUniform(tub, bv, p2, ids, tokens, scales, FEE_BPS, TREASURY, OWNER);

        Stubs.installPermissiveERC1271(payer);
    }

    function _request(uint64 publicIn) internal view returns (PubInputs.DepositRequest memory) {
        return DepositFixture.request(ASSET_ID, publicIn, payer, recipient, bytes32(uint256(0xdead)));
    }

    function _fund(uint64 publicIn) internal returns (uint256 inAmt, uint256 fee) {
        inAmt = uint256(publicIn) * SCALE;
        fee = FeeMath.fee(inAmt, FEE_BPS);
        token.mint(payer, inAmt + fee);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);
    }

    function _sig(uint256 maxTotal) internal pure returns (MASP.Permit2Sig memory) {
        return DepositFixture.sig(0, maxTotal, 0);
    }

    // --- happy path --------------------------------------------------------

    function test_happy_pullsFundsAndEscrows() public {
        uint64 publicIn = 100;
        (uint256 inAmt, uint256 fee) = _fund(publicIn);
        uint256 total = inAmt + fee;

        PubInputs.DepositRequest memory d = _request(publicIn);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();

        uint256 poolBefore = token.balanceOf(address(masp));
        uint256 payerBefore = token.balanceOf(payer);

        uint256 id = masp.deposit(d, _sig(total), aux[0], aux[1]);

        assertEq(id, 0, "first id");
        assertEq(token.balanceOf(address(masp)) - poolBefore, total, "pool gross");
        assertEq(payerBefore - token.balanceOf(payer), total, "payer debited");
        assertEq(masp.accruedFee(IERC20(address(token))), 0, "no accrual at submit; fee accrues at flush");
        assertEq(masp.nextDepositId(), 1, "nextDepositId bumped");

        // Escrow slot: a single digest binds the full preimage, including payer
        // and submit block.
        bytes32 expectedDigest = keccak256(
            abi.encode(
                address(masp),
                block.chainid,
                id,
                d.outCm,
                d.cvDep,
                uint64(ASSET_ID),
                uint48(publicIn),
                uint16(FEE_BPS),
                payer,
                uint32(block.number),
                // The relayer's leaf is bound too, so a flusher cannot mint
                // itself a different fee note than the payer funded.
                uint48(d.feeIn),
                uint64(d.feeAssetId),
                d.feeCm,
                d.feeCvDep
            )
        );
        assertEq(masp.escrowed(id), expectedDigest, "digest binds full preimage");
    }

    function test_happy_idsMonotonic() public {
        uint64 publicIn = 50;
        _fund(publicIn);
        _fund(publicIn); // second deposit's funds
        PubInputs.DepositRequest memory d = _request(publicIn);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        MASP.Permit2Sig memory s1 = DepositFixture.sig(0);
        MASP.Permit2Sig memory s2 = DepositFixture.sig(1);

        uint256 a = masp.deposit(d, s1, aux[0], aux[1]);
        uint256 b = masp.deposit(d, s2, aux[0], aux[1]);
        assertEq(a, 0);
        assertEq(b, 1);
    }

    function test_happy_sweep_nothingAccruedAtSubmit() public {
        uint64 publicIn = 100;
        _fund(publicIn);
        masp.deposit(
            _request(publicIn), _sig(type(uint256).max), SpendFixture.validAux()[0], SpendFixture.validAux()[1]
        );

        // Fees accrue only at flush, so a submit leaves nothing to sweep;
        // escrowed principal and fee stay out of `accruedFee`.
        uint256 swept = masp.sweep(IERC20(address(token)));
        assertEq(swept, 0, "nothing accrued");
        assertEq(masp.accruedFee(IERC20(address(token))), 0);
    }

    // --- reverts -----------------------------------------------------------

    function test_revert_BadChainId() public {
        _fund(100);
        PubInputs.DepositRequest memory d = _request(100);
        d.chainId = block.chainid + 1;
        vm.expectRevert(MASP.BadChainId.selector);
        masp.deposit(d, _sig(type(uint256).max), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
    }

    function test_revert_MustHaveDeposit() public {
        PubInputs.DepositRequest memory d = _request(0);
        vm.expectRevert(MASP.MustHaveDeposit.selector);
        masp.deposit(d, _sig(type(uint256).max), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
    }

    function test_revert_PublicInTooLarge() public {
        // 2^48 exceeds uint48 max
        PubInputs.DepositRequest memory d = _request(0);
        d.publicIn = uint64(uint256(type(uint48).max) + 1);
        vm.expectRevert(MASP.PublicInTooLarge.selector);
        masp.deposit(d, _sig(type(uint256).max), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
    }

    function test_revert_ZeroPayer() public {
        PubInputs.DepositRequest memory d = _request(100);
        d.payer = address(0);
        vm.expectRevert(MASP.ZeroPayer.selector);
        masp.deposit(d, _sig(type(uint256).max), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
    }

    function test_revert_ZeroRecipient() public {
        PubInputs.DepositRequest memory d = _request(100);
        d.recipient = address(0);
        vm.expectRevert(MASP.ZeroRecipient.selector);
        masp.deposit(d, _sig(type(uint256).max), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
    }

    function test_revert_ZeroCm() public {
        PubInputs.DepositRequest memory d = _request(100);
        // Zero principal commitment with a non-zero fee commitment, so `outCm`
        // alone triggers the check.
        d.outCm = bytes32(0);
        d.feeCm = bytes32(uint256(0xfee));
        vm.expectRevert(MASP.ZeroCm.selector);
        masp.deposit(d, _sig(type(uint256).max), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
    }

    function test_revert_UnknownAsset() public {
        PubInputs.DepositRequest memory d = _request(100);
        d.publicAssetId = 999;
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, 999));
        masp.deposit(d, _sig(type(uint256).max), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
    }

    // --- admin / cancelDelay -----------------------------------------------

    function test_setCancelDelay_owner_rejectsBelowMin() public {
        vm.prank(OWNER);
        vm.expectRevert(MASP.BadCancelDelay.selector);
        masp.setCancelDelay(3_599);
    }

    function test_setCancelDelay_owner_rejectsAboveMax() public {
        vm.prank(OWNER);
        vm.expectRevert(MASP.BadCancelDelay.selector);
        masp.setCancelDelay(50_401);
    }

    /// Shortening the delay only frees escrowed funds sooner, so it applies at
    /// once.
    function test_setCancelDelay_owner_setsValid() public {
        vm.expectEmit(address(masp));
        emit MASP.CancelDelayUpdated(7_200, 5_000);
        vm.prank(OWNER);
        masp.setCancelDelay(5_000);
        assertEq(masp.cancelDelay(), 5_000);
    }

    /// Lengthening it would extend the lock on every escrow in flight, so it is
    /// queued and lands only at the commit, after the notice.
    function test_setCancelDelay_raiseIsQueuedUntilCommitted() public {
        uint256 due = vm.getBlockTimestamp() + ExitTerms.DELAY;
        vm.expectEmit(address(masp));
        emit ExitTerms.ExitTermRaisePending(0, ExitTerms.CANCEL_DELAY, 10_000, due);
        vm.prank(OWNER);
        masp.setCancelDelay(10_000);
        assertEq(masp.cancelDelay(), 7_200, "raise applied without notice");

        vm.warp(due - 1);
        vm.expectRevert(abi.encodeWithSelector(ExitTerms.RaiseNotDue.selector, due));
        masp.commitExitTerms(ASSET_ID);

        vm.warp(due);
        vm.expectEmit(address(masp));
        emit MASP.CancelDelayUpdated(7_200, 10_000);
        masp.commitExitTerms(ASSET_ID);
        assertEq(masp.cancelDelay(), 10_000);
    }

    /// The delay is pool-wide, so any id's commit carries it, registered or not.
    function test_setCancelDelay_raiseCommitsThroughAnyId() public {
        vm.prank(OWNER);
        masp.setCancelDelay(10_000);
        vm.warp(vm.getBlockTimestamp() + ExitTerms.DELAY);
        masp.commitExitTerms(999);
        assertEq(masp.cancelDelay(), 10_000);
    }

    /// Shortening drops a queued lengthening, which then cannot be committed.
    function test_setCancelDelay_decreaseIsImmediateAndCancelsPendingRaise() public {
        vm.startPrank(OWNER);
        masp.setCancelDelay(10_000);
        masp.setCancelDelay(4_000);
        vm.stopPrank();
        assertEq(masp.cancelDelay(), 4_000);

        vm.warp(vm.getBlockTimestamp() + ExitTerms.DELAY);
        vm.expectRevert(ExitTerms.NoPendingRaise.selector);
        masp.commitExitTerms(ASSET_ID);
        assertEq(masp.cancelDelay(), 4_000);
    }

    function test_setCancelDelay_nonOwner_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        masp.setCancelDelay(7_200);
    }

    // --- relayer fee note ---------------------------------------------------

    /// The relayer's leg is charged on top of principal and treasury fee, so
    /// the payer funds it and treasury revenue is untouched.
    function test_happy_relayerFeeChargedOnTopOfPrincipalAndFee() public {
        uint64 publicIn = 100;
        uint64 feeIn = 7;
        uint256 relayerAmt = uint256(feeIn) * SCALE;
        (uint256 inAmt, uint256 fee) = _fund(publicIn);
        token.mint(payer, relayerAmt);

        PubInputs.DepositRequest memory d = _request(publicIn);
        d.feeIn = feeIn;
        d.feeAssetId = ASSET_ID;
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();

        uint256 payerBefore = token.balanceOf(payer);
        uint256 poolBefore = token.balanceOf(address(masp));
        masp.deposit(d, _sig(inAmt + fee + relayerAmt), aux[0], aux[1]);

        uint256 total = inAmt + fee + relayerAmt;
        assertEq(payerBefore - token.balanceOf(payer), total, "payer funds the relayer's note too");
        assertEq(token.balanceOf(address(masp)) - poolBefore, total, "pool holds the tokens backing both leaves");
        assertEq(masp.accruedFee(IERC20(address(token))), 0, "relayer amount is not treasury revenue");
    }

    /// `_drainDeposit` narrows `feeIn` to `uint48` for the digest, the same way
    /// it does `publicIn`, so the submit path range-checks it the same way.
    function test_revert_PublicInTooLarge_feeIn() public {
        PubInputs.DepositRequest memory d = _request(100);
        d.feeIn = uint64(uint256(type(uint48).max) + 1);
        vm.expectRevert(MASP.PublicInTooLarge.selector);
        masp.deposit(d, _sig(type(uint256).max), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
    }

    /// A deposit mints two leaves, so the fee leaf's commitment gets the same
    /// well-formedness check as the principal's. `feeIn` stays zero here: a
    /// subsidised deployment still mints the leaf, so the guard fires on
    /// shape alone, not on value.
    function test_revert_ZeroCm_feeCm() public {
        PubInputs.DepositRequest memory d = _request(100);
        d.feeCm = bytes32(0);
        vm.expectRevert(MASP.ZeroCm.selector);
        masp.deposit(d, _sig(type(uint256).max), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
    }

    /// Both aux payloads are validated. The two arguments are interchangeable in
    /// every other test, so a swapped or dropped `feeAux` check would otherwise
    /// go undetected and publish an unvalidated payload to the event.
    ///
    /// Each case takes its payload from a fresh `SpendFixture.validAux()`: a memory struct is a
    /// reference, so reusing one would carry the previous mutation forward.
    function test_revert_feeAuxValidatedIndependently() public {
        _fund(100);
        PubInputs.DepositRequest memory d = _request(100);

        AuxValidation.Output memory badFee = SpendFixture.validAux()[1];
        badFee.ciphertext = hex"";
        vm.expectRevert(AuxValidation.CiphertextTooShort.selector);
        masp.deposit(d, _sig(type(uint256).max), SpendFixture.validAux()[0], badFee);

        // Off-curve ephemeral key in the fee payload, principal payload intact.
        badFee = SpendFixture.validAux()[1];
        badFee.ephPubX = 1;
        badFee.ephPubY = 1;
        vm.expectRevert(AuxValidation.OffCurvePoint.selector);
        masp.deposit(d, _sig(type(uint256).max), SpendFixture.validAux()[0], badFee);
    }
}
