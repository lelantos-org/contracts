// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";

import { CommitmentTreeHarness } from "../fuzz/CommitmentTreeHarness.sol";

/// Symbolic proofs for the 64-entry root ring buffer.
///
/// `test/invariant/CommitmentTree.invariant.t.sol` asserts these same three
/// properties over randomly generated call sequences. Here they are proved for
/// every root value, at a call depth halmos unrolls exactly — the ring's
/// wrap-around and its eviction rule are the parts a random sequence explores
/// shallowly.
contract CommitmentTreeSymbolicTest is GuardAsserts {
    CommitmentTreeHarness internal tree;

    function setUp() public {
        tree = new CommitmentTreeHarness();
    }

    /// One advance: the new root becomes current, is known, and the leaf count
    /// moves by exactly what was inserted.
    ///
    /// `inserted` is a uint32 so `committedCount` (uint64, starting at 0 in a
    /// fresh harness) cannot overflow across the two advances the multi-step
    /// proofs below make — an overflowing path reverts and would satisfy the
    /// postconditions vacuously.
    function check_advanceRoot_postconditions(bytes32 newRoot, uint32 inserted) public {
        uint64 before = tree.committedCount();

        tree.advanceRoot(newRoot, inserted);

        assertEq(tree.currentRoot(), newRoot);
        assertTrue(tree.isKnownRoot(newRoot));
        assertEq(tree.committedCount(), before + uint64(inserted));
    }

    /// `rootIndex` stays inside the ring and `roots[rootIndex]` is always what
    /// `currentRoot()` returns, for any pair of advances. The index is computed
    /// with a mask rather than a modulo (`(rootIndex + 1) & (ROOT_HISTORY - 1)`),
    /// which is only equivalent because the size is a power of two.
    function check_rootIndex_staysInRing(bytes32 r1, bytes32 r2) public {
        tree.advanceRoot(r1, 1);
        assertLt(uint256(tree.rootIndex()), tree.ROOT_HISTORY_SIZE());
        assertEq(tree.rootAt(tree.rootIndex()), tree.currentRoot());

        tree.advanceRoot(r2, 1);
        assertLt(uint256(tree.rootIndex()), tree.ROOT_HISTORY_SIZE());
        assertEq(tree.rootAt(tree.rootIndex()), tree.currentRoot());
    }

    /// Pushing the same root twice must not mark it unknown. Eviction clears
    /// `isKnownRoot` for the entry it overwrites, so without the
    /// `evicted != newRoot` guard a root still live in the buffer would be
    /// unlearned by its own re-insertion.
    function check_repeatedRoot_staysKnown(bytes32 r) public {
        tree.advanceRoot(r, 1);
        tree.advanceRoot(r, 1);
        assertTrue(tree.isKnownRoot(r));
        assertEq(tree.currentRoot(), r);
    }

    /// The previous root stays known while it is still in the ring: a proof
    /// accepted against the root one batch behind must not be invalidated by
    /// the next batch. Distinct roots only — the shared case is above.
    function check_previousRoot_staysKnown(bytes32 r1, bytes32 r2) public {
        vm.assume(r1 != r2);
        tree.advanceRoot(r1, 1);
        tree.advanceRoot(r2, 1);
        assertTrue(tree.isKnownRoot(r1));
        assertTrue(tree.isKnownRoot(r2));
    }
}
