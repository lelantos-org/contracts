// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { UpgradeStorage } from "../../src/UpgradeStorage.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";
import { VenueBinding } from "../../src/yield/YieldOps.sol";
import { VerifierStorage } from "../../src/VerifierStorage.sol";

/// ERC-7201 namespaced slots used by the pool under `delegatecall`. Each slot is
/// a literal constant, re-derived here so a transcription error cannot alias
/// another slot.
abstract contract NamespaceSlotTestBase is Test {
    /// The ERC-7201 slot for `namespace`:
    /// `keccak256(abi.encode(uint256(keccak256(namespace)) - 1)) & ~0xff`.
    function _erc7201Slot(string memory namespace) internal pure returns (bytes32) {
        uint256 inner = uint256(keccak256(bytes(namespace))) - 1;
        return keccak256(abi.encode(inner)) & ~bytes32(uint256(0xff));
    }

    /// Absolute distance between two slots.
    function _distance(bytes32 x, bytes32 y) internal pure returns (uint256) {
        uint256 a = uint256(x);
        uint256 b = uint256(y);
        return a > b ? a - b : b - a;
    }
}

contract UpgradeStorageTest is NamespaceSlotTestBase {
    function test_slotMatchesTheErc7201Derivation() public pure {
        bytes32 expected = _erc7201Slot("lelantos.storage.DelayedUpgrade");
        assertEq(UpgradeStorage.SLOT, expected, "slot constant drifted from its namespace");
    }

    /// ERC-7201 slots are 256-aligned, so the struct can grow within its
    /// namespace.
    function test_slotIsAligned() public pure {
        assertEq(uint256(UpgradeStorage.SLOT) & 0xff, 0);
    }

    /// The slot lies far above the sequential slots a pool implementation uses.
    function test_slotIsNowhereNearSequentialStorage() public pure {
        assertGt(uint256(UpgradeStorage.SLOT), 1e60);
    }
}

contract ExitTermsSlotTest is NamespaceSlotTestBase {
    function test_slotMatchesTheErc7201Derivation() public pure {
        bytes32 expected = _erc7201Slot("lelantos.storage.ExitTerms");
        assertEq(ExitTerms.SLOT, expected, "slot constant drifted from its namespace");
    }

    /// ERC-7201 slots are 256-aligned, so the struct can grow within its
    /// namespace.
    function test_slotIsAligned() public pure {
        assertEq(uint256(ExitTerms.SLOT) & 0xff, 0);
    }

    /// The slot lies far above the sequential slots a pool implementation uses.
    function test_slotIsNowhereNearSequentialStorage() public pure {
        assertGt(uint256(ExitTerms.SLOT), 1e60);
    }

    /// Both namespaces live in the pool's storage under `delegatecall`, so
    /// they must not overlap. A layout is at most a few slots wide.
    function test_slotIsClearOfTheUpgradeNamespace() public pure {
        assertGt(_distance(ExitTerms.SLOT, UpgradeStorage.SLOT), 1e60);
    }

    /// `Deploy.s.sol` bounds `upgradeDelay` by this, so a raise queued with an
    /// upgrade cannot land inside its window.
    function test_delayCoversTheLongestDeployableUpgradeWindow() public pure {
        assertEq(ExitTerms.DELAY, 30 days);
    }
}

contract VenueBindingSlotTest is NamespaceSlotTestBase {
    function test_slotMatchesTheErc7201Derivation() public pure {
        bytes32 expected = _erc7201Slot("lelantos.storage.VenueBinding");
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
        assertGt(_distance(VenueBinding.SLOT, ExitTerms.SLOT), 1e60, "ExitTerms");
        assertGt(_distance(VenueBinding.SLOT, UpgradeStorage.SLOT), 1e60, "UpgradeStorage");
    }
}

contract VerifierStorageSlotTest is NamespaceSlotTestBase {
    function test_slotMatchesTheErc7201Derivation() public pure {
        bytes32 expected = _erc7201Slot("lelantos.storage.Verifiers");
        assertEq(VerifierStorage.SLOT, expected, "slot constant drifted from its namespace");
    }

    /// ERC-7201 slots are 256-aligned, so the struct can grow within its
    /// namespace.
    function test_slotIsAligned() public pure {
        assertEq(uint256(VerifierStorage.SLOT) & 0xff, 0);
    }

    /// The slot lies far above the sequential slots a pool implementation uses.
    function test_slotIsNowhereNearSequentialStorage() public pure {
        assertGt(uint256(VerifierStorage.SLOT), 1e60);
    }

    /// Four namespaces now live in the pool's storage, and the proxy writes two
    /// of them in its own context. None may overlap.
    function test_slotIsClearOfTheOtherNamespaces() public pure {
        assertGt(_distance(VerifierStorage.SLOT, UpgradeStorage.SLOT), 1e60, "UpgradeStorage");
        assertGt(_distance(VerifierStorage.SLOT, ExitTerms.SLOT), 1e60, "ExitTerms");
        assertGt(_distance(VerifierStorage.SLOT, VenueBinding.SLOT), 1e60, "VenueBinding");
    }
}
