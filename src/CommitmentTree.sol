// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Lazy-root commitment tree.
///
/// Holds a 64-entry ring buffer of recently accepted roots and
/// `committedCount`, the number of leaves baked into the latest one. Leaves are
/// inserted off-chain; a relayer submits the tree-update SNARK that proves the
/// transition, and the verifying caller advances the root.
abstract contract CommitmentTree {
    /// Capacity of the arity-4, depth-11 tree the circuits are built for.
    uint256 internal constant MAX_LEAVES = 4_194_304; // 4^11
    uint256 internal constant ROOT_HISTORY = 64;

    /// Genesis empty-tree root: iterate `z = Poseidon([5, z, z, z, z])`, with 5
    /// the Merkle domain tag, eleven times from `z = 0`. Pinned by
    /// `emptySubtree[11]` in the circuits' golden vectors.
    bytes32 internal constant EMPTY_ROOT = 0x1cf92e62b512433b35f0064d537576b0184cad5fa7ab64201cd8084ee2dc171f;

    bytes32[ROOT_HISTORY] public roots;
    /// Shares a storage slot with `committedCount`.
    uint32 public rootIndex;
    /// Number of leaves baked into the latest root. Advances by the number of
    /// leaves each verified batch inserts.
    uint64 public committedCount;
    mapping(bytes32 => bool) public isKnownRoot;

    event RootAdvanced(uint64 indexed startIndex, uint64 inserted, bytes32 oldRoot, bytes32 newRoot);

    constructor() {
        roots[0] = EMPTY_ROOT;
        isKnownRoot[EMPTY_ROOT] = true;
    }

    function currentRoot() public view returns (bytes32) {
        return roots[rootIndex];
    }

    /// Push `newRoot` and advance the leaf count. The caller must have verified
    /// the tree-update SNARK and that `oldRoot == currentRoot()` beforehand.
    function _advanceRoot(bytes32 newRoot, uint64 inserted, bytes32 oldRoot) internal {
        // `rootIndex` and `committedCount` share a slot: both are read here and
        // written together at the end, so the pair costs one SLOAD and one
        // SSTORE rather than two of each.
        uint32 newIdx = uint32((uint256(rootIndex) + 1) & (ROOT_HISTORY - 1));
        uint64 startIndex = committedCount;

        bytes32 evicted = roots[newIdx];
        // Clearing the evicted entry when it equals `newRoot` would mark a root
        // that remains live in the buffer as unknown.
        if (evicted != bytes32(0) && evicted != newRoot) {
            isKnownRoot[evicted] = false;
        }
        roots[newIdx] = newRoot;
        isKnownRoot[newRoot] = true;

        rootIndex = newIdx;
        committedCount = startIndex + inserted;
        emit RootAdvanced(startIndex, inserted, oldRoot, newRoot);
    }
}
