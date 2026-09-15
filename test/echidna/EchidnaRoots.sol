// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { SnarkCompression } from "../../src/SnarkCompression.sol";

/// Root values for the Echidna targets.
///
/// Both targets stub the tree-update verifier, so the new root a flush or a
/// spend publishes is unconstrained but must still be a field element.
/// `flushBatch` and `withdraw` compress the batch header through
/// `SnarkCompression.evaluatePolyAt`, which rejects any coefficient at or
/// above the BN254 scalar field. A raw keccak is at or above that modulus about
/// 81% of the time, so an unreduced root makes the call revert for a reason
/// unrelated to the state machine under test, and since reverting handler calls
/// are tolerated, the failure is silent.
///
/// Every call site uses this helper so none can omit the reduction.
library EchidnaRoots {
    /// A fresh root derived from `salt`, reduced into the scalar field.
    ///
    /// Callers derive `salt` from live state rather than a counter, so distinct
    /// flushes publish distinct roots and the ring advances as in production.
    function fresh(bytes memory salt) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(salt)) % SnarkCompression.R);
    }
}
