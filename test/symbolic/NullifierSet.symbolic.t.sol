// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";

import { NullifierSet } from "../../src/NullifierSet.sol";
import { NullifierSetHarness } from "../utils/NullifierSetHarness.sol";

/// Symbolic proofs for the packed-bitmap nullifier set.
///
/// `_spentBuckets[nf >> 8]` holds 256 bits keyed by `nf & 0xff`. Splitting a
/// 256-bit nullifier into a bucket and a bit position is exactly the kind of
/// aliasing bug a sampling fuzzer can miss: `test/fuzz/NullifierSet.fuzz.t.sol`
/// draws random pairs, while `check_consume_neverAffectsAnyOther` quantifies
/// over all 2^256 x 2^256 of them.
contract NullifierSetSymbolicTest is GuardAsserts {
    NullifierSetHarness internal nfs;

    function setUp() public {
        nfs = new NullifierSetHarness();
    }

    /// Nothing is spent before it is consumed, and consuming marks exactly it.
    function check_consume_marksSpent(bytes32 nf) public {
        assertFalse(nfs.spent(nf));
        nfs.consume(nf);
        assertTrue(nfs.spent(nf));
    }

    /// The core isolation property: consuming one nullifier leaves every other
    /// nullifier unspent. Covers same-bucket bit aliasing and cross-bucket
    /// collisions in one proof.
    function check_consume_neverAffectsAnyOther(bytes32 a, bytes32 b) public {
        vm.assume(a != b);
        nfs.consume(a);
        assertFalse(nfs.spent(b));
    }

    /// Two distinct nullifiers both stick, in either order.
    function check_consume_twoDistinctBothSpent(bytes32 a, bytes32 b) public {
        vm.assume(a != b);
        nfs.consume(a);
        nfs.consume(b);
        assertTrue(nfs.spent(a));
        assertTrue(nfs.spent(b));
    }

    /// Double-spend is unconditional: no nullifier value slips through a second
    /// consume, and the revert is `DoubleSpend` rather than an out-of-gas or a
    /// panic. A low-level call is used because halmos does not implement
    /// `vm.expectRevert`.
    function check_doubleConsume_alwaysRevertsDoubleSpend(bytes32 nf) public {
        nfs.consume(nf);
        (bool ok, bytes memory ret) = address(nfs).call(abi.encodeCall(NullifierSetHarness.consume, (nf)));
        _assertRejected(ok, ret, NullifierSet.DoubleSpend.selector);
    }

    /// Spent is permanent: no further consume of any other nullifier clears an
    /// existing one.
    ///
    /// The bitmap only ever ORs bits in, so nothing in the contract can unset
    /// one — but that is the property a double-spend depends on, and it is
    /// cheap to state over every pair rather than infer from reading the code.
    function check_spentIsMonotone(bytes32 a, bytes32 b) public {
        vm.assume(a != b);
        nfs.consume(a);
        assertTrue(nfs.spent(a));

        nfs.consume(b);

        assertTrue(nfs.spent(a), "an earlier nullifier stays spent");
        assertTrue(nfs.spent(b));
    }

    /// A second consume that reverts leaves the bitmap exactly as it was, so a
    /// caller that swallows the revert cannot un-spend anything.
    function check_doubleConsume_leavesOthersUnspent(bytes32 a, bytes32 b) public {
        vm.assume(a != b);
        nfs.consume(a);
        (bool ok,) = address(nfs).call(abi.encodeCall(NullifierSetHarness.consume, (a)));
        assertFalse(ok);
        assertTrue(nfs.spent(a));
        assertFalse(nfs.spent(b));
    }
}
