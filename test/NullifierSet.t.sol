// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { NullifierSet } from "../src/NullifierSet.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MASPHarness } from "./invariant/MASPHarness.sol";

/// Unit tests for `NullifierSet` bitmap storage via `MASPHarness`.
/// Covers double-spend, bucket isolation, and full-bucket exhaustion.
contract NullifierSetTest is Test {
    MASPHarness harness;

    function setUp() public {
        IVerifier v = IVerifier(address(new MockERC20("v", "v", 18)));
        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        address permit2 = new DeployPermit2().deployPermit2();
        harness = new MASPHarness(v, tub, ISignatureTransfer(address(permit2)), address(0xfee), address(this));
    }

    function test_unspent_beforeConsume() public view {
        assertFalse(harness.spent(bytes32(uint256(1))));
    }

    function test_spent_afterConsume() public {
        bytes32 nf = bytes32(uint256(0xdeadbeef));
        harness.consumeNullifierExternal(nf);
        assertTrue(harness.spent(nf));
    }

    function test_doubleSpend_reverts() public {
        bytes32 nf = bytes32(uint256(0xdeadbeef));
        harness.consumeNullifierExternal(nf);
        vm.expectRevert(NullifierSet.DoubleSpend.selector);
        harness.consumeNullifierExternal(nf);
    }

    function test_distinctNullifiers_independent() public {
        bytes32 nf1 = bytes32(uint256(100));
        bytes32 nf2 = bytes32(uint256(200));
        harness.consumeNullifierExternal(nf1);
        assertFalse(harness.spent(nf2));
        harness.consumeNullifierExternal(nf2);
        assertTrue(harness.spent(nf1));
        assertTrue(harness.spent(nf2));
    }

    /// Two nfs sharing the same bucket (`nf >> 8` identical) but different
    /// bit positions (`nf & 0xff` distinct) must not interfere.
    function test_sameBucket_differentBits_isolated() public {
        bytes32 nf1 = bytes32(uint256(256)); // bucket 1, bit 0
        bytes32 nf2 = bytes32(uint256(257)); // bucket 1, bit 1
        harness.consumeNullifierExternal(nf1);
        assertFalse(harness.spent(nf2), "nf2 unaffected by nf1");
        harness.consumeNullifierExternal(nf2);
        assertTrue(harness.spent(nf1));
        assertTrue(harness.spent(nf2));
    }

    /// Cross-bucket: consuming a nf in bucket A doesn't touch bucket B.
    function test_crossBucket_independent() public {
        bytes32 nfA = bytes32(uint256(0)); // bucket 0, bit 0
        bytes32 nfB = bytes32(uint256(256)); // bucket 1, bit 0
        harness.consumeNullifierExternal(nfA);
        assertFalse(harness.spent(nfB));
    }

    /// Maximum bit position (bit 255 of a bucket) works correctly.
    function test_maxBitPosition() public {
        bytes32 nf = bytes32(uint256(255)); // bucket 0, bit 255
        harness.consumeNullifierExternal(nf);
        assertTrue(harness.spent(nf));
        vm.expectRevert(NullifierSet.DoubleSpend.selector);
        harness.consumeNullifierExternal(nf);
    }

    /// All 256 bits of one bucket independently settable; no overflow into
    /// adjacent bits.
    function test_allBitsInOneBucket() public {
        uint256 bucket = 3;
        for (uint256 bit = 0; bit < 256; bit++) {
            bytes32 nf = bytes32((bucket << 8) | bit);
            harness.consumeNullifierExternal(nf);
        }
        for (uint256 bit = 0; bit < 256; bit++) {
            bytes32 nf = bytes32((bucket << 8) | bit);
            assertTrue(harness.spent(nf));
        }
        // Adjacent bucket untouched.
        assertFalse(harness.spent(bytes32(((bucket + 1) << 8) | 0)));
    }
}
