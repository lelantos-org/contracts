// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { NullifierSet } from "../src/NullifierSet.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockBatchVerifier } from "./mocks/MockBatchVerifier.sol";
import { SpendFixture } from "./utils/SpendFixture.sol";
import { FixtureLoader } from "./utils/FixtureLoader.sol";

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
        MockBatchVerifier bv = new MockBatchVerifier();
        address permit2 = new DeployPermit2().deployPermit2();
        masp = new MASP(
            tub,
            bv,
            ISignatureTransfer(address(permit2)),
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
        SpendFixture.fillOutputs(pi, 1, 3);
        pi.merkleRoot = masp.currentRoot();
        // outCvDep: all zero → matches tpi.cvDeps default
    }

    function _tpi(PubInputs.Transact memory pi) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        return SpendFixture.batchFor(pi, masp.currentRoot(), bytes32(uint256(0xdead)), masp.committedCount());
    }

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return FixtureLoader.emptyProof();
    }

    function _validAux() internal pure returns (AuxValidation.Output[4] memory aux) {
        return SpendFixture.validAux();
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

    /// `actualCount` counts leaves, so a 2-output spend must declare exactly
    /// 2. Anything else — here a pair-era 1 — is misaligned.
    function test_BatchMisaligned_actualCountNotOutLeaves() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        tpi.actualCount = 1; // must be 2 (N_OUT) for the spend path
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BatchMisaligned.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    /// The batch circuit cannot distinguish a spend leaf from a deposit leaf, and
    /// per-leaf deposit binding is satisfiable by any spend output that declares
    /// its own (asset, value) — which would publish the note's opening. So the
    /// spend path must pin `isDeposit` to 0 on-chain, for every output leaf.
    function test_BadDepositMode_spendLeafMarkedDeposit() public {
        for (uint256 k = 0; k < 2; k++) {
            PubInputs.Transact memory pi = _pi();
            PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
            tpi.isDeposit[k] = 1;
            vm.prank(RELAYER);
            vm.expectRevert(MASP.BadDepositMode.selector);
            masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
        }
    }

    /// Both cross-binding arrays are indexed by output, so both are swept over
    /// the whole shape rather than over a hardcoded prefix. Enumerating only
    /// outputs 0 and 1 is what let the `cvDeps[2]` gap survive the 2x2 -> 3x3 -> 4x4
    /// migration: the tests agreed with the bug.
    function test_CmMismatch_everyOutput() public {
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; ++k) {
            PubInputs.Transact memory pi = _pi();
            PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
            tpi.cms[k] = bytes32(uint256(0xbad)); // tamper exactly one output
            vm.prank(RELAYER);
            vm.expectRevert(MASP.CmMismatch.selector);
            masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
        }
    }

    /// `cv_dep` is inside the leaf preimage and `spent.circom` recomputes it
    /// from the note's own (asset, value, rcv), so an unbound (output,
    /// coordinate) pair lets a relayer consume the inputs while inserting a
    /// leaf the recipient can never produce a Merkle path for. All
    /// `TRANSACT_OUT * 2` coordinates must revert.
    function test_CvDepMismatch_everyOutputAndCoordinate() public {
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; ++k) {
            for (uint256 c = 0; c < 2; ++c) {
                PubInputs.Transact memory pi = _pi();
                PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
                tpi.cvDeps[k][c] = 1; // pi.outCvDep[k][c] == 0 -> mismatch
                vm.prank(RELAYER);
                vm.expectRevert(MASP.CvDepMismatch.selector);
                masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
            }
        }
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
