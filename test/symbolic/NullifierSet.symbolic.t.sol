// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";

import { NullifierSet } from "../../src/NullifierSet.sol";
import { NullifierSetHarness } from "../utils/NullifierSetHarness.sol";

/// Symbolic proofs for the packed-bitmap nullifier set.
///
/// `_spentBuckets[nf >> 8]` holds 256 bits keyed by `nf & 0xff`. Splitting a
/// nullifier into bucket and bit position can introduce aliasing that random
/// sampling misses: `test/fuzz/NullifierSet.fuzz.t.sol` draws random pairs, while
/// `check_consume_neverAffectsAnyOther` quantifies over all pairs.
contract NullifierSetSymbolicTest is GuardAsserts {
    NullifierSetHarness internal nfs;

    function setUp() public {
        nfs = new NullifierSetHarness();
    }

    /// A nullifier is unspent before consumption and spent after.
    function check_consume_marksSpent(bytes32 nf) public {
        assertFalse(nfs.spent(nf));
        nfs.consume(nf);
        assertTrue(nfs.spent(nf));
    }

    /// Isolation: consuming one nullifier leaves every other nullifier unspent,
    /// covering both same-bucket bit aliasing and cross-bucket collisions.
    function check_consume_neverAffectsAnyOther(bytes32 a, bytes32 b) public {
        vm.assume(a != b);
        nfs.consume(a);
        assertFalse(nfs.spent(b));
    }

    /// Two distinct consumed nullifiers are both spent.
    function check_consume_twoDistinctBothSpent(bytes32 a, bytes32 b) public {
        vm.assume(a != b);
        nfs.consume(a);
        nfs.consume(b);
        assertTrue(nfs.spent(a));
        assertTrue(nfs.spent(b));
    }

    /// A second consume of any nullifier reverts with `DoubleSpend`, not an
    /// out-of-gas or panic. A low-level call is used because halmos does not
    /// implement `vm.expectRevert`.
    function check_doubleConsume_alwaysRevertsDoubleSpend(bytes32 nf) public {
        nfs.consume(nf);
        (bool ok, bytes memory ret) = address(nfs).call(abi.encodeCall(NullifierSetHarness.consume, (nf)));
        _assertRejected(ok, ret, NullifierSet.DoubleSpend.selector);
    }

    /// Spent is permanent: consuming another nullifier does not clear an
    /// existing one.
    ///
    /// The bitmap only ORs bits in; double-spend protection depends on this, so
    /// it is proved over every pair.
    function check_spentIsMonotone(bytes32 a, bytes32 b) public {
        vm.assume(a != b);
        nfs.consume(a);
        assertTrue(nfs.spent(a));

        nfs.consume(b);

        assertTrue(nfs.spent(a), "an earlier nullifier stays spent");
        assertTrue(nfs.spent(b));
    }

    /// A reverted second consume leaves `a` spent and `b` unspent, so a caller
    /// that swallows the revert cannot change spent state.
    function check_doubleConsume_leavesOthersUnspent(bytes32 a, bytes32 b) public {
        vm.assume(a != b);
        nfs.consume(a);
        (bool ok,) = address(nfs).call(abi.encodeCall(NullifierSetHarness.consume, (a)));
        assertFalse(ok);
        assertTrue(nfs.spent(a));
        assertFalse(nfs.spent(b));
    }
}
