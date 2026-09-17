// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FeeBurnerTestBase } from "./FeeBurnerTestBase.sol";

/// The `FeeBurner` asking price: halving decay with its `maxHalvings` and floor
/// clamps, and the per-lot snapshot of the decay curve that keeps a change to
/// the globals from repricing a running lot.
contract FeeBurnerPriceTest is FeeBurnerTestBase {
    // ============== Price curve ==============================================

    function test_priceStartsAtSeedAndHalvesEachHalfLife() public {
        _enableLot();
        assertEq(burner.priceOf(IERC20(address(token))), SEED_PRICE, "t=0");

        vm.warp(T0 + HALF_LIFE);
        assertEq(burner.priceOf(IERC20(address(token))), SEED_PRICE / 2, "one half-life");

        vm.warp(T0 + 2 * uint256(HALF_LIFE));
        assertEq(burner.priceOf(IERC20(address(token))), SEED_PRICE / 4, "two half-lives");
    }

    /// Halfway through a period the linear interpolation sits at three quarters,
    /// so the curve is continuous across each halving boundary.
    function test_priceInterpolatesWithinAPeriod() public {
        _enableLot();
        vm.warp(T0 + HALF_LIFE / 2);
        assertEq(burner.priceOf(IERC20(address(token))), SEED_PRICE - (SEED_PRICE / 2) / 2);
    }

    /// Two independent clamps bound decay, and the tighter one applies. Here
    /// `maxHalvings` binds, because 12 halvings of the seed is above the floor.
    function test_priceStopsDecayingAtMaxHalvings() public {
        _enableLot();
        vm.warp(T0 + 365 days);
        uint256 floorFromHalvings = SEED_PRICE >> MAX_HALVINGS;
        assertGt(floorFromHalvings, MIN_PRICE, "this test is only meaningful while halvings bind first");
        assertEq(burner.priceOf(IERC20(address(token))), floorFromHalvings, "decayed past the halving clamp");
    }

    /// When the floor is the tighter clamp, the floor binds.
    function test_priceClampsAtMinPriceWhenItBindsFirst() public {
        uint256 highFloor = SEED_PRICE / 2;
        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(token)), true, SEED_PRICE, highFloor, MIN_LOT);

        vm.warp(T0 + 365 days);
        assertEq(burner.priceOf(IERC20(address(token))), highFloor, "must not decay below the floor");
    }

    function test_priceIsZeroForDisabledLot() public view {
        assertEq(burner.priceOf(IERC20(address(token))), 0);
    }

    function testFuzz_priceIsMonotonicallyNonIncreasing(uint32 a, uint32 b) public {
        _enableLot();
        uint256 ta = T0 + uint256(a);
        uint256 tb = T0 + uint256(a) + uint256(b);
        vm.warp(ta);
        uint256 pa = burner.priceOf(IERC20(address(token)));
        vm.warp(tb);
        uint256 pb = burner.priceOf(IERC20(address(token)));
        assertLe(pb, pa, "price rose with time");
    }

    // ============== Decay curve snapshot =====================================

    /// `setLot` copies the global curve into the lot, and later changes to the
    /// globals leave that copy alone until the lot is set again.
    function test_setLotSnapshotsDecayParams() public {
        vm.prank(timelockOwner);
        burner.setDecayParams(120, 5, RESTART_MULT_BPS);
        _enableLot();

        (,, uint32 halfLife, uint8 maxHalvings) = _lotClock();
        assertEq(halfLife, 120, "halfLife not snapshotted");
        assertEq(maxHalvings, 5, "maxHalvings not snapshotted");

        vm.prank(timelockOwner);
        burner.setDecayParams(7200, 20, RESTART_MULT_BPS);
        (,, halfLife, maxHalvings) = _lotClock();
        assertEq(halfLife, 120, "a global change reached the running lot");
        assertEq(maxHalvings, 5, "a global change reached the running lot");

        vm.warp(T0 + 120);
        assertEq(burner.priceOf(IERC20(address(token))), SEED_PRICE / 2, "lot did not decay on its own curve");

        // Re-seeding picks up the globals in force at that moment.
        _enableLot();
        uint256 startPrice;
        uint48 startedAt;
        (startPrice, startedAt, halfLife, maxHalvings) = _lotClock();
        assertEq(halfLife, 7200);
        assertEq(maxHalvings, 20);
        assertEq(startedAt, uint48(T0 + 120));
        assertEq(burner.priceOf(IERC20(address(token))), SEED_PRICE);
    }

    /// Shortening the half-life does not reprice a lot already decaying. Applied
    /// retroactively, 1800 s at a 60 s half-life would count as 30 halvings and
    /// drop the price to the `maxHalvings` clamp in one block for whoever buys
    /// next.
    function test_setDecayParamsDoesNotRepriceARunningLot() public {
        _seedBurner(10e18);
        _enableLot();
        vm.warp(T0 + 1800);
        uint256 before = burner.priceOf(IERC20(address(token)));
        assertEq(before, SEED_PRICE - SEED_PRICE / 4, "fixture: halfway through the first half-life");

        vm.prank(timelockOwner);
        burner.setDecayParams(60, MAX_HALVINGS, RESTART_MULT_BPS);
        assertEq(burner.priceOf(IERC20(address(token))), before, "setDecayParams repriced a running lot");

        // The lot keeps its anchored curve going forward, and a bidder pays on it.
        vm.warp(T0 + HALF_LIFE);
        assertEq(burner.priceOf(IERC20(address(token))), SEED_PRICE / 2, "lot left its anchored curve");
        vm.prank(bidder);
        uint256 govIn = burner.buy(IERC20(address(token)), MIN_LOT, type(uint256).max, bidder);
        assertEq(govIn, uint256(MIN_LOT) * (SEED_PRICE / 2) / 1e18, "bidder paid on the new curve");
    }

    /// A re-anchoring fill adopts the globals in force at the fill, so a curve
    /// change reaches a running lot at its next eligible fill.
    function test_newDecayParamsApplyAfterReanchor() public {
        _seedBurner(10e18);
        _enableLot();
        vm.warp(T0 + 1800);
        vm.prank(timelockOwner);
        burner.setDecayParams(60, 4, RESTART_MULT_BPS);
        uint256 clearing = burner.priceOf(IERC20(address(token)));

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), 5e18, type(uint256).max, bidder); // half fill

        (uint256 startPrice, uint48 startedAt, uint32 halfLife, uint8 maxHalvings) = _lotClock();
        assertEq(startPrice, clearing * 15_000 / 10_000, "half fill must apply half the ratchet");
        assertEq(startedAt, uint48(T0 + 1800), "clock not restarted");
        assertEq(halfLife, 60, "re-anchor did not adopt the new halfLife");
        assertEq(maxHalvings, 4, "re-anchor did not adopt the new maxHalvings");

        vm.warp(T0 + 1800 + 60);
        assertEq(burner.priceOf(IERC20(address(token))), startPrice / 2, "new halfLife not in force");
        vm.warp(T0 + 1800 + 365 days);
        assertEq(burner.priceOf(IERC20(address(token))), startPrice >> 4, "new maxHalvings not in force");
    }

    /// Absent a fill that re-anchors, nothing raises the asking price: not time,
    /// not a clearing dust fill, and not a change to the global decay curve.
    function testFuzz_priceNeverRisesAbsentAnEligibleFill(
        uint32 wait1,
        uint32 wait2,
        uint128 dust,
        uint32 newHalfLife,
        uint8 newMaxHalvings
    ) public {
        dust = uint128(bound(dust, 1, MIN_LOT - 1));
        newHalfLife = uint32(bound(newHalfLife, 1, type(uint32).max));
        newMaxHalvings = uint8(bound(newMaxHalvings, 1, 32));
        _enableLot();

        vm.warp(T0 + uint256(wait1));
        uint256 p1 = burner.priceOf(IERC20(address(token)));

        vm.prank(timelockOwner);
        burner.setDecayParams(newHalfLife, newMaxHalvings, RESTART_MULT_BPS);
        assertEq(burner.priceOf(IERC20(address(token))), p1, "setDecayParams moved the price");

        _seedBurner(dust);
        vm.prank(bidder);
        burner.buy(IERC20(address(token)), dust, type(uint256).max, bidder);
        assertEq(burner.priceOf(IERC20(address(token))), p1, "a clearing dust fill moved the price");

        vm.warp(T0 + uint256(wait1) + uint256(wait2));
        assertLe(burner.priceOf(IERC20(address(token))), p1, "price rose with time");
    }
}
