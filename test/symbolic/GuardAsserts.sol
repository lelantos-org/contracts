// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

/// The assertion every rejection proof in this suite ends with.
///
/// Almost every property here proves a *rejection* — `README.md` explains why:
/// a guard that reverts is cheap to explore, while its accepting counterpart
/// usually runs `PubInputs.compress` and no solver here finishes. So the suite
/// is built out of one shape, repeated: make the call low-level, assert it
/// failed, and pin the selector it failed with.
///
/// Pinning the selector is not decoration. `README.md` records the trap it
/// exists for: `assertFalse(ok)` alone is satisfied by a fixture that reverts
/// for an unrelated reason — a drifted constant, an exhausted role, a stand-in
/// with no such function — and on a proof that explores a single path, that is
/// invisible. Every rejection in this suite names its selector so a fixture
/// that stops being valid fails instead of passing vacuously.
///
/// This lived on `PoolFixture` first, which put it out of reach of the nine
/// suites that deploy no pool; they each re-spelled the two assertions inline.
/// It is a base contract rather than a library because both assertions come
/// from forge-std's `Test`, which a library cannot inherit.
///
/// The name deliberately contains no `Symbolic`, for the same reason
/// `PoolFixture`'s does not: `match-contract` in `halmos.toml` scopes a run to
/// contracts matching that word, and shared scaffolding is not a test.
abstract contract GuardAsserts is Test {
    /// Assert that a low-level call was rejected, and by the guard under test
    /// rather than by something else on the way there.
    function _assertRejected(bool ok, bytes memory ret, bytes4 expected) internal pure {
        _assertRejected(ok, ret, expected, "rejected by the guard under test");
    }

    /// The same, carrying what the call was expected to be refused for. Worth
    /// spelling out wherever the failure would otherwise read as a fixture
    /// problem — most of the access-control and identity proofs do.
    function _assertRejected(bool ok, bytes memory ret, bytes4 expected, string memory why) internal pure {
        assertFalse(ok, why);
        assertEq(bytes4(ret), expected, why);
    }
}
