// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Lazy-root commitment tree. Holds a 64-entry ring buffer of accepted roots
/// and `committedCount`, the number of leaves baked into the latest one. Leaves
/// are inserted off-chain; a relayer submits the tree-update SNARK proving the
/// transition, and the verifying caller advances the root.
///
/// There is no root-to-known mapping: a spend names the ring slot its anchor
/// sits in (`SpendTree.anchorIndex`) and the pool compares that one slot.
abstract contract CommitmentTree {
    /// Capacity of the arity-4, depth-11 tree the circuits are built for.
    uint256 internal constant MAX_LEAVES = 4_194_304; // 4^11
    uint256 internal constant ROOT_HISTORY = 64;

    /// Genesis empty-tree root: iterate `z = Poseidon([5, z, z, z, z])`, with 5
    /// the Merkle domain tag, eleven times from `z = 0`. Pinned by
    /// `emptySubtree[11]` in the circuits' golden vectors.
    bytes32 internal constant EMPTY_ROOT = 0x1cf92e62b512433b35f0064d537576b0184cad5fa7ab64201cd8084ee2dc171f;

    /// Ring buffer of accepted roots; an unfilled slot holds zero.
    bytes32[ROOT_HISTORY] public roots;
    /// Ring position of `currentRoot()`. Shares a storage slot with
    /// `committedCount`.
    uint32 public rootIndex;
    /// Number of leaves baked into the latest root. Advances by the number of
    /// leaves each verified batch inserts.
    uint64 public committedCount;
    /// Reserved slot, never read or written. Keeps every subsequent slot at the
    /// position deployed pool storage expects.
    uint256 private _retiredKnownRootSlot;

    event RootAdvanced(uint64 indexed startIndex, uint64 inserted, bytes32 oldRoot, bytes32 newRoot);

    /// Seeds the empty-tree root. Called once from the pool's initializer; the
    /// pool runs behind a proxy, where a constructor would write the
    /// implementation's storage.
    function _initCommitmentTree() internal {
        roots[0] = EMPTY_ROOT;
    }

    /// Whether `root` is one of the last `ROOT_HISTORY` accepted roots. A scan,
    /// for off-chain callers; the spend path checks one slot by index.
    function isKnownRoot(bytes32 root) external view returns (bool found) {
        (found,) = rootIndexOf(root);
    }

    /// Ring position of `root`, the `SpendTree.anchorIndex` a spend against it
    /// passes. Scans newest first, so a root held twice resolves to the slot
    /// evicted last. The index stays valid until `ROOT_HISTORY` more roots are
    /// accepted, which overwrite it.
    function rootIndexOf(bytes32 root) public view returns (bool found, uint256 index) {
        if (root == bytes32(0)) return (false, 0);
        uint256 idx = rootIndex;
        for (uint256 i; i < ROOT_HISTORY; ++i) {
            if (roots[idx] == root) return (true, idx);
            idx = (idx + ROOT_HISTORY - 1) & (ROOT_HISTORY - 1);
        }
    }

    /// Whether `root` sits at ring position `index`. Zero never matches, as an
    /// unfilled slot holds zero.
    function _isRootAt(bytes32 root, uint256 index) internal view returns (bool) {
        return index < ROOT_HISTORY && root != bytes32(0) && roots[index] == root;
    }

    function currentRoot() public view returns (bytes32) {
        return roots[rootIndex];
    }

    /// Pushes `newRoot` and advances the leaf count. The caller must have verified
    /// the tree-update SNARK and that `oldRoot == currentRoot()` beforehand.
    function _advanceRoot(bytes32 newRoot, uint64 inserted, bytes32 oldRoot) internal {
        // `rootIndex` and `committedCount` share a slot and are read here and
        // written together below, for one SLOAD and one SSTORE.
        uint32 newIdx = uint32((uint256(rootIndex) + 1) & (ROOT_HISTORY - 1));
        uint64 startIndex = committedCount;

        roots[newIdx] = newRoot;

        rootIndex = newIdx;
        committedCount = startIndex + inserted;
        emit RootAdvanced(startIndex, inserted, oldRoot, newRoot);
    }
}
