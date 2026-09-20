// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { UpgradeStorage } from "../../src/UpgradeStorage.sol";
import { VerifierStorage } from "../../src/VerifierStorage.sol";

import { MASPUpgradeTestBase } from "../utils/MASPUpgradeTestBase.sol";
import { PoolSlots } from "../utils/PoolSlots.sol";
import { MASPNext } from "../mocks/MASPNext.sol";

/// The pool's storage layout, pinned at the raw-slot level.
///
/// Behind a proxy the layout is the compatibility contract between versions:
/// inserting or reordering a variable in any base shifts everything below it.
/// The compiler cannot detect that across separately compiled implementations,
/// so it is asserted here. Upgrades may only append after the last slot.
contract StorageLayoutTest is MASPUpgradeTestBase {
    // The slot map itself lives in `utils/PoolSlots.sol`, so the suites that
    // read raw storage cannot drift apart from it. This suite is what pins it
    // against the live contract.

    function _slot(uint256 i) internal view returns (uint256) {
        return uint256(vm.load(address(proxy), bytes32(i)));
    }

    function test_ownerAndTreasuryOccupyExpectedSlots() public view {
        assertEq(address(uint160(_slot(PoolSlots.OWNER))), poolOwner, "owner moved off its slot");
        assertEq(address(uint160(_slot(PoolSlots.TREASURY))), treasury, "treasury moved off its slot");
    }

    /// Permit2 is held in storage so it survives an upgrade.
    function test_permit2AddressIsHeldInSequentialStorage() public view {
        assertEq(address(uint160(_slot(PoolSlots.PERMIT2))), permit2);
    }

    /// The verifiers are no longer in the sequential layout: they live in the
    /// `VerifierStorage` namespace, which the proxy writes and the pool reads,
    /// and the slots they used to occupy now hold what followed them.
    function test_verifiersAreInTheirNamespaceAndNotInSequentialStorage() public view {
        // Read from the proxy's storage: `$()` resolves against whatever
        // context it runs in, which here would be the test contract's own.
        bytes32 base = VerifierStorage.SLOT;
        address tub = address(uint160(uint256(vm.load(address(proxy), base))));
        address spend = address(uint160(uint256(vm.load(address(proxy), bytes32(uint256(base) + 1)))));
        assertEq(tub, address(tubVerifier), "tree-update verifier not in the namespace");
        assertEq(spend, address(batchVerifier), "spend verifier not in the namespace");

        assertEq(address(uint160(_slot(PoolSlots.PERMIT2))), permit2, "Permit2 did not shift up into slot 76");
        assertTrue(
            address(uint160(_slot(PoolSlots.ESCROWED))) != address(batchVerifier), "a verifier is still in the layout"
        );
    }

    /// `rootIndex` and `committedCount` share one slot; unpacking them would
    /// shift every slot below.
    function test_rootIndexAndCommittedCountStillShareOneSlot() public {
        bytes32 cm = bytes32(uint256(0x111));
        uint256 id = _deposit(1_000, cm, 0);
        _flush(id, 1_000, cm);

        uint256 packed = _slot(PoolSlots.PACKED_COUNTS);
        uint32 rootIndex = uint32(packed);
        uint64 committedCount = uint64(packed >> 32);

        assertEq(rootIndex, masp.rootIndex(), "rootIndex not at offset 0");
        assertEq(committedCount, masp.committedCount(), "committedCount not at offset 4");
        assertEq(committedCount, 2);
    }

    function test_scalarSlotsMatchTheirGetters() public {
        _deposit(1_000, bytes32(uint256(0x111)), 0);
        assertEq(_slot(PoolSlots.NEXT_DEPOSIT_ID), masp.nextDepositId(), "nextDepositId moved off its slot");
        assertEq(uint32(_slot(PoolSlots.CANCEL_DELAY)), masp.cancelDelay(), "cancelDelay moved off its slot");
    }

    /// The genesis root occupies the first element of `roots`, written by the
    /// initializer.
    function test_genesisRootIsInSlotZero() public view {
        assertEq(bytes32(_slot(PoolSlots.ROOTS)), masp.currentRoot());
    }

    // ============== Namespace isolation ======================================

    /// The exit-window state and the pool's sequential slots do not overlap in
    /// either direction.
    function test_poolStateDoesNotDisturbTheUpgradeNamespace() public {
        uint256 before = uint256(vm.load(address(proxy), UpgradeStorage.SLOT));
        assertEq(before, 0, "upgrade namespace dirty at rest");

        bytes32 cm = bytes32(uint256(0x111));
        uint256 id = _deposit(1_000, cm, 0);
        _flush(id, 1_000, cm);

        assertEq(
            uint256(vm.load(address(proxy), UpgradeStorage.SLOT)), 0, "pool activity wrote into the upgrade namespace"
        );
    }

    function test_upgradeStateDoesNotDisturbPoolStorage() public {
        bytes32 cm = bytes32(uint256(0x111));
        uint256 id = _deposit(1_000, cm, 0);
        _flush(id, 1_000, cm);

        uint256[6] memory watched = [
            PoolSlots.PACKED_COUNTS,
            PoolSlots.OWNER,
            PoolSlots.ASSETS,
            PoolSlots.TREASURY,
            PoolSlots.NEXT_DEPOSIT_ID,
            PoolSlots.CANCEL_DELAY
        ];
        uint256[6] memory before;
        for (uint256 i = 0; i < watched.length; ++i) {
            before[i] = _slot(watched[i]);
        }

        MASPNext next = new MASPNext();
        vm.prank(admin);
        proxy.queueUpgrade(address(next));
        vm.prank(admin);
        proxy.pauseSpends(1 days);

        for (uint256 i = 0; i < watched.length; ++i) {
            assertEq(_slot(watched[i]), before[i], "upgrade/pause state overwrote pool storage");
        }
        assertTrue(uint256(vm.load(address(proxy), UpgradeStorage.SLOT)) != 0, "namespace should now be populated");
    }

    /// Every slot is unchanged across an upgrade.
    function test_everySlotSurvivesAnUpgrade() public {
        bytes32 cm = bytes32(uint256(0x111));
        uint256 id = _deposit(1_000, cm, 0);
        _flush(id, 1_000, cm);

        // Dynamic: an array length must be a literal or a local constant
        // expression, which a library constant is not.
        uint256[] memory before = new uint256[](PoolSlots.END);
        for (uint256 i = 0; i < PoolSlots.END; ++i) {
            before[i] = _slot(i);
        }

        MASPNext next = new MASPNext();
        vm.prank(admin);
        proxy.queueUpgrade(address(next));
        vm.warp(T0 + UPGRADE_DELAY);
        proxy.activateUpgrade();

        for (uint256 i = 0; i < PoolSlots.END; ++i) {
            assertEq(_slot(i), before[i], "a pool slot changed across the upgrade");
        }
    }

    /// Slots beyond the layout are free, so an appending upgrade cannot alias
    /// state already in use.
    function test_appendedSlotsStartEmpty() public view {
        assertEq(_slot(PoolSlots.ESCROW_PULLED), 0, "a mapping root holds no value");
        assertEq(_slot(PoolSlots.END), 0, "slot after the layout is not free");
        assertEq(_slot(PoolSlots.END + 1), 0);
    }
}
