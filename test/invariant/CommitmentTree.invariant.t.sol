// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";

import { CommitmentTreeHarness } from "../utils/CommitmentTreeHarness.sol";

/// Handler narrows the fuzzer's call surface to a single bounded entrypoint
/// (`advance`, wrapping `advanceRoot`) and tracks ghost state for the
/// monotonicity checks.
contract CommitmentTreeHandler is Test {
    CommitmentTreeHarness public tree;
    uint64 public lastCommittedCount;
    uint256 public advanceCalls;

    constructor(CommitmentTreeHarness t) {
        tree = t;
    }

    function advance(bytes32 newRoot, uint64 inserted) external {
        // Bound `inserted` so cumulative count cannot overflow uint64 across
        // the fuzz depth.
        inserted = uint64(bound(inserted, 0, 1_000_000));
        uint64 before = tree.committedCount();
        tree.advanceRoot(newRoot, inserted);
        uint64 afterCount = tree.committedCount();
        assertGe(afterCount, before, "committedCount went backwards");
        assertEq(afterCount, before + inserted, "committedCount delta != inserted");
        lastCommittedCount = afterCount;
        advanceCalls++;
    }
}

contract CommitmentTreeInvariantTest is StdInvariant, Test {
    uint256 internal constant ROOT_HISTORY = 64;

    CommitmentTreeHarness tree;
    CommitmentTreeHandler handler;

    function setUp() public {
        tree = new CommitmentTreeHarness();
        handler = new CommitmentTreeHandler(tree);
        targetContract(address(handler));
    }

    /// rootIndex stays in [0, ROOT_HISTORY).
    function invariant_RootIndexInRange() public view {
        assertLt(tree.rootIndex(), ROOT_HISTORY);
    }

    /// `roots[rootIndex]` and `currentRoot()` agree.
    function invariant_CurrentRootMatchesRing() public view {
        assertEq(tree.rootAt(tree.rootIndex()), tree.currentRoot());
    }

    /// A non-zero current root reads as known, and `rootIndexOf` names a slot
    /// holding it. A zero root is never known: zero marks an unfilled slot, and
    /// no Poseidon root is zero.
    function invariant_CurrentRootIsKnown() public view {
        bytes32 current = tree.currentRoot();
        if (current == bytes32(0)) {
            assertFalse(tree.isKnownRoot(current), "zero root never known");
            return;
        }
        assertTrue(tree.isKnownRoot(current));
        (bool found, uint256 index) = tree.rootIndexOf(current);
        assertTrue(found, "current root found");
        assertEq(tree.rootAt(index), current, "found slot holds it");
    }

    /// Live count matches the last value the handler observed. Monotonicity
    /// (non-decreasing, advancing by exactly `inserted`) is asserted inside the
    /// handler on every call.
    function invariant_CommittedCountMatchesGhost() public view {
        assertEq(tree.committedCount(), handler.lastCommittedCount());
    }
}
