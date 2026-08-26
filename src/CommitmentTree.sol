// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Lazy-root commitment tree.
///
/// Holds a 64-entry ring buffer of recently accepted roots and
/// `committedCount`, the number of leaves baked into the latest one. Leaves are
/// inserted off-chain; a relayer submits the tree-update SNARK that proves the
/// transition, and the verifying caller advances the root.
abstract contract CommitmentTree {
    /// Capacity of the arity-4, depth-10 tree the circuits are built for.
    uint256 internal constant MAX_LEAVES = 1_048_576; // 4^10
    uint256 internal constant ROOT_HISTORY = 64;

    /// Genesis empty-tree root: iterate `z = Poseidon([5, z, z, z, z])`, with 5
    /// the Merkle domain tag, ten times from `z = 0`.
    bytes32 internal constant EMPTY_ROOT = 0x1308eb79d37ed29a9a2d34861692ea8c3e4fed3f555f53a8776c1256738e40a7;

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
        uint32 newIdx = uint32((uint256(rootIndex) + 1) & (ROOT_HISTORY - 1));
        bytes32 evicted = roots[newIdx];
        // Clearing the evicted entry when it equals `newRoot` would mark a root
        // that remains live in the buffer as unknown.
        if (evicted != bytes32(0) && evicted != newRoot) {
            isKnownRoot[evicted] = false;
        }
        roots[newIdx] = newRoot;
        rootIndex = newIdx;
        isKnownRoot[newRoot] = true;
        uint64 startIndex = committedCount;
        committedCount = startIndex + inserted;
        emit RootAdvanced(startIndex, inserted, oldRoot, newRoot);
    }
}
