// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { CommitmentTreeHarness } from "./CommitmentTreeHarness.sol";

/// Fuzz the lazy-root ring buffer in isolation, independent of the SNARK.
/// `_advanceRoot` is a state machine over (roots, isKnownRoot, committedCount);
/// the invariants below hold for any caller-supplied root sequence.
contract CommitmentTreeFuzzTest is Test {
    CommitmentTreeHarness tree;
    uint256 internal ROOT_HISTORY;

    function setUp() public {
        tree = new CommitmentTreeHarness();
        ROOT_HISTORY = tree.ROOT_HISTORY_SIZE();
    }

    /// Advancing N times leaves `currentRoot()` as the most recently pushed
    /// root and `committedCount` advanced by sum(inserted_i).
    function testFuzz_CurrentRootAndCount(bytes32[16] memory rs, uint64[16] memory ins) public {
        uint64 expectedCount;
        bytes32 last;
        for (uint256 i; i < rs.length; ++i) {
            // Bound `inserted` so the running sum cannot overflow uint64.
            uint64 step = uint64(bound(ins[i], 0, 1_000_000));
            tree.advanceRoot(rs[i], step);
            expectedCount += step;
            last = rs[i];
            assertEq(tree.currentRoot(), last);
            assertTrue(tree.isKnownRoot(last));
            assertEq(tree.committedCount(), expectedCount);
        }
    }

    /// `rootIndex` cycles within [0, ROOT_HISTORY) and equals the number of
    /// advances modulo ROOT_HISTORY (genesis sits at slot 0; first push lands
    /// at slot 1).
    function testFuzz_RootIndexCycles(bytes32[8] memory rs) public {
        for (uint256 i; i < rs.length; ++i) {
            tree.advanceRoot(rs[i], 2);
            uint32 expectedIdx = uint32((i + 1) % ROOT_HISTORY);
            assertEq(tree.rootIndex(), expectedIdx);
        }
    }

    /// After ROOT_HISTORY+1 advances the genesis root is evicted unless one of
    /// the pushed roots equals it. Roots are forced distinct to keep the
    /// assertion deterministic.
    function testFuzz_GenesisEvictedAfterFullCycle(bytes32 seed) public {
        bytes32 genesis = tree.currentRoot();
        // ROOT_HISTORY pushes evict slot 0 (the next index after genesis is 1,
        // so it takes a full lap to come back around and overwrite slot 0).
        for (uint256 i; i < ROOT_HISTORY; ++i) {
            bytes32 r = keccak256(abi.encode(seed, i));
            // Vanishingly unlikely keccak collision, but skip if it ever happens
            // to be the genesis root or any earlier push (would re-set isKnownRoot).
            vm.assume(r != genesis);
            tree.advanceRoot(r, 0);
        }
        assertEq(tree.isKnownRoot(genesis), false);
        assertEq(tree.rootAt(0), keccak256(abi.encode(seed, ROOT_HISTORY - 1)));
    }

    /// Re-pushing the same root twice in a row keeps it `isKnownRoot == true`
    /// — the eviction guard skips flipping the flag when `evicted == newRoot`.
    function testFuzz_SameRootReinsertStaysKnown(bytes32 r, uint8 reps) public {
        reps = uint8(bound(reps, 1, 100));
        for (uint256 i; i < reps; ++i) {
            tree.advanceRoot(r, 0);
            assertTrue(tree.isKnownRoot(r));
            assertEq(tree.currentRoot(), r);
        }
    }
}
