// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { MASPSpendHarness, deploySpendHarness } from "../utils/MASPSpendHarness.sol";
import { MockPoolTestBase } from "../utils/MockPoolTestBase.sol";
import { noAssets } from "../utils/PoolDeployer.sol";

/// Root ring-buffer eviction: a spend using a root evicted from the 64-slot
/// ring buffer reverts with `UnknownRoot`, and a spend against a lagging root
/// still in the ring is accepted at that root's slot.
///
/// `ROOT_HISTORY = 64`. After 64 root advances slot 0 is overwritten and the
/// genesis root leaves the ring, so any subsequent spend presenting it as
/// `pi.merkleRoot`, at any `anchorIndex`, fails. A spend built on a tree
/// position that another batch has since advanced fails `BatchMisaligned`.
contract MASPStaleRootTest is MockPoolTestBase {
    address internal constant PAYER = address(0xBEEF);

    /// `masp` as its harness type, for `seedRoot`.
    MASPSpendHarness harness;

    function setUp() public {
        _deployMockStack();
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = noAssets();

        harness = deploySpendHarness(tub, bv, permit2, ids, tokens, scales, address(0xfee), address(this));
        masp = harness;
    }

    /// Advances the ring buffer `ROOT_HISTORY` times with distinct roots so
    /// slot 0 (genesis) is overwritten and the genesis root is unknown.
    function _evictGenesisRoot() internal {
        bytes32 genesis = masp.currentRoot();
        uint256 rootHistory = 64; // CommitmentTree.ROOT_HISTORY
        for (uint256 i = 0; i < rootHistory; i++) {
            bytes32 newRoot = keccak256(abi.encode("evict", i));
            vm.assume(newRoot != genesis); // practically impossible collision
            harness.seedRoot(newRoot, 0);
        }
        assertFalse(masp.isKnownRoot(genesis), "genesis still known after eviction");
    }

    function test_evictedRoot_spendReverts_UnknownRoot() public {
        bytes32 genesis = masp.currentRoot();
        _evictGenesisRoot();

        PubInputs.Transact memory pi = _transact(PAYER, RELAYER, 1, 3);
        pi.publicAssetId = 0; // irrelevant: the asset check fires after UnknownRoot
        pi.merkleRoot = genesis; // evicted, so unknown

        PubInputs.SpendTree memory tpi = SpendFixture.spendTree(bytes32(uint256(0xdead)), masp.committedCount());

        vm.prank(RELAYER);
        vm.expectRevert(MASP.UnknownRoot.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    function _spend(bytes32 anchor, uint8 anchorIndex)
        internal
        view
        returns (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi)
    {
        pi = _transact(PAYER, RELAYER, 1, 3);
        pi.merkleRoot = anchor;
        tpi = SpendFixture.spendTree(bytes32(uint256(0xdead)), masp.committedCount(), anchorIndex);
    }

    /// The evicted genesis root is refused at the slot it occupied before
    /// eviction and at every other slot.
    function test_evictedRoot_everyIndex_UnknownRoot() public {
        bytes32 genesis = masp.currentRoot();
        _evictGenesisRoot();
        (bool found,) = masp.rootIndexOf(genesis);
        assertFalse(found, "lookup agrees");

        for (uint256 i; i < 256; i += 17) {
            (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _spend(genesis, uint8(i));
            vm.prank(RELAYER);
            vm.expectRevert(MASP.UnknownRoot.selector);
            masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
        }
    }

    /// A root 63 advances old still sits in the ring, at the slot after the
    /// current one; `rootIndexOf` names it and the spend passes validation,
    /// failing next on the asset this pool does not register.
    function test_laggingAnchor_acceptedAtItsIndex() public {
        bytes32 oldest = keccak256(abi.encode("step", uint256(0)));
        for (uint256 i = 0; i < 64; i++) {
            harness.seedRoot(keccak256(abi.encode("step", i)), 0);
        }
        (bool found, uint256 index) = masp.rootIndexOf(oldest);
        assertTrue(found, "oldest root still in the ring");
        assertEq(index, (uint256(masp.rootIndex()) + 1) % 64, "next to be evicted");

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _spend(oldest, uint8(index));
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(0)));
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());

        // One more advance evicts it, and the same request fails validation.
        harness.seedRoot(keccak256("evicts the oldest"), 0);
        tpi.startIndex = masp.committedCount();
        vm.prank(RELAYER);
        vm.expectRevert(MASP.UnknownRoot.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// A spend proved against the tree before another batch landed extends a
    /// root that is not current. Its anchor is still known; its tree position
    /// is stale.
    function test_staleTreePosition_BatchMisaligned() public {
        bytes32 genesis = masp.currentRoot();
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _spend(genesis, 0);
        harness.seedRoot(keccak256("another batch"), 6);

        vm.prank(RELAYER);
        vm.expectRevert(MASP.BatchMisaligned.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// A root within the 64-slot window stays known after 63 advances; together
    /// with `test_genesisEvicted_after64Advances` this pins the eviction
    /// threshold at exactly 64.
    function test_recentRoot_stillKnown_after63Advances() public {
        bytes32 genesis = masp.currentRoot();

        // 63 advances: genesis still occupies slot 0.
        for (uint256 i = 0; i < 63; i++) {
            harness.seedRoot(keccak256(abi.encode("step", i)), 0);
        }

        assertTrue(masp.isKnownRoot(genesis), "genesis evicted too early");
    }

    /// After exactly ROOT_HISTORY advances, genesis is gone.
    function test_genesisEvicted_after64Advances() public {
        bytes32 genesis = masp.currentRoot();
        for (uint256 i = 0; i < 64; i++) {
            harness.seedRoot(keccak256(abi.encode("step", i)), 0);
        }
        assertFalse(masp.isKnownRoot(genesis), "genesis should be evicted after 64 advances");
    }
}
