// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { NullifierSet } from "../../src/NullifierSet.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { MockPoolTestBase } from "../utils/MockPoolTestBase.sol";
import { noAssets } from "../utils/PoolDeployer.sol";

/// Spend-path (`transfer`, `withdraw`) request-validation negative tests.
/// Each test tampers with exactly one field to reach a specific revert.
/// All checks tested here fire in the entry points or `_validateRequest`,
/// before SNARK verification, so proof acceptance does not matter. The pool
/// registers no asset, so a transfer that passes validation reverts
/// `UnknownAsset(0)` next.
contract MASPSpendGuardsTest is MockPoolTestBase {
    address internal constant PAYER = address(0xBEEF);

    function setUp() public {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = noAssets();
        _deployMockPool(ids, tokens, scales, 0, address(0xfee), address(this));
    }

    // --- helpers -----------------------------------------------------------

    function _pi() internal view returns (PubInputs.Transact memory) {
        return _transact(PAYER, RELAYER, 1, 3);
    }

    // --- withdraw entry-point checks (before _validateRequest) --------------

    function test_withdraw_MustNotHaveDeposit() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicIn = 1; // triggers MustNotHaveDeposit
        pi.publicOut = 1;
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotHaveDeposit.selector);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    function test_withdraw_MustHaveWithdraw() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicIn = 0;
        pi.publicOut = 0; // triggers MustHaveWithdraw
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustHaveWithdraw.selector);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    // --- transfer entry-point checks ----------------------------------------

    function test_transfer_MustNotHaveDeposit() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicIn = 1; // triggers MustNotHaveDeposit
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotHaveDeposit.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    function test_transfer_MustNotHaveWithdraw() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicOut = 1; // triggers MustNotHaveWithdraw
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotHaveWithdraw.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    // --- _validateRequest checks (in order) ---------------------------------

    function test_ZeroRecipient() public {
        PubInputs.Transact memory pi = _pi();
        pi.recipient = address(0);
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.ZeroRecipient.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    function test_ZeroPayer() public {
        PubInputs.Transact memory pi = _pi();
        pi.payer = address(0);
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.ZeroPayer.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    function test_BadRelayer_wrongSender() public {
        PubInputs.Transact memory pi = _pi();
        pi.relayer = address(0xABCD); // differs from msg.sender (RELAYER)
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BadRelayer.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    function test_DuplicateNullifier() public {
        PubInputs.Transact memory pi = _pi();
        pi.nullifier[1] = pi.nullifier[0]; // same nf
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(NullifierSet.DuplicateNullifier.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    function test_UnknownRoot() public {
        PubInputs.Transact memory pi = _pi();
        pi.merkleRoot = bytes32(uint256(0xdeadbeef)); // in no ring slot
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.UnknownRoot.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// The anchor is checked at the slot the request names, not searched for:
    /// the genesis root is known, but not at slot 1.
    function test_UnknownRoot_knownRootAtWrongIndex() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        tpi.anchorIndex = 1;
        assertTrue(masp.isKnownRoot(pi.merkleRoot), "anchor is known");
        vm.prank(RELAYER);
        vm.expectRevert(MASP.UnknownRoot.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// `anchorIndex` is a `uint8`, so it can name a slot past `ROOT_HISTORY`.
    function test_UnknownRoot_indexOutOfRange() public {
        uint8[3] memory indices = [uint8(64), 65, 255];
        for (uint256 i; i < indices.length; ++i) {
            PubInputs.Transact memory pi = _pi();
            PubInputs.SpendTree memory tpi = _spendTree(pi);
            tpi.anchorIndex = indices[i];
            vm.prank(RELAYER);
            vm.expectRevert(MASP.UnknownRoot.selector);
            masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
        }
    }

    /// An unfilled slot holds zero, and a zero anchor does not match it.
    function test_UnknownRoot_zeroRootAtEmptySlot() public {
        PubInputs.Transact memory pi = _pi();
        pi.merkleRoot = bytes32(0);
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        tpi.anchorIndex = 5;
        assertEq(masp.roots(5), bytes32(0), "slot is unfilled");
        vm.prank(RELAYER);
        vm.expectRevert(MASP.UnknownRoot.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// The right slot passes validation: the next check to fail is the asset,
    /// which this pool does not register.
    function test_anchorAtItsIndex_reachesVerification() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        (bool found, uint256 index) = masp.rootIndexOf(pi.merkleRoot);
        assertTrue(found, "anchor found");
        tpi.anchorIndex = uint8(index);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(0)));
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    function test_BatchMisaligned_wrongStartIndex() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        tpi.startIndex = masp.committedCount() + 1; // wrong
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BatchMisaligned.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }
}
