// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { NullifierSet } from "../../src/NullifierSet.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { deployPoolUniform, mockVerifierStack, noAssets } from "../utils/PoolDeployer.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// Spend-path (`transfer`, `withdraw`) request-validation negative tests.
/// Each test tampers with exactly one field to reach a specific revert.
/// All checks tested here fire in the entry points or `_validateRequest`,
/// before SNARK verification, so proof acceptance does not matter. The pool
/// registers no asset, so a transfer that passes validation reverts
/// `UnknownAsset(0)` next.
contract MASPSpendGuardsTest is Test {
    address internal constant RELAYER = address(0xCA11);
    address internal constant PAYER = address(0xBEEF);
    address internal constant RECIPIENT = TestConstants.RECIPIENT;

    MASP masp;

    function setUp() public {
        (IVerifier tub, MockBatchVerifier bv, ISignatureTransfer permit2) = mockVerifierStack();
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = noAssets();
        masp = deployPoolUniform(tub, bv, permit2, ids, tokens, scales, 0, address(0xfee), address(this));
    }

    // --- helpers -----------------------------------------------------------

    function _pi() internal view returns (PubInputs.Transact memory pi) {
        pi.chainId = block.chainid;
        pi.recipient = RECIPIENT;
        pi.payer = PAYER;
        pi.relayer = RELAYER;
        SpendFixture.fillOutputs(pi, 1, 3);
        pi.merkleRoot = masp.currentRoot();
    }

    /// Anchored at `pi.merkleRoot`'s slot; an unknown root gets slot 0.
    function _tpi(PubInputs.Transact memory pi) internal view returns (PubInputs.SpendTree memory) {
        (, uint256 anchorIndex) = masp.rootIndexOf(pi.merkleRoot);
        return SpendFixture.spendTree(bytes32(uint256(0xdead)), masp.committedCount(), uint8(anchorIndex));
    }

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return FixtureLoader.emptyProof();
    }

    function _validAux() internal pure returns (AuxValidation.Output[6] memory aux) {
        return SpendFixture.validAux();
    }

    // --- withdraw entry-point checks (before _validateRequest) --------------

    function test_withdraw_MustNotHaveDeposit() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicIn = 1; // triggers MustNotHaveDeposit
        pi.publicOut = 1;
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotHaveDeposit.selector);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_withdraw_MustHaveWithdraw() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicIn = 0;
        pi.publicOut = 0; // triggers MustHaveWithdraw
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustHaveWithdraw.selector);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    // --- transfer entry-point checks ----------------------------------------

    function test_transfer_MustNotHaveDeposit() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicIn = 1; // triggers MustNotHaveDeposit
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotHaveDeposit.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_transfer_MustNotHaveWithdraw() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicOut = 1; // triggers MustNotHaveWithdraw
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotHaveWithdraw.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    // --- _validateRequest checks (in order) ---------------------------------

    function test_ZeroRecipient() public {
        PubInputs.Transact memory pi = _pi();
        pi.recipient = address(0);
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.ZeroRecipient.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_ZeroPayer() public {
        PubInputs.Transact memory pi = _pi();
        pi.payer = address(0);
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.ZeroPayer.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_BadRelayer_wrongSender() public {
        PubInputs.Transact memory pi = _pi();
        pi.relayer = address(0xABCD); // differs from msg.sender (RELAYER)
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BadRelayer.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_DuplicateNullifier() public {
        PubInputs.Transact memory pi = _pi();
        pi.nullifier[1] = pi.nullifier[0]; // same nf
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(NullifierSet.DuplicateNullifier.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_UnknownRoot() public {
        PubInputs.Transact memory pi = _pi();
        pi.merkleRoot = bytes32(uint256(0xdeadbeef)); // in no ring slot
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.UnknownRoot.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    /// The anchor is checked at the slot the request names, not searched for:
    /// the genesis root is known, but not at slot 1.
    function test_UnknownRoot_knownRootAtWrongIndex() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _tpi(pi);
        tpi.anchorIndex = 1;
        assertTrue(masp.isKnownRoot(pi.merkleRoot), "anchor is known");
        vm.prank(RELAYER);
        vm.expectRevert(MASP.UnknownRoot.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    /// `anchorIndex` is a `uint8`, so it can name a slot past `ROOT_HISTORY`.
    function test_UnknownRoot_indexOutOfRange() public {
        uint8[3] memory indices = [uint8(64), 65, 255];
        for (uint256 i; i < indices.length; ++i) {
            PubInputs.Transact memory pi = _pi();
            PubInputs.SpendTree memory tpi = _tpi(pi);
            tpi.anchorIndex = indices[i];
            vm.prank(RELAYER);
            vm.expectRevert(MASP.UnknownRoot.selector);
            masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
        }
    }

    /// An unfilled slot holds zero, and a zero anchor does not match it.
    function test_UnknownRoot_zeroRootAtEmptySlot() public {
        PubInputs.Transact memory pi = _pi();
        pi.merkleRoot = bytes32(0);
        PubInputs.SpendTree memory tpi = _tpi(pi);
        tpi.anchorIndex = 5;
        assertEq(masp.roots(5), bytes32(0), "slot is unfilled");
        vm.prank(RELAYER);
        vm.expectRevert(MASP.UnknownRoot.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    /// The right slot passes validation: the next check to fail is the asset,
    /// which this pool does not register.
    function test_anchorAtItsIndex_reachesVerification() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _tpi(pi);
        (bool found, uint256 index) = masp.rootIndexOf(pi.merkleRoot);
        assertTrue(found, "anchor found");
        tpi.anchorIndex = uint8(index);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(0)));
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function test_BatchMisaligned_wrongStartIndex() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _tpi(pi);
        tpi.startIndex = masp.committedCount() + 1; // wrong
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BatchMisaligned.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }
}
