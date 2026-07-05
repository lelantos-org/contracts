// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// Lazy-root commitment tree. Tracks:
///   - 64-deep ring buffer of recently-known roots,
///   - `committedCount`, leaves in the latest root.
/// Relayers insert off-chain and submit a tree-update SNARK; contract
/// verifies and calls `_advanceRoot`. `EMPTY_ROOT` precomputed off-chain.
abstract contract CommitmentTree {
    uint256 internal constant TAG_MERKLE = 5;
    uint256 internal constant DEPTH = 10;
    uint256 internal constant ARITY = 4;
    uint256 internal constant MAX_LEAVES = 1_048_576; // 4^10
    uint256 internal constant ROOT_HISTORY = 64;

    /// Genesis empty-tree root: iterate `z = Poseidon([TAG_MERKLE, z, z, z, z])`
    /// DEPTH times from z = 0.
    bytes32 internal constant EMPTY_ROOT = 0x1308eb79d37ed29a9a2d34861692ea8c3e4fed3f555f53a8776c1256738e40a7;

    bytes32[ROOT_HISTORY] public roots;
    /// Packed: rootIndex (4B) | committedCount (8B).
    uint32 public rootIndex;
    /// Number of leaves baked into the latest root. Advances by 2 per spend.
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

    /// Push `newRoot`, advance leaf count. Caller MUST have verified the
    /// tree-update SNARK and that `oldRoot == currentRoot()` before calling.
    function _advanceRoot(bytes32 newRoot, uint64 inserted, bytes32 oldRoot) internal {
        uint32 newIdx = uint32((uint256(rootIndex) + 1) & (ROOT_HISTORY - 1));
        bytes32 evicted = roots[newIdx];
        // Skip the clear when re-inserting the same value, so a duplicate root
        // in the buffer is never marked unknown while a live copy exists.
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
