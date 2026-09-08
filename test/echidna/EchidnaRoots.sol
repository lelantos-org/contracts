// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { SnarkCompression } from "../../src/SnarkCompression.sol";

/// Root values for the Echidna targets.
///
/// Both targets stub the tree-update verifier, so the new root a flush or a
/// spend publishes is unconstrained — but not arbitrary. `flushBatch` and
/// `withdraw` compress the batch header through
/// `SnarkCompression.evaluatePolyAt`, which rejects any coefficient at or
/// above the BN254 scalar field. A raw keccak clears that field about 22% of
/// the time, so an unreduced root makes the call fail for a reason that has
/// nothing to do with the state machine under test — and, because every
/// handler swallows its revert, fail silently.
///
/// Centralised here because seven call sites across the two targets were each
/// restating the reduction, and a site that forgot it would not announce
/// itself: the sequence would simply never settle.
library EchidnaRoots {
    /// A fresh root derived from `salt`, reduced into the scalar field.
    ///
    /// Derived from live state at the call site rather than from a counter, so
    /// that distinct flushes publish distinct roots and the ring advances the
    /// way it would in production.
    function fresh(bytes memory salt) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(salt)) % SnarkCompression.R);
    }
}
