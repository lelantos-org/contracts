// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CommitmentTreeHarness } from "../fuzz/CommitmentTreeHarness.sol";

import { CommitmentTreeSpec } from "./generated/CommitmentTreeSpec.sol";
import { CommitmentTreeSpecReplay } from "./generated/CommitmentTreeSpecReplay.sol";

/// Driver for [spec/commitment_tree.qnt](../../spec/commitment_tree.qnt).
///
/// Reuses the harness the fuzz suite already drives
/// ([test/fuzz/CommitmentTreeHarness.sol](../fuzz/CommitmentTreeHarness.sol)),
/// so the two suites exercise the same surface and only differ in what chooses
/// the calls: the fuzzer picks at random within one run, Quint picks from a
/// model that is itself checked, and every step's post-state is asserted.
///
/// `abstract` so Foundry does not collect it as a test contract; the generated
/// `CommitmentTreeTraces` inherits it and holds one test per trace.
abstract contract CommitmentTreeReplay is CommitmentTreeSpecReplay {
    /// Must match `MAX_ROOT` in the spec. Roots are drawn from `2..MAX_ROOT`,
    /// and `_project` enumerates that domain to rebuild `knownRoots` — so if
    /// the spec widens its domain and this does not, the projection silently
    /// stops seeing the extra values. `_toModel` turns that into a hard failure
    /// rather than a quiet omission.
    uint256 internal constant MAX_ROOT = 7;
    /// Spec `EMPTY`, standing for `CommitmentTree.EMPTY_ROOT`.
    uint256 internal constant MODEL_EMPTY = 1;

    CommitmentTreeHarness internal tree;

    /// Read from the harness rather than hardcoded: the constant is `internal`
    /// on `CommitmentTree`, and slot 0 holds it immediately after construction.
    bytes32 internal emptyRoot;

    function setUp() public virtual {
        tree = new CommitmentTreeHarness();
        emptyRoot = tree.rootAt(0);
    }

    function apply_(CommitmentTreeSpec.Action action, CommitmentTreeSpec.Picks memory picks) external override {
        require(msg.sender == address(this), "self-call only");

        if (action == CommitmentTreeSpec.Action.Advance) {
            tree.advanceRoot(_toChain(picks.newRoot), uint64(picks.inserted));
        } else {
            revert("unhandled action");
        }
    }

    /// Every field is a live read; this driver keeps no shadow state.
    function _project() internal view override returns (CommitmentTreeSpec.State memory s) {
        s.rootIndex = tree.rootIndex();
        s.committedCount = tree.committedCount();

        uint256 n = tree.ROOT_HISTORY_SIZE();
        s.rootRing = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            s.rootRing[i] = _toModel(tree.rootAt(i));
        }

        // `isKnownRoot` is a mapping and cannot be enumerated, but the model's
        // root domain is finite and known, so walking it is a complete
        // reconstruction rather than a sample. Ascending by construction, which
        // is the order the generator sorted the model's set into.
        uint256[] memory found = new uint256[](MAX_ROOT);
        uint256 count = 0;
        for (uint256 v = MODEL_EMPTY; v <= MAX_ROOT; v++) {
            if (tree.isKnownRoot(_toChain(v))) {
                found[count++] = v;
            }
        }
        s.knownRoots = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            s.knownRoots[i] = found[i];
        }
    }

    /// Model integer to on-chain root.
    function _toChain(uint256 v) internal view returns (bytes32) {
        if (v == 0) return bytes32(0);
        if (v == MODEL_EMPTY) return emptyRoot;
        return bytes32(v);
    }

    /// On-chain root back to a model integer.
    function _toModel(bytes32 b) internal view returns (uint256) {
        if (b == bytes32(0)) return 0;
        if (b == emptyRoot) return MODEL_EMPTY;
        uint256 v = uint256(b);
        // A root outside the spec's domain means the driver and the spec have
        // drifted apart. Failing here names that directly, instead of letting a
        // value the model never chose surface as a divergence.
        require(v > MODEL_EMPTY && v <= MAX_ROOT, "driver: on-chain root outside the spec's domain");
        return v;
    }
}
