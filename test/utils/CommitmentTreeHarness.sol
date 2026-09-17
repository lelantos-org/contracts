// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CommitmentTree } from "../../src/CommitmentTree.sol";

/// Concrete subclass exposing `_advanceRoot` for fuzzing. The base contract is
/// abstract because `MASP` combines it with access control and SNARK gating;
/// this harness exercises the ring-buffer/known-root bookkeeping in isolation.
contract CommitmentTreeHarness is CommitmentTree {
    /// In production the genesis root is seeded from the proxy initializer. The
    /// harness is not proxied, so it seeds the root in its constructor.
    constructor() {
        _initCommitmentTree();
    }

    /// Ring-buffer size, re-exported from `CommitmentTree.ROOT_HISTORY` so tests
    /// do not redeclare the constant.
    uint256 public constant ROOT_HISTORY_SIZE = ROOT_HISTORY;

    function advanceRoot(bytes32 newRoot, uint64 inserted) external {
        _advanceRoot(newRoot, inserted, currentRoot());
    }

    function rootAt(uint256 i) external view returns (bytes32) {
        return roots[i];
    }
}
