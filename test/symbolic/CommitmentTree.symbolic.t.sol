// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";

import { CommitmentTreeHarness } from "../fuzz/CommitmentTreeHarness.sol";

/// Symbolic proofs for the 64-entry root ring buffer.
///
/// `test/invariant/CommitmentTree.invariant.t.sol` checks the ring-index,
/// current-root and committed-count invariants over random call sequences. Here
/// the properties are proved for every root value at a fixed call depth, covering
/// the ring's index masking and root lookups that random sequences reach rarely.
contract CommitmentTreeSymbolicTest is GuardAsserts {
    CommitmentTreeHarness internal tree;

    function setUp() public {
        tree = new CommitmentTreeHarness();
    }

    /// One advance: the new root becomes current, is known at the current slot,
    /// and the leaf count increases by exactly `inserted`. Zero is excluded: it
    /// marks an unfilled slot and is never known.
    ///
    /// `inserted` is a uint32 so `committedCount` (uint64, 0 in a fresh harness)
    /// cannot overflow; an overflowing path reverts, and halmos would discard it,
    /// satisfying the postconditions vacuously.
    function check_advanceRoot_postconditions(bytes32 newRoot, uint32 inserted) public {
        vm.assume(newRoot != bytes32(0));
        uint64 before = tree.committedCount();

        tree.advanceRoot(newRoot, inserted);

        assertEq(tree.currentRoot(), newRoot);
        assertTrue(tree.isKnownRoot(newRoot));
        (bool found, uint256 index) = tree.rootIndexOf(newRoot);
        assertTrue(found);
        assertEq(index, uint256(tree.rootIndex()));
        assertEq(tree.committedCount(), before + uint64(inserted));
    }

    /// Zero is never a known root, whatever the ring holds: unfilled slots are
    /// zero, and a spend naming one must not match.
    function check_zeroRoot_neverKnown(bytes32 r) public {
        tree.advanceRoot(r, 1);
        assertFalse(tree.isKnownRoot(bytes32(0)));
        (bool found,) = tree.rootIndexOf(bytes32(0));
        assertFalse(found);
    }

    /// `rootIndex` stays inside the ring and `roots[rootIndex]` equals
    /// `currentRoot()`, for any pair of advances. The index uses a mask rather
    /// than a modulo (`(rootIndex + 1) & (ROOT_HISTORY - 1)`), which is equivalent
    /// only because the size is a power of two.
    function check_rootIndex_staysInRing(bytes32 r1, bytes32 r2) public {
        tree.advanceRoot(r1, 1);
        assertLt(uint256(tree.rootIndex()), tree.ROOT_HISTORY_SIZE());
        assertEq(tree.rootAt(tree.rootIndex()), tree.currentRoot());

        tree.advanceRoot(r2, 1);
        assertLt(uint256(tree.rootIndex()), tree.ROOT_HISTORY_SIZE());
        assertEq(tree.rootAt(tree.rootIndex()), tree.currentRoot());
    }

    /// Pushing the same root twice keeps it known, and the lookup returns the
    /// newer slot, which is evicted last.
    function check_repeatedRoot_staysKnown(bytes32 r) public {
        vm.assume(r != bytes32(0));
        tree.advanceRoot(r, 1);
        tree.advanceRoot(r, 1);
        assertTrue(tree.isKnownRoot(r));
        assertEq(tree.currentRoot(), r);
        (, uint256 index) = tree.rootIndexOf(r);
        assertEq(index, uint256(tree.rootIndex()));
    }

    /// The previous root stays known while it is in the ring, so a proof against
    /// the root one batch behind is not invalidated by the next batch. Distinct
    /// roots only; the repeated case is covered above.
    function check_previousRoot_staysKnown(bytes32 r1, bytes32 r2) public {
        vm.assume(r1 != r2 && r1 != bytes32(0) && r2 != bytes32(0));
        tree.advanceRoot(r1, 1);
        tree.advanceRoot(r2, 1);
        assertTrue(tree.isKnownRoot(r1));
        assertTrue(tree.isKnownRoot(r2));
    }
}
