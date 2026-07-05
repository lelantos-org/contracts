// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { NullifierSet } from "../src/NullifierSet.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// Spend-path (`transfer`, `withdraw`) request-validation negative tests.
/// Each test tampers with exactly one field to reach a specific revert.
/// All checks tested here fire inside `_validateRequest`, before SNARK
/// verification — no mocked verifier needed.
contract MASPSpendGuardsTest is Test {
    address internal constant RELAYER = address(0xCA11);
    address internal constant PAYER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xF00D);

    MASP masp;

    function setUp() public {
        IVerifier v = IVerifier(address(new MockERC20("v", "v", 18)));
        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        address permit2 = new DeployPermit2().deployPermit2();
        masp = new MASP(
            v,
            tub,
            ISignatureTransfer(address(permit2)),
            IWrappedNative(address(0)),
            new uint64[](0),
            new IERC20[](0),
            new uint256[](0),
            0,
            address(0xfee),
            address(this)
        );
    }

    // --- helpers -----------------------------------------------------------

    function _pi() internal view returns (PubInputs.Transact memory pi) {
        pi.chainId = block.chainid;
        pi.recipient = RECIPIENT;
        pi.payer = PAYER;
        pi.relayer = RELAYER;
        pi.nullifier[0] = bytes32(uint256(1));
        pi.nullifier[1] = bytes32(uint256(2));
        pi.outCm[0] = bytes32(uint256(3));
        pi.outCm[1] = bytes32(uint256(4));
        pi.merkleRoot = masp.currentRoot();
        // outCvDep: all zero → matches tpi.cvDeps default
    }

    function _tpi(PubInputs.Transact memory pi) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = 1;
        tpi.cms[0] = pi.outCm[0];
        tpi.cms[1] = pi.outCm[1];
        // cvDeps: all zero → matches pi.outCvDep default
        // isDeposit[0] = 0 (spend)
    }

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return MASP.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    function _validAux() internal pure returns (AuxValidation.Output[2] memory aux) {
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
    }

    // --- withdraw entry-point checks (before _validateRequest) --------------

    function test_withdraw_MustNotHaveDeposit() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicIn = 1; // triggers MustNotHaveDeposit
        pi.publicOut = 1;
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotHaveDeposit.selector);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_withdraw_MustHaveWithdraw() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicIn = 0;
        pi.publicOut = 0; // triggers MustHaveWithdraw
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustHaveWithdraw.selector);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    // --- transfer entry-point checks ----------------------------------------

    function test_transfer_MustNotHaveDeposit() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicIn = 1; // triggers MustNotHaveDeposit
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotHaveDeposit.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_transfer_MustNotHaveWithdraw() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicOut = 1; // triggers MustNotHaveWithdraw
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotHaveWithdraw.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    // --- _validateRequest checks (in order) ---------------------------------

    function test_ZeroRecipient() public {
        PubInputs.Transact memory pi = _pi();
        pi.recipient = address(0);
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.ZeroRecipient.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_ZeroPayer() public {
        PubInputs.Transact memory pi = _pi();
        pi.payer = address(0);
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.ZeroPayer.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_BadRelayer_wrongSender() public {
        PubInputs.Transact memory pi = _pi();
        pi.relayer = address(0xABCD); // differs from msg.sender (RELAYER)
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BadRelayer.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_DuplicateNullifier() public {
        PubInputs.Transact memory pi = _pi();
        pi.nullifier[1] = pi.nullifier[0]; // same nf
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(NullifierSet.DuplicateNullifier.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_BatchMisaligned_actualCountNot1() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        tpi.actualCount = 2; // must be 1 for spend path
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BatchMisaligned.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_CmMismatch_outCm0() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        tpi.cms[0] = bytes32(uint256(0xbad)); // tamper
        vm.prank(RELAYER);
        vm.expectRevert(MASP.CmMismatch.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_CmMismatch_outCm1() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        tpi.cms[1] = bytes32(uint256(0xbad)); // tamper
        vm.prank(RELAYER);
        vm.expectRevert(MASP.CmMismatch.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_CvDepMismatch() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        tpi.cvDeps[0][0] = 1; // pi.outCvDep[0][0] == 0 → mismatch
        vm.prank(RELAYER);
        vm.expectRevert(MASP.CvDepMismatch.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_UnknownRoot() public {
        PubInputs.Transact memory pi = _pi();
        pi.merkleRoot = bytes32(uint256(0xdeadbeef)); // not in isKnownRoot
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.UnknownRoot.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_StaleOldRoot() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        tpi.oldRoot = bytes32(uint256(0xbad)); // not currentRoot()
        vm.prank(RELAYER);
        vm.expectRevert(MASP.StaleOldRoot.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_BatchMisaligned_wrongStartIndex() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        tpi.startIndex = masp.committedCount() + 1; // wrong
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BatchMisaligned.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }
}
