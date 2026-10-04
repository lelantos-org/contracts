// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { NullifierSet } from "../../src/NullifierSet.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { MockPoolTestBase } from "../utils/MockPoolTestBase.sol";
import { noAssets } from "../utils/PoolDeployer.sol";

/// Spend-path (`transfer`, `withdraw`) request-validation negative tests.
/// Each test tampers with exactly one field to reach a specific revert.
/// All checks tested here fire in the entry points or `_validateRequest`,
/// before SNARK verification, so proof acceptance does not matter. The pool
/// registers no asset. A transfer names none, so one that passes validation
/// goes on to proof verification, which the mock verifier rejects until told
/// otherwise; a withdrawal that passes validation reverts `UnknownAsset`.
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

    function test_withdraw_MustHaveWithdraw() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicAssetId = 1;
        pi.publicOut = 0;
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustHaveWithdraw.selector);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    // --- transfer entry-point checks ----------------------------------------

    function test_transfer_MustNotHaveWithdraw() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicOut = 1;
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotHaveWithdraw.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// A transfer withdraws nothing, so it names no asset: the circuit forces
    /// `publicAssetId` to 0 whenever `publicOut` is, and the pool refuses a
    /// request built otherwise before looking at anything else in it. Any
    /// non-zero id is refused, registered or not.
    function testFuzz_transfer_MustNotNameAsset(uint64 assetId) public {
        vm.assume(assetId != 0);
        PubInputs.Transact memory pi = _pi();
        pi.publicAssetId = assetId;
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        bv.setResult(true);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotNameAsset.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// Naming a live registered asset is refused like any other: the check is
    /// on the request's shape, not on the registry.
    function test_transfer_MustNotNameAsset_registeredAsset() public {
        uint64 id = 7;
        masp.addAsset(id, IERC20(address(new MockERC20("M", "M", 18))), 1, 0, 0);

        PubInputs.Transact memory pi = _pi();
        pi.publicAssetId = id;
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        bv.setResult(true);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotNameAsset.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// With both set, the withdrawal amount is reported first: a request
    /// carrying `publicOut` belongs to `withdraw`, whatever asset it names.
    function test_transfer_MustNotHaveWithdraw_precedesMustNotNameAsset() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicAssetId = 7;
        pi.publicOut = 1;
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.MustNotHaveWithdraw.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// A transfer consults no registry entry: with asset 0 it completes on a
    /// pool that has registered nothing, inserting its outputs and consuming
    /// its nullifiers.
    function test_transfer_namesNoAsset_needsNoRegistry() public {
        PubInputs.Transact memory pi = _pi();
        assertEq(pi.publicAssetId, 0, "a transfer names no asset");
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        uint64 countBefore = masp.committedCount();

        bv.setResult(true);
        vm.prank(RELAYER);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());

        assertEq(masp.committedCount(), countBefore + PubInputs.TRANSACT_OUT, "outputs inserted");
        assertEq(masp.currentRoot(), tpi.newRoot, "root advanced");
        for (uint256 k; k < PubInputs.TRANSACT_IN; ++k) {
            assertTrue(masp.spent(pi.nullifier[k]), "nullifier consumed");
        }
    }

    /// A withdrawal still needs its asset: one naming an unregistered id is
    /// refused after request validation, and asset 0, which cannot be
    /// registered, is refused the same way.
    function test_withdraw_UnknownAsset() public {
        uint64[2] memory ids = [uint64(7), 0];
        for (uint256 i; i < ids.length; ++i) {
            PubInputs.Transact memory pi = _pi();
            pi.publicAssetId = ids[i];
            pi.publicOut = 1;
            PubInputs.SpendTree memory tpi = _spendTree(pi);
            bv.setResult(true);
            vm.prank(RELAYER);
            vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, ids[i]));
            masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
        }
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
        pi.nullifier[1] = pi.nullifier[0];
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

    /// The right slot passes validation: the next check to fail is the proof,
    /// which the mock verifier rejects by default. A transfer has no registry
    /// check in between.
    function test_anchorAtItsIndex_reachesVerification() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        (bool found, uint256 index) = masp.rootIndexOf(pi.merkleRoot);
        assertTrue(found, "anchor found");
        tpi.anchorIndex = uint8(index);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.ProofRejected.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    function test_BatchMisaligned_wrongStartIndex() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        tpi.startIndex = masp.committedCount() + 1;
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BatchMisaligned.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }
}
