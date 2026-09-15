// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { VenueBinding } from "../../src/yield/YieldOps.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";
import { UpgradeStorage } from "../../src/UpgradeStorage.sol";

/// The namespaced slot is a literal constant, re-derived here so a transcription
/// error cannot alias another slot.
contract VenueBindingSlotTest is Test {
    function test_slotMatchesTheErc7201Derivation() public pure {
        uint256 inner = uint256(keccak256("lelantos.storage.VenueBinding")) - 1;
        bytes32 expected = keccak256(abi.encode(inner)) & ~bytes32(uint256(0xff));
        assertEq(VenueBinding.SLOT, expected, "slot constant drifted from its namespace");
    }

    /// ERC-7201 slots are 256-aligned, so the struct can grow within its
    /// namespace.
    function test_slotIsAligned() public pure {
        assertEq(uint256(VenueBinding.SLOT) & 0xff, 0);
    }

    /// The slot lies far above the sequential slots a pool implementation uses.
    function test_slotIsNowhereNearSequentialStorage() public pure {
        assertGt(uint256(VenueBinding.SLOT), 1e60);
    }

    /// All three namespaces live in the pool's storage, so none may overlap. A
    /// layout is at most a few slots wide.
    function test_slotIsClearOfTheOtherNamespaces() public pure {
        uint256 a = uint256(VenueBinding.SLOT);
        uint256 b = uint256(ExitTerms.SLOT);
        uint256 c = uint256(UpgradeStorage.SLOT);
        assertGt(a > b ? a - b : b - a, 1e60, "ExitTerms");
        assertGt(a > c ? a - c : c - a, 1e60, "UpgradeStorage");
    }
}
