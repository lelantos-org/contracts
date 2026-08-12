// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { CommitmentTree } from "../../src/CommitmentTree.sol";

/// Concrete subclass exposing `_advanceRoot` for fuzzing. The base contract is
/// abstract because `MASP` mixes it with access control and SNARK gating; this
/// harness exercises the ring-buffer/known-root bookkeeping in isolation.
contract CommitmentTreeHarness is CommitmentTree {
    /// Re-export the ring-buffer size so tests do not redeclare the constant;
    /// kept in sync with `CommitmentTree.ROOT_HISTORY` by inheritance.
    uint256 public constant ROOT_HISTORY_SIZE = ROOT_HISTORY;

    function advanceRoot(bytes32 newRoot, uint64 inserted) external {
        _advanceRoot(newRoot, inserted, currentRoot());
    }

    function rootAt(uint256 i) external view returns (bytes32) {
        return roots[i];
    }
}
