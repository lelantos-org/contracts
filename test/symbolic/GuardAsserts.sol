// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

/// Shared assertion for rejection proofs in this suite.
///
/// Most properties here prove a rejection (see `README.md`): a reverting guard is
/// cheap to explore, while the accepting path usually runs `PubInputs.compress`,
/// which the solvers do not finish. Each proof makes a low-level call, asserts it
/// failed, and pins the revert selector.
///
/// `assertFalse(ok)` alone is satisfied by a fixture that reverts for an
/// unrelated reason (a stale constant, a missing role, a stand-in lacking the
/// function), which a single-path proof cannot distinguish. Pinning the selector
/// makes an invalid fixture fail instead of passing vacuously.
///
/// A base contract rather than a library, because the assertions come from
/// forge-std's `Test`.
///
/// The name omits `Symbolic`, as does `PoolFixture`: `match-contract` in
/// `halmos.toml` selects contracts matching that word, and shared scaffolding is
/// not a test.
abstract contract GuardAsserts is Test {
    /// Asserts that a low-level call reverted with the `expected` selector.
    function _assertRejected(bool ok, bytes memory ret, bytes4 expected) internal pure {
        _assertRejected(ok, ret, expected, "rejected by the guard under test");
    }

    /// As above, with a failure message `why` describing the expected rejection.
    function _assertRejected(bool ok, bytes memory ret, bytes4 expected, string memory why) internal pure {
        assertFalse(ok, why);
        assertEq(bytes4(ret), expected, why);
    }
}
