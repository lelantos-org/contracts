// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { Groth16Verifier } from "../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC1271 } from "./mocks/MockERC1271.sol";

contract MASPCancelDepositTest is Test {
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);

    Groth16Verifier verifier;
    TreeUpdateBatchGroth16Verifier tubVerifier;
    address permit2;
    MockERC20 token;
    MASP masp;

    address payer = address(0xface);
    address recipient = address(0xb0b);
    address bystander = address(0xdead);
    /// Plain EOA payer — no code, so the permissionless cancel path applies.
    address eoaPayer = address(0xEA0A);

    function setUp() public {
        verifier = new Groth16Verifier();
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("M", "M", 18);

        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = ASSET_ID;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;

        masp = new MASP(
            IVerifier(address(verifier)),
            IVerifier(address(tubVerifier)),
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            FEE_BPS,
            TREASURY,
            OWNER
        );

        MockERC1271 stub = new MockERC1271();
        vm.etch(payer, address(stub).code);
    }

    function _aux() internal pure returns (AuxValidation.Output[3] memory aux) {
        aux[0].clueRx = BabyJubJub.BASE8_X;
        aux[0].clueRy = BabyJubJub.BASE8_Y;
        aux[0].ephPubX = BabyJubJub.BASE8_X;
        aux[0].ephPubY = BabyJubJub.BASE8_Y;
        aux[0].ciphertext = hex"0001";
        aux[1].clueRx = BabyJubJub.BASE8_X;
        aux[1].clueRy = BabyJubJub.BASE8_Y;
        aux[1].ephPubX = BabyJubJub.BASE8_X;
        aux[1].ephPubY = BabyJubJub.BASE8_Y;
        aux[1].ciphertext = hex"0001";
        aux[2].clueRx = BabyJubJub.BASE8_X;
        aux[2].clueRy = BabyJubJub.BASE8_Y;
        aux[2].ephPubX = BabyJubJub.BASE8_X;
        aux[2].ephPubY = BabyJubJub.BASE8_Y;
        aux[2].ciphertext = hex"0001";
    }

    uint256 private _nextNonce;

    struct _Preimage {
        uint48 publicIn;
        uint16 fbps;
        bytes32 cm;
        uint256[2] cvDep;
        uint32 submittedAt;
    }

    mapping(uint256 => _Preimage) internal _pre;

    function _submit(uint64 publicIn) internal returns (uint256 id, uint256 inAmt, uint256 fee) {
        inAmt = uint256(publicIn) * SCALE;
        fee = (inAmt * FEE_BPS) / 10_000;
        token.mint(payer, inAmt + fee);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);

        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = recipient;
        d.outCm = bytes32(uint256(0x111 + _nextNonce));

        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: _nextNonce++, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00"
        });

        id = masp.deposit(d, sig, _aux()[0]);
        _pre[id] = _Preimage({
            publicIn: uint48(publicIn), fbps: FEE_BPS, cm: d.outCm, cvDep: d.cvDep, submittedAt: uint32(block.number)
        });
    }

    /// Deposit with a codeless payer, via the standing-allowance path so no
    /// signature is needed. `deposit`'s fixture payer is an etched ERC-1271
    /// stub, which MASP classifies as a contract payer.
    function _submitEoa(uint64 publicIn) internal returns (uint256 id, uint256 inAmt, uint256 fee) {
        inAmt = uint256(publicIn) * SCALE;
        fee = (inAmt * FEE_BPS) / 10_000;
        token.mint(eoaPayer, inAmt + fee);

        vm.startPrank(eoaPayer);
        token.approve(address(permit2), type(uint256).max);
        IAllowanceTransfer(permit2).approve(address(token), address(masp), type(uint160).max, type(uint48).max);

        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = eoaPayer;
        d.recipient = recipient;
        d.outCm = bytes32(uint256(0x222 + _nextNonce++));
        id = masp.depositAuthorized(d, _aux()[0]);
        vm.stopPrank();

        _pre[id] = _Preimage({
            publicIn: uint48(publicIn), fbps: FEE_BPS, cm: d.outCm, cvDep: d.cvDep, submittedAt: uint32(block.number)
        });
    }

    function _cancelEoaAs(address caller, uint256 id) internal {
        _Preimage memory p = _pre[id];
        vm.prank(caller);
        masp.cancelDeposit(id, p.publicIn, p.cm, p.cvDep, ASSET_ID, p.fbps, eoaPayer, p.submittedAt);
    }

    /// The fixture payer is an etched ERC-1271 stub, so it has code and MASP
    /// treats it as a contract payer: only it may drive its own cancel.
    function _cancel(uint256 id) internal {
        _Preimage memory p = _pre[id];
        vm.prank(payer);
        masp.cancelDeposit(id, p.publicIn, p.cm, p.cvDep, ASSET_ID, p.fbps, payer, p.submittedAt);
    }

    // --- happy path --------------------------------------------------------

    function test_happy_refundsAfterDelay() public {
        (uint256 id, uint256 inAmt, uint256 fee) = _submit(100);
        uint256 total = inAmt + fee;

        // Advance past cancelDelay.
        vm.roll(block.number + masp.cancelDelay());

        uint256 payerBefore = token.balanceOf(payer);
        uint256 poolBefore = token.balanceOf(address(masp));

        _cancel(id);

        assertEq(token.balanceOf(payer) - payerBefore, total, "payer refunded gross");
        assertEq(poolBefore - token.balanceOf(address(masp)), total, "pool drained gross");
        assertEq(masp.accruedFee(IERC20(address(token))), 0, "no accrual to reverse; fees accrue at flush only");

        // Slot cleared.
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

    /// A contract payer is restricted to cancelling its own deposit: the coin
    /// returns to it, so it must be the one to observe the refund.
    function test_revert_contractPayer_thirdPartyCannotCancel() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _Preimage memory p = _pre[id];

        vm.prank(bystander);
        vm.expectRevert(MASP.PayerNotSender.selector);
        masp.cancelDeposit(id, p.publicIn, p.cm, p.cvDep, ASSET_ID, p.fbps, payer, p.submittedAt);
    }

    // --- reverts -----------------------------------------------------------

    function test_revert_CancelTooEarly() public {
        (uint256 id,,) = _submit(100);
        // No vm.roll → still in delay window.
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
        // Caller picks any preimage; contract reverts on empty slot before
        // touching the digest, so the choice does not matter.
        uint256[2] memory zCv;
        masp.cancelDeposit(999, 0, bytes32(0), zCv, 0, 0, address(0), 0);
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
        masp.cancelDeposit(id, p.publicIn, p.cm, p.cvDep, ASSET_ID, p.fbps, bystander, p.submittedAt);
    }

    function test_revert_DigestMismatch_wrongSubmittedAt() public {
        // A forged earlier submittedAt cannot bypass the delay: the digest
        // check runs before the delay check ever trusts the value.
        (uint256 id,,) = _submit(100);
        _Preimage memory p = _pre[id];
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.cancelDeposit(id, p.publicIn, p.cm, p.cvDep, ASSET_ID, p.fbps, payer, p.submittedAt - 1);
    }

    function test_revert_DigestMismatch_wrongFbps() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _Preimage memory p = _pre[id];
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.cancelDeposit(id, p.publicIn, p.cm, p.cvDep, ASSET_ID, p.fbps + 1, payer, p.submittedAt);
    }

    function test_revert_DigestMismatch_wrongAsset() public {
        (uint256 id,,) = _submit(100);
        vm.roll(block.number + masp.cancelDelay());
        _Preimage memory p = _pre[id];
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.cancelDeposit(id, p.publicIn, p.cm, p.cvDep, ASSET_ID + 1, p.fbps, payer, p.submittedAt);
    }

    // --- accounting invariant ---------------------------------------------

    function test_accruedFee_zeroThroughCancelLifecycle() public {
        (uint256 id,,) = _submit(100);
        // Nothing accrues at submit (fees accrue at flush only)...
        assertEq(masp.accruedFee(IERC20(address(token))), 0);

        vm.roll(block.number + masp.cancelDelay());
        _cancel(id);

        // ...and cancel has no fee bookkeeping to reverse.
        assertEq(masp.accruedFee(IERC20(address(token))), 0);
        assertEq(masp.sweep(IERC20(address(token))), 0, "nothing to sweep");
    }

    function test_sweep_unaffectedByCancel() public {
        // Two pending deposits; cancel the first. Neither ever accrued, so
        // sweep finds nothing and the second deposit's escrow stays whole.
        (uint256 id1,,) = _submit(100);
        (, uint256 inAmt2, uint256 fee2) = _submit(100);

        vm.roll(block.number + masp.cancelDelay());
        _cancel(id1);

        assertEq(masp.sweep(IERC20(address(token))), 0, "no accrual without flush");
        assertEq(token.balanceOf(address(masp)), inAmt2 + fee2, "second deposit's escrow (principal + fee) untouched");
    }
}
