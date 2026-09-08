// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { UpgradeStorage } from "../../src/UpgradeStorage.sol";

/// The namespaced slot is a literal constant, re-derived here so a transcription
/// error cannot alias another slot.
contract UpgradeStorageTest is Test {
    function test_slotMatchesTheErc7201Derivation() public pure {
        uint256 inner = uint256(keccak256("lelantos.storage.DelayedUpgrade")) - 1;
        bytes32 expected = keccak256(abi.encode(inner)) & ~bytes32(uint256(0xff));
        assertEq(UpgradeStorage.SLOT, expected, "slot constant drifted from its namespace");
    }

    /// ERC-7201 slots are 256-aligned, so the struct can grow within its
    /// namespace.
    function test_slotIsAligned() public pure {
        assertEq(uint256(UpgradeStorage.SLOT) & 0xff, 0);
    }

    /// Well clear of the sequential slots a pool implementation uses.
    function test_slotIsNowhereNearSequentialStorage() public pure {
        assertGt(uint256(UpgradeStorage.SLOT), 1e60);
    }
}
