// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { CommitmentTreeHarness } from "../utils/CommitmentTreeHarness.sol";

/// Fuzzes the lazy-root ring buffer in isolation, independent of the SNARK.
/// `_advanceRoot` is a state machine over (roots, rootIndex, committedCount), and
/// `isKnownRoot`/`rootIndexOf` read the ring; the properties below hold for any
/// caller-supplied root sequence.
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
            // Zero marks an unfilled slot and is never known.
            assertEq(tree.isKnownRoot(last), last != bytes32(0));
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

    /// After ROOT_HISTORY advances the genesis root is evicted, provided no
    /// pushed root equals it. Roots are derived from distinct keccak preimages
    /// to keep the assertion deterministic.
    function testFuzz_GenesisEvictedAfterFullCycle(bytes32 seed) public {
        bytes32 genesis = tree.currentRoot();
        // Genesis sits at slot 0 and the first push lands at slot 1, so the
        // ROOT_HISTORY-th push wraps around and overwrites slot 0.
        for (uint256 i; i < ROOT_HISTORY; ++i) {
            bytes32 r = keccak256(abi.encode(seed, i));
            // A pushed root equal to genesis would keep it in the ring.
            vm.assume(r != genesis);
            tree.advanceRoot(r, 0);
        }
        assertEq(tree.isKnownRoot(genesis), false);
        assertEq(tree.rootAt(0), keccak256(abi.encode(seed, ROOT_HISTORY - 1)));
    }

    /// Re-pushing the same root keeps it known, at the newest slot.
    function testFuzz_SameRootReinsertStaysKnown(bytes32 r, uint8 reps) public {
        vm.assume(r != bytes32(0));
        reps = uint8(bound(reps, 1, 100));
        for (uint256 i; i < reps; ++i) {
            tree.advanceRoot(r, 0);
            assertTrue(tree.isKnownRoot(r));
            assertEq(tree.currentRoot(), r);
            (bool found, uint256 index) = tree.rootIndexOf(r);
            assertTrue(found);
            assertEq(index, tree.rootIndex());
        }
    }

    /// `rootIndexOf` agrees with the ring for every root pushed, until it is
    /// evicted: the slot it names holds the root, and it is the newest such slot.
    function testFuzz_RootIndexOf_matchesRing(bytes32 seed, uint8 n) public {
        uint256 pushes = bound(n, 1, 3 * ROOT_HISTORY);
        for (uint256 i; i < pushes; ++i) {
            // A small domain, so roots repeat across the wrap.
            tree.advanceRoot(bytes32(uint256(keccak256(abi.encode(seed, i % 5))) | 1), 1);
        }
        for (uint256 k; k < 5; ++k) {
            bytes32 r = bytes32(uint256(keccak256(abi.encode(seed, k))) | 1);
            (bool found, uint256 index) = tree.rootIndexOf(r);
            bool inRing;
            uint256 newest;
            // Walk back from the current slot; the first hit is the newest.
            for (uint256 j; j < ROOT_HISTORY; ++j) {
                uint256 slot = (uint256(tree.rootIndex()) + ROOT_HISTORY - j) % ROOT_HISTORY;
                if (tree.rootAt(slot) == r) {
                    inRing = true;
                    newest = slot;
                    break;
                }
            }
            assertEq(found, inRing, "found iff in ring");
            assertEq(tree.isKnownRoot(r), inRing, "isKnownRoot agrees");
            if (found) assertEq(index, newest, "newest slot");
        }
    }
}
