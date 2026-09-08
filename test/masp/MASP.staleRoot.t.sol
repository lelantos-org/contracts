// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { MASPSpendHarness, deploySpendHarness } from "../utils/MASPSpendHarness.sol";
import { mockVerifierStack, noAssets } from "../utils/PoolDeployer.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// Root ring-buffer eviction: a spend using a root that has been evicted from
/// the 64-slot ring buffer must revert with `UnknownRoot`.
///
/// `ROOT_HISTORY = 64`. After 64 root advances slot 0 is overwritten and the
/// genesis root ceases to be `isKnownRoot`, so any subsequent spend presenting
/// it as `pi.merkleRoot` must fail.
contract MASPStaleRootTest is Test {
    address internal constant RELAYER = address(0xCA11);
    address internal constant PAYER = address(0xBEEF);
    address internal constant RECIPIENT = TestConstants.RECIPIENT;

    MASPSpendHarness masp;

    function setUp() public {
        (IVerifier tubVerifier, MockBatchVerifier batchVerifier, ISignatureTransfer permit2) = mockVerifierStack();
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = noAssets();

        masp =
            deploySpendHarness(tubVerifier, batchVerifier, permit2, ids, tokens, scales, address(0xfee), address(this));
    }

    function _validAux() internal pure returns (AuxValidation.Output[6] memory aux) {
        return SpendFixture.validAux();
    }

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return FixtureLoader.emptyProof();
    }

    /// Advance the ring buffer `ROOT_HISTORY` times with distinct roots so
    /// slot 0 (genesis) is overwritten and `isKnownRoot[genesis] == false`.
    function _evictGenesisRoot() internal {
        bytes32 genesis = masp.currentRoot();
        uint256 rootHistory = 64; // CommitmentTree.ROOT_HISTORY
        for (uint256 i = 0; i < rootHistory; i++) {
            bytes32 newRoot = keccak256(abi.encode("evict", i));
            vm.assume(newRoot != genesis); // practically impossible collision
            masp.seedRoot(newRoot, 0);
        }
        assertFalse(masp.isKnownRoot(genesis), "genesis still known after eviction");
    }

    function test_evictedRoot_spendReverts_UnknownRoot() public {
        bytes32 genesis = masp.currentRoot();
        _evictGenesisRoot();

        PubInputs.Transact memory pi;
        pi.chainId = block.chainid;
        pi.publicAssetId = 0; // asset check fires after UnknownRoot, doesn't matter
        pi.publicIn = 0;
        pi.publicOut = 0;
        pi.recipient = RECIPIENT;
        pi.payer = PAYER;
        pi.relayer = RELAYER;
        SpendFixture.fillOutputs(pi, 1, 3);
        pi.merkleRoot = genesis; // evicted — no longer known

        PubInputs.TreeUpdateBatch memory tpi =
            SpendFixture.batchFor(pi, masp.currentRoot(), bytes32(uint256(0xdead)), masp.committedCount());

        vm.prank(RELAYER);
        vm.expectRevert(MASP.UnknownRoot.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    /// Root that is still within the 64-slot window is accepted (no revert
    /// from UnknownRoot), verifying the eviction threshold is exactly 64.
    function test_recentRoot_stillKnown_after63Advances() public {
        bytes32 genesis = masp.currentRoot();

        // Advance 63 times — genesis still occupies slot 0 (not yet overwritten).
        for (uint256 i = 0; i < 63; i++) {
            masp.seedRoot(keccak256(abi.encode("step", i)), 0);
        }

        assertTrue(masp.isKnownRoot(genesis), "genesis evicted too early");
    }

    /// After exactly ROOT_HISTORY advances, genesis is gone.
    function test_genesisEvicted_after64Advances() public {
        bytes32 genesis = masp.currentRoot();
        for (uint256 i = 0; i < 64; i++) {
            masp.seedRoot(keccak256(abi.encode("step", i)), 0);
        }
        assertFalse(masp.isKnownRoot(genesis), "genesis should be evicted after 64 advances");
    }
}
