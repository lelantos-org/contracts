// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IBatchVerifier } from "./interfaces/IBatchVerifier.sol";
import { IVerifier } from "./interfaces/IVerifier.sol";

/// The pool's two verifiers and the replacement queued for them, held at a fixed
/// ERC-7201 slot.
///
/// Written by `DelayedUpgradeProxy` in its own context and read by the pool
/// under `delegatecall`, exactly as `UpgradeStorage` is. The namespaced slot
/// keeps them clear of the pool's sequential layout, so the pair can be
/// installed by the proxy without the proxy holding a copy of that layout.
///
/// ## Why the proxy owns this
///
/// The verifiers decide what the pool accepts as a valid proof, so replacing
/// them is the same power as replacing the implementation: either can make the
/// pool honour notes that were never legitimately created. A swap therefore gets
/// the treatment an upgrade gets, and gets it from the same contract — the admin
/// queues it, the window is `UPGRADE_DELAY`, a pause defers it by the pause
/// duration, and the commit is permissionless once the window has run.
///
/// Matching the upgrade window is deliberate rather than conservative.
/// Governance can already change what the pool accepts by upgrading the
/// implementation, which takes `UPGRADE_DELAY`, so a shorter window here would
/// be a route around the guarantee the proxy exists to provide, and a longer one
/// would buy nothing governance could not undo by taking the upgrade path
/// instead.
///
/// ## Why both move together
///
/// `BatchedGroth16Verifier` embeds the verifying keys of `4x6` and
/// `tree_update_batch`, and `TreeUpdateBatchVerifier` embeds the second of
/// those; both come from one circuits release. Replacing them separately would
/// leave a window in which a `tree_update_batch` proof is accepted on the spend
/// path and rejected on the flush path, or the reverse.
library VerifierStorage {
    /// `keccak256(abi.encode(uint256(keccak256("lelantos.storage.Verifiers")) - 1)) & ~bytes32(uint256(0xff))`
    /// Re-derived in `NamespaceSlots.t.sol`.
    bytes32 internal constant SLOT = 0xcbcc4872aefd59bec89d7dd87ceec756160699724c0e83f918a4b4dcbb131100;

    /// Four slots. The live pair is read on every spend and every flush, so it
    /// sits first; the queued pair packs its `notBefore` alongside, 20 + 5
    /// bytes.
    ///
    /// `notBefore == 0` means nothing is queued, and a queued pair is never
    /// zero, since both halves are checked for code before they are written.
    ///
    /// @custom:storage-location erc7201:lelantos.storage.Verifiers
    struct Layout {
        /// Verifier for `tree_update_batch.circom`, used by `flushBatch`.
        address treeUpdateBatchVerifier;
        /// Checks the `(4x6, tree_update_batch)` pair a spend carries, in one
        /// BN254 pairing call.
        address spendVerifier;
        address pendingTreeUpdateBatchVerifier;
        address pendingSpendVerifier;
        /// Earliest commit time. Set at queue to `now + UPGRADE_DELAY` and
        /// pushed out by any pause, so the window measures unpaused time the
        /// same way `activationAt` does.
        uint40 notBefore;
    }

    error ZeroVerifier();
    error BadSpendVerifier();

    /// Named `$` because `layout` is reserved for promotion to a keyword.
    function $() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly {
            l.slot := s
        }
    }

    // ============== Reads ====================================================
    //
    // The pool queries these rather than reaching into the struct, so the layout
    // stays confined to this file. They return the interface each caller uses,
    // so no call site restates the type of a slot it does not own.

    function treeUpdateBatchVerifier() internal view returns (IVerifier) {
        return IVerifier($().treeUpdateBatchVerifier);
    }

    function spendVerifier() internal view returns (IBatchVerifier) {
        return IBatchVerifier($().spendVerifier);
    }

    // ============== Validation ===============================================

    /// Both addresses hold code and the spend verifier answers `verifyBatch`.
    /// The pool's `initialize` calls this for the pair it starts with, and the
    /// proxy's `queueVerifierUpdate` for every pair after; neither accepts one
    /// that fails here.
    function validatePair(address treeUpdate, address spend) internal view {
        if (treeUpdate.code.length == 0) revert ZeroVerifier();
        if (spend.code.length == 0) revert ZeroVerifier();

        // Zero-valued probe arguments; memory is already zeroed. A wrong address
        // would otherwise make every spend revert with nothing identifying the
        // cause. The return value is ignored: the probe establishes the
        // interface, not a verdict.
        // slither-disable-next-line uninitialized-local
        uint256[2] memory g1;
        // slither-disable-next-line uninitialized-local
        uint256[2][2] memory g2;
        // slither-disable-next-line unused-return
        try IBatchVerifier(spend).verifyBatch(g1, g2, g1, g1, g1, g2, g1, g1) returns (bool) { }
        catch {
            revert BadSpendVerifier();
        }
    }
}
