// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MASPSpendHarness } from "./utils/MASPSpendHarness.sol";
import { CommitmentTree } from "../src/CommitmentTree.sol";

/// Root ring-buffer eviction: a spend using a root that has been evicted from
/// the 64-slot ring buffer must revert with `UnknownRoot`.
///
/// `ROOT_HISTORY = 64`. After 64 root advances, slot 0 is overwritten and the
/// genesis root is no longer `isKnownRoot`. Any subsequent spend that presents
/// the genesis root as `pi.merkleRoot` must fail.
contract MASPStaleRootTest is Test {
    address internal constant RELAYER = address(0xCA11);
    address internal constant PAYER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xF00D);

    MASPSpendHarness masp;
    IVerifier verifier;

    function setUp() public {
        verifier = IVerifier(address(new MockERC20("v", "v", 18)));
        IVerifier tubVerifier = IVerifier(address(new MockERC20("tub", "tub", 18)));
        address permit2 = new DeployPermit2().deployPermit2();

        uint64[] memory ids = new uint64[](0);
        IERC20[] memory tokens = new IERC20[](0);
        uint256[] memory scales = new uint256[](0);

        masp = new MASPSpendHarness(
            verifier,
            tubVerifier,
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            address(0xfee),
            address(this)
        );
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

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return MASP.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
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
        pi.nullifier[0] = bytes32(uint256(1));
        pi.nullifier[1] = bytes32(uint256(2));
        pi.outCm[0] = bytes32(uint256(3));
        pi.outCm[1] = bytes32(uint256(4));
        pi.merkleRoot = genesis; // evicted — no longer known

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = 1;
        tpi.cms[0] = pi.outCm[0];
        tpi.cms[1] = pi.outCm[1];

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
