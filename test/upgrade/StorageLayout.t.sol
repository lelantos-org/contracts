// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { UpgradeStorage } from "../../src/UpgradeStorage.sol";

import { MASPUpgradeTestBase } from "../utils/MASPUpgradeTestBase.sol";
import { MASPNext } from "../mocks/MASPNext.sol";

/// The pool's storage layout, pinned at the raw-slot level.
///
/// Behind a proxy the layout is the compatibility contract between versions:
/// inserting or reordering a variable in any base shifts everything below it.
/// The compiler cannot detect that across separately-compiled implementations,
/// so it is asserted here. Upgrades may only append after the last slot.
contract StorageLayoutTest is MASPUpgradeTestBase {
    uint256 internal constant SLOT_ROOTS = 0; // bytes32[64] -> slots 0..63
    uint256 internal constant SLOT_PACKED_COUNTS = 64; // rootIndex | committedCount
    uint256 internal constant SLOT_IS_KNOWN_ROOT = 65;
    uint256 internal constant SLOT_OWNER = 66;
    uint256 internal constant SLOT_ASSETS = 67;
    uint256 internal constant SLOT_SPENT_BUCKETS = 68;
    uint256 internal constant SLOT_TREASURY = 69;
    uint256 internal constant SLOT_ACCRUED_FEE = 70;
    uint256 internal constant SLOT_YIELD_STORE = 71; // 5 slots, 71..75
    // Verifier and Permit2 addresses.
    uint256 internal constant SLOT_TUB_VERIFIER = 76;
    uint256 internal constant SLOT_SPEND_VERIFIER = 77;
    uint256 internal constant SLOT_PERMIT2 = 78;
    uint256 internal constant SLOT_ESCROWED = 79;
    uint256 internal constant SLOT_NEXT_DEPOSIT_ID = 80;
    uint256 internal constant SLOT_CANCEL_DELAY = 81;

    function _slot(uint256 i) internal view returns (uint256) {
        return uint256(vm.load(address(proxy), bytes32(i)));
    }

    function test_ownerAndTreasuryOccupyExpectedSlots() public view {
        assertEq(address(uint160(_slot(SLOT_OWNER))), poolOwner, "owner moved off slot 66");
        assertEq(address(uint160(_slot(SLOT_TREASURY))), treasury, "treasury moved off slot 69");
    }

    /// The verifier and Permit2 addresses, held in storage so they survive an
    /// upgrade.
    function test_verifierAddressesAreStateAtSlots76To78() public view {
        assertEq(address(uint160(_slot(SLOT_TUB_VERIFIER))), address(tubVerifier));
        assertEq(address(uint160(_slot(SLOT_SPEND_VERIFIER))), address(batchVerifier));
        assertEq(address(uint160(_slot(SLOT_PERMIT2))), permit2);
    }

    /// `rootIndex` and `committedCount` share one slot; unpacking them would
    /// shift every slot below.
    function test_rootIndexAndCommittedCountStillShareOneSlot() public {
        bytes32 cm = bytes32(uint256(0x111));
        uint256 id = _deposit(1_000, cm, 0);
        _flush(id, 1_000, cm);

        uint256 packed = _slot(SLOT_PACKED_COUNTS);
        uint32 rootIndex = uint32(packed);
        uint64 committedCount = uint64(packed >> 32);

        assertEq(rootIndex, masp.rootIndex(), "rootIndex not at offset 0");
        assertEq(committedCount, masp.committedCount(), "committedCount not at offset 4");
        assertEq(committedCount, 2);
    }

    function test_scalarSlotsMatchTheirGetters() public {
        _deposit(1_000, bytes32(uint256(0x111)), 0);
        assertEq(_slot(SLOT_NEXT_DEPOSIT_ID), masp.nextDepositId(), "nextDepositId moved off slot 77");
        assertEq(uint32(_slot(SLOT_CANCEL_DELAY)), masp.cancelDelay(), "cancelDelay moved off slot 78");
    }

    /// The genesis root occupies the first element of `roots`, written by the
    /// initializer.
    function test_genesisRootIsInSlotZero() public view {
        assertEq(bytes32(_slot(SLOT_ROOTS)), masp.currentRoot());
    }

    // ============== Namespace isolation ======================================

    /// The exit-window state and the pool's sequential slots must not overlap in
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

        uint256[6] memory watched =
            [SLOT_PACKED_COUNTS, SLOT_OWNER, SLOT_ASSETS, SLOT_TREASURY, SLOT_NEXT_DEPOSIT_ID, SLOT_CANCEL_DELAY];
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

        uint256[82] memory before;
        for (uint256 i = 0; i < 82; ++i) {
            before[i] = _slot(i);
        }

        MASPNext next = new MASPNext();
        vm.prank(admin);
        proxy.queueUpgrade(address(next));
        vm.warp(T0 + UPGRADE_DELAY);
        proxy.activateUpgrade();

        for (uint256 i = 0; i < 82; ++i) {
            assertEq(_slot(i), before[i], "a pool slot changed across the upgrade");
        }
    }

    /// Slots beyond the layout are free, so an appending upgrade cannot alias
    /// state already in use.
    function test_appendedSlotsStartEmpty() public view {
        assertEq(_slot(82), 0, "slot after the layout is not free");
        assertEq(_slot(83), 0);
    }
}
