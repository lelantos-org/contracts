// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { NullifierSet } from "../../src/NullifierSet.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MASPHarness } from "../invariant/MASPHarness.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { MASP } from "../../src/MASP.sol";

/// Property-based tests for the packed-bitmap nullifier set.
contract NullifierSetFuzzTest is Test {
    MASPHarness harness;

    function setUp() public {
        IVerifier v = IVerifier(address(new MockERC20("v", "v", 18)));
        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        MockBatchVerifier bv = new MockBatchVerifier();
        address permit2 = new DeployPermit2().deployPermit2();
        harness = new MASPHarness(tub, bv, ISignatureTransfer(address(permit2)), address(0xfee), address(this));
    }

    // --- Core properties ---------------------------------------------------

    /// `spent(nf)` is false before consume and true after for any nf.
    function testFuzz_consumeSetsBit(bytes32 nf) public {
        assertFalse(harness.spent(nf));
        harness.consumeNullifierExternal(nf);
        assertTrue(harness.spent(nf));
    }

    /// Double-consume always reverts with DoubleSpend.
    function testFuzz_doubleConsume_reverts(bytes32 nf) public {
        harness.consumeNullifierExternal(nf);
        vm.expectRevert(NullifierSet.DoubleSpend.selector);
        harness.consumeNullifierExternal(nf);
    }

    // --- Bit isolation properties ------------------------------------------

    /// Consuming nf1 does not affect nf2 when they share a bucket but differ
    /// in bit position.
    function testFuzz_sameBucket_bitIsolation(uint248 bucketTop, uint8 bit1, uint8 bit2) public {
        vm.assume(bit1 != bit2);
        // Construct nfs with identical top 248 bits (same bucket) but different bottom 8 bits.
        bytes32 nf1 = bytes32((uint256(bucketTop) << 8) | uint256(bit1));
        bytes32 nf2 = bytes32((uint256(bucketTop) << 8) | uint256(bit2));
        harness.consumeNullifierExternal(nf1);
        assertFalse(harness.spent(nf2), "bit isolation: nf2 unaffected");
    }

    /// Consuming nf1 in bucket A does not affect nf2 in bucket B (different top bits).
    function testFuzz_differentBucket_isolation(uint248 bucketA, uint248 bucketB, uint8 bit) public {
        vm.assume(bucketA != bucketB);
        bytes32 nf1 = bytes32((uint256(bucketA) << 8) | uint256(bit));
        bytes32 nf2 = bytes32((uint256(bucketB) << 8) | uint256(bit));
        harness.consumeNullifierExternal(nf1);
        assertFalse(harness.spent(nf2), "cross-bucket isolation");
    }

    /// Two distinct nfs can both be consumed independently, with no interference.
    function testFuzz_twoDistinctNullifiers_bothConsumed(bytes32 nf1, bytes32 nf2) public {
        vm.assume(nf1 != nf2);
        harness.consumeNullifierExternal(nf1);
        harness.consumeNullifierExternal(nf2);
        assertTrue(harness.spent(nf1));
        assertTrue(harness.spent(nf2));
    }

    // --- Edge values -------------------------------------------------------

    /// Null bytes32 (0x00...00) can be consumed normally.
    function testFuzz_zeroNullifier() public {
        bytes32 nf = bytes32(0);
        assertFalse(harness.spent(nf));
        harness.consumeNullifierExternal(nf);
        assertTrue(harness.spent(nf));
        vm.expectRevert(NullifierSet.DoubleSpend.selector);
        harness.consumeNullifierExternal(nf);
    }

    /// Max bytes32 (0xFF...FF) can be consumed normally.
    function testFuzz_maxNullifier() public {
        bytes32 nf = bytes32(type(uint256).max);
        assertFalse(harness.spent(nf));
        harness.consumeNullifierExternal(nf);
        assertTrue(harness.spent(nf));
        vm.expectRevert(NullifierSet.DoubleSpend.selector);
        harness.consumeNullifierExternal(nf);
    }
}
