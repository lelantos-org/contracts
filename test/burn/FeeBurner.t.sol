// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { FeeBurner } from "../../src/burn/FeeBurner.sol";

import { FeeBurnerTestBase } from "./FeeBurnerTestBase.sol";

contract FeeBurnerTest is FeeBurnerTestBase {
    // ============== Integration ==============================================

    /// Fees reach the burner without pool changes: `sweep` is permissionless and
    /// pays `treasury`. Driven through a real deposit and flush, so the accrual
    /// comes from `FeeConfig._accrueFee` at its production call site.
    function test_permissionlessSweepDeliversRealFeesToTheBurner() public {
        uint256 fee = _accrueRealFees(1_000);
        assertGt(fee, 0, "fixture must accrue something");
        assertEq(masp.accruedFee(IERC20(address(token))), fee, "fee accrued at flush");
        assertEq(token.balanceOf(address(burner)), 0, "nothing swept yet");

        // An unrelated party sweeps; the destination is fixed to `treasury`.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        masp.sweep(IERC20(address(token)));

        assertEq(token.balanceOf(address(burner)), fee, "burner did not receive the fees");
        assertEq(masp.accruedFee(IERC20(address(token))), 0, "accrual not cleared");
        assertEq(token.balanceOf(stranger), 0, "sweeper must not be paid");
    }

    function test_harvestPullsFeesFromRegisteredPools() public {
        uint256 fee = _accrueRealFees(1_000);
        address[] memory p = new address[](1);
        p[0] = address(masp);
        vm.prank(timelockOwner);
        burner.setPools(p);

        burner.harvest(IERC20(address(token)));
        assertEq(token.balanceOf(address(burner)), fee);
    }

    /// A reverting pool does not block harvesting from the others.
    function test_harvestSkipsFailingPools() public {
        uint256 fee = _accrueRealFees(1_000);
        address[] memory p = new address[](2);
        p[0] = makeAddr("notAPool");
        p[1] = address(masp);
        vm.prank(timelockOwner);
        burner.setPools(p);

        burner.harvest(IERC20(address(token)));
        assertEq(token.balanceOf(address(burner)), fee);
    }

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

    // ============== buy ======================================================

    function test_buyBurnsExactlyWhatWasPaid() public {
        _seedBurner(10e18);
        _enableLot();

        uint256 supplyBefore = gov.totalSupply();
        uint256 expectedGov = 1e18 * SEED_PRICE / 1e18;

        vm.prank(bidder);
        uint256 govIn = burner.buy(IERC20(address(token)), 1e18, type(uint256).max, bidder);

        assertEq(govIn, expectedGov, "priced wrong");
        assertEq(gov.totalSupply(), supplyBefore - expectedGov, "supply did not drop by the full payment");
        assertEq(token.balanceOf(bidder), 1e18, "bidder did not receive the lot");
        assertEq(gov.balanceOf(address(burner)), 0, "burner must hold no GOV between calls");
        assertEq(gov.totalBurned(), expectedGov);
    }

    function test_buySendsRemainderToSecondaryTreasuryWhenBurnBpsIsPartial() public {
        address treasury = makeAddr("secondary");
        vm.startPrank(timelockOwner);
        burner.setSecondaryTreasury(treasury);
        burner.setBurnBps(6_000);
        vm.stopPrank();

        _seedBurner(10e18);
        _enableLot();

        uint256 supplyBefore = gov.totalSupply();
        vm.prank(bidder);
        uint256 govIn = burner.buy(IERC20(address(token)), 1e18, type(uint256).max, bidder);

        uint256 burned = govIn * 6_000 / 10_000;
        assertEq(gov.totalSupply(), supplyBefore - burned);
        assertEq(gov.balanceOf(treasury), govIn - burned, "remainder not forwarded");
    }

    function test_buyRoundsInFavourOfTheProtocol() public {
        _seedBurner(10e18);
        // A price that cannot divide evenly, and a `minLot` that admits the
        // two-unit fill.
        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(token)), true, 3, 1, 1);

        vm.prank(bidder);
        uint256 govIn = burner.buy(IERC20(address(token)), 2, type(uint256).max, bidder);
        // 2 * 3 / 1e18 = 6e-18 → rounds up to 1 rather than down to 0.
        assertEq(govIn, 1, "rounding must not favour the bidder");
    }

    function test_buyRespectsMaxGovIn() public {
        _seedBurner(10e18);
        _enableLot();
        uint256 tooLittle = 1e18 * SEED_PRICE / 1e18 - 1;

        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(FeeBurner.PriceAboveMax.selector, 1e18 * SEED_PRICE / 1e18, tooLittle));
        burner.buy(IERC20(address(token)), 1e18, tooLittle, bidder);
    }

    function test_buyCanSendLotToAThirdParty() public {
        _seedBurner(10e18);
        _enableLot();
        address dest = makeAddr("dest");
        vm.prank(bidder);
        burner.buy(IERC20(address(token)), 1e18, type(uint256).max, dest);
        assertEq(token.balanceOf(dest), 1e18);
    }

    // ============== The size-weighted ratchet ================================

    /// A full fill of at least `minLot` applies the whole multiplier to the
    /// clearing price and restarts the clock.
    function test_fullFillAppliesFullRatchet() public {
        _seedBurner(10e18);
        _enableLot();
        vm.warp(T0 + HALF_LIFE);
        uint256 clearing = burner.priceOf(IERC20(address(token)));

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), 10e18, type(uint256).max, bidder);

        (uint256 startPrice, uint48 startedAt,,) = _lotClock();
        assertEq(startPrice, clearing * RESTART_MULT_BPS / 10_000, "full fill must double the price");
        assertEq(startedAt, uint48(T0 + HALF_LIFE), "clock not restarted");
    }

    /// A fill of exactly `minLot` that takes a tiny share of the lot moves the
    /// price proportionally to that share. A flat ratchet would let a 0.01% buy
    /// double the price and restart the clock, so a lot could be kept from
    /// clearing at negligible cost.
    function test_dustFillBarelyMovesThePrice() public {
        _seedBurner(10_000e18);
        _enableLot();

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), MIN_LOT, type(uint256).max, bidder); // 0.01% of the lot

        (uint256 startPrice,,,) = _lotClock();
        // fillBps = 1, so mult = 10_000 + (10_000 * 1 / 10_000) = 10_001.
        assertEq(startPrice, SEED_PRICE * 10_001 / 10_000);
        assertLt(startPrice, SEED_PRICE * 101 / 100, "dust buy moved the price more than 1%");
    }

    function test_halfFillAppliesHalfTheRatchet() public {
        _seedBurner(10e18);
        _enableLot();

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), 5e18, type(uint256).max, bidder);

        (uint256 startPrice,,,) = _lotClock();
        // fillBps = 5_000 → mult = 10_000 + 10_000 * 5_000 / 10_000 = 15_000.
        assertEq(startPrice, SEED_PRICE * 15_000 / 10_000);
    }

    function test_partialFillLeavesTheRemainderSellable() public {
        _seedBurner(10e18);
        _enableLot();

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), 4e18, type(uint256).max, bidder);
        assertEq(token.balanceOf(address(burner)), 6e18);

        vm.prank(bidder2);
        burner.buy(IERC20(address(token)), 6e18, type(uint256).max, bidder2);
        assertEq(token.balanceOf(address(burner)), 0);
    }

    // ============== Ratchet eligibility ======================================

    /// A fill below `minLot` is admitted only because it clears the balance, and
    /// it leaves the price, the clock and the curve snapshot untouched. Measured
    /// against the balance it is a full fill, so a size-weighted ratchet alone
    /// would double the price.
    function test_dustClearDoesNotRatchetOrRestartTheClock() public {
        _seedBurner(MIN_LOT / 2);
        _enableLot();
        vm.warp(T0 + HALF_LIFE / 2);
        // A re-anchor would also adopt these.
        vm.prank(timelockOwner);
        burner.setDecayParams(60, 4, RESTART_MULT_BPS);
        uint256 price = burner.priceOf(IERC20(address(token)));

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), MIN_LOT / 2, type(uint256).max, bidder);
        assertEq(token.balanceOf(address(burner)), 0, "fixture: the fill clears the balance");

        (uint256 startPrice, uint48 startedAt, uint32 halfLife, uint8 maxHalvings) = _lotClock();
        assertEq(startPrice, SEED_PRICE, "dust clear ratcheted the price");
        assertEq(startedAt, uint48(T0), "dust clear restarted the clock");
        assertEq(halfLife, HALF_LIFE, "dust clear re-snapshotted halfLife");
        assertEq(maxHalvings, MAX_HALVINGS, "dust clear re-snapshotted maxHalvings");
        assertEq(burner.priceOf(IERC20(address(token))), price, "dust clear moved the asking price");
    }

    /// The donate-and-clear loop, at mainnet parameters (1 h half-life, 12
    /// halvings, 2x restart). Each round donates 1 wei to an empty burner and buys
    /// it back, a clearing fill of the whole balance. Were that to ratchet, 20
    /// rounds in one block would lift the start price 2^20-fold and the
    /// `maxHalvings` floor 256-fold above the seed, freezing the lot. It does
    /// not: the lot decays to its original floor and clears there.
    function test_donateAndClearLoopDoesNotFreezeTheLot() public {
        _enableLot();
        address attacker = makeAddr("attacker");
        token.mint(attacker, 20);
        vm.prank(govHolder);
        gov.transfer(attacker, 1_000e18);

        vm.startPrank(attacker);
        gov.approve(address(burner), type(uint256).max);
        for (uint256 i = 0; i < 20; ++i) {
            token.transfer(address(burner), 1);
            burner.buy(IERC20(address(token)), 1, type(uint256).max, attacker);
        }
        vm.stopPrank();

        (uint256 startPrice, uint48 startedAt,,) = _lotClock();
        assertEq(startPrice, SEED_PRICE, "the loop ratcheted the start price");
        assertEq(startedAt, uint48(T0), "the loop restarted the clock");
        assertEq(burner.priceOf(IERC20(address(token))), SEED_PRICE, "the loop moved the asking price");

        vm.warp(T0 + uint256(HALF_LIFE) * MAX_HALVINGS);
        uint256 floor = SEED_PRICE >> MAX_HALVINGS;
        assertEq(burner.priceOf(IERC20(address(token))), floor, "full decay no longer reaches the floor");

        // A real bidder clears a real lot at that floor.
        _seedBurner(10e18);
        uint256 maxGovIn = Math.mulDiv(10e18, floor, 1e18, Math.Rounding.Ceil);
        vm.prank(bidder2);
        uint256 govIn = burner.buy(IERC20(address(token)), 10e18, maxGovIn, bidder2);
        assertEq(govIn, maxGovIn);
    }

    /// The loop at `minLot` still ratchets, but each round must buy a whole
    /// `minLot` at the doubled price, so the cost of pushing the price up grows
    /// geometrically: round `n` costs `2^n` times round 0. The donated tokens
    /// come back with each fill, so all of it is GOV burned.
    function test_minLotDonationLoopCostGrowsGeometrically() public {
        _enableLot();
        token.mint(bidder, MIN_LOT);
        uint256 rounds = 10;
        uint256 first;
        uint256 prev;
        uint256 total;

        vm.startPrank(bidder);
        for (uint256 i = 0; i < rounds; ++i) {
            token.transfer(address(burner), MIN_LOT);
            uint256 govIn = burner.buy(IERC20(address(token)), MIN_LOT, type(uint256).max, bidder);
            if (i == 0) first = govIn;
            else assertEq(govIn * 10_000, prev * RESTART_MULT_BPS, "round cost did not scale by restartMultBps");
            prev = govIn;
            total += govIn;
        }
        vm.stopPrank();

        assertEq(first, uint256(MIN_LOT) * SEED_PRICE / 1e18, "round 0 is one minLot at the seed");
        assertEq(prev, first << (rounds - 1), "round n must cost 2^n times round 0");
        assertEq(total, first * ((1 << rounds) - 1), "total is a geometric series");
        assertEq(token.balanceOf(bidder), MIN_LOT, "the donated tokens come back");
    }

    /// A fill of at least `minLot` whose share of a large balance floors to zero
    /// basis points gets `mult == BPS`, and does not re-anchor. Re-anchoring there
    /// would raise nothing and only restart decay from the current price, so a
    /// run of such fills could walk the price below the `maxHalvings` clamp.
    function test_zeroWeightFillDoesNotReanchor() public {
        // 1e18 of 20_000e18 is half a basis point, which floors to zero.
        _seedBurner(20_000e18);
        _enableLot();
        vm.warp(T0 + HALF_LIFE / 2);
        uint256 price = burner.priceOf(IERC20(address(token)));

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), MIN_LOT, type(uint256).max, bidder);

        (uint256 startPrice, uint48 startedAt,,) = _lotClock();
        assertEq(startPrice, SEED_PRICE, "zero-weight fill rewrote the start price");
        assertEq(startedAt, uint48(T0), "zero-weight fill restarted the clock");
        assertEq(burner.priceOf(IERC20(address(token))), price, "zero-weight fill moved the asking price");
    }

    /// With `restartMultBps == BPS` every fill has zero ratchet weight, so even a
    /// full fill leaves the clock running.
    function test_unitRestartMultiplierNeverReanchors() public {
        vm.prank(timelockOwner);
        burner.setDecayParams(HALF_LIFE, MAX_HALVINGS, 10_000);
        _seedBurner(10e18);
        _enableLot();
        vm.warp(T0 + HALF_LIFE / 2);
        uint256 price = burner.priceOf(IERC20(address(token)));

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), 10e18, type(uint256).max, bidder);

        (uint256 startPrice, uint48 startedAt,,) = _lotClock();
        assertEq(startPrice, SEED_PRICE, "unit multiplier rewrote the start price");
        assertEq(startedAt, uint48(T0), "unit multiplier restarted the clock");
        assertEq(burner.priceOf(IERC20(address(token))), price);
    }

    // ============== Dust rules ===============================================

    function test_belowMinLotReverts() public {
        _seedBurner(10e18);
        _enableLot();

        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(FeeBurner.BelowMinLot.selector, 0.5e18, MIN_LOT));
        burner.buy(IERC20(address(token)), 0.5e18, type(uint256).max, bidder);
    }

    /// A remainder under `minLot` is clearable in full, so dust does not
    /// accumulate. Such a fill does not ratchet; see
    /// `test_dustClearDoesNotRatchetOrRestartTheClock`.
    function test_belowMinLotAllowedWhenItClearsTheBalance() public {
        _seedBurner(0.5e18);
        _enableLot();

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), 0.5e18, type(uint256).max, bidder);
        assertEq(token.balanceOf(address(burner)), 0);
    }

    function test_zeroAmountReverts() public {
        _seedBurner(10e18);
        _enableLot();
        vm.prank(bidder);
        vm.expectRevert(FeeBurner.BadAmount.selector);
        burner.buy(IERC20(address(token)), 0, type(uint256).max, bidder);
    }

    function test_buyingMoreThanTheBalanceReverts() public {
        _seedBurner(10e18);
        _enableLot();
        vm.prank(bidder);
        vm.expectRevert(FeeBurner.BadAmount.selector);
        burner.buy(IERC20(address(token)), 11e18, type(uint256).max, bidder);
    }

    /// Rounding up guarantees a non-zero cost: one base unit at the lowest
    /// representable price still costs GOV, so no amount clears for free.
    function test_smallestPossibleBuyStillCostsGov() public {
        _seedBurner(10e18);
        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(token)), true, 2, 1, 1);

        vm.prank(bidder);
        uint256 govIn = burner.buy(IERC20(address(token)), 1, type(uint256).max, bidder);
        assertEq(govIn, 1, "a one-unit buy must still cost at least one wei of GOV");
    }

    // ============== Guards ===================================================

    function test_disabledLotCannotBeBought() public {
        _seedBurner(10e18);
        vm.prank(bidder);
        vm.expectRevert(FeeBurner.LotDisabled.selector);
        burner.buy(IERC20(address(token)), 1e18, type(uint256).max, bidder);
    }

    function test_pausedBlocksBuying() public {
        _seedBurner(10e18);
        _enableLot();
        vm.prank(timelockOwner);
        burner.setPaused(true);

        vm.prank(bidder);
        vm.expectRevert(FeeBurner.IsPaused.selector);
        burner.buy(IERC20(address(token)), 1e18, type(uint256).max, bidder);
    }

    /// GOV cannot be auctioned for GOV, which would corrupt the ratchet.
    function test_govCannotBeConfiguredAsALot() public {
        vm.prank(timelockOwner);
        vm.expectRevert(FeeBurner.CannotAuctionGov.selector);
        burner.setLot(IERC20(address(gov)), true, SEED_PRICE, MIN_PRICE, MIN_LOT);
    }

    function test_buyRejectsZeroDestination() public {
        _seedBurner(10e18);
        _enableLot();
        vm.prank(bidder);
        vm.expectRevert(FeeBurner.ZeroAddress.selector);
        burner.buy(IERC20(address(token)), 1e18, type(uint256).max, address(0));
    }

    // ============== GOV arriving as a fee ====================================

    function test_burnAccruedGovBurnsARestingBalance() public {
        vm.prank(govHolder);
        gov.transfer(address(burner), 500e18);

        uint256 supplyBefore = gov.totalSupply();
        uint256 burned = burner.burnAccruedGov();

        assertEq(burned, 500e18);
        assertEq(gov.totalSupply(), supplyBefore - 500e18);
        assertEq(gov.balanceOf(address(burner)), 0);
    }

    function test_burnAccruedGovRevertsWhenEmpty() public {
        vm.expectRevert(FeeBurner.NothingToBurn.selector);
        burner.burnAccruedGov();
    }

    // ============== Access control and bounds ================================

    function test_settersAreOwnerOnly() public {
        address attacker = makeAddr("attacker");
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker);

        vm.startPrank(attacker);
        vm.expectRevert(err);
        burner.setLot(IERC20(address(token)), true, 1, 1, 1);
        vm.expectRevert(err);
        burner.setDecayParams(1 hours, 12, 20_000);
        vm.expectRevert(err);
        burner.setBurnBps(5_000);
        vm.expectRevert(err);
        burner.setSecondaryTreasury(attacker);
        vm.expectRevert(err);
        burner.setPaused(true);
        vm.expectRevert(err);
        burner.setPools(new address[](0));
        vm.expectRevert(err);
        burner.rescue(IERC20(address(token)), attacker, 1);
        vm.stopPrank();
    }

    function test_decayParamBounds() public {
        vm.startPrank(timelockOwner);
        vm.expectRevert(FeeBurner.BadDecayParams.selector);
        burner.setDecayParams(0, 12, 20_000); // halfLife 0 divides by zero
        vm.expectRevert(FeeBurner.BadDecayParams.selector);
        burner.setDecayParams(1 hours, 0, 20_000);
        vm.expectRevert(FeeBurner.BadDecayParams.selector);
        burner.setDecayParams(1 hours, 33, 20_000);
        vm.expectRevert(FeeBurner.BadDecayParams.selector);
        burner.setDecayParams(1 hours, 12, 9_999); // a ratchet must never lower the price
        vm.expectRevert(FeeBurner.BadDecayParams.selector);
        burner.setDecayParams(1 hours, 12, 50_001);
        vm.stopPrank();
    }

    function test_burnBpsBounds() public {
        vm.startPrank(timelockOwner);
        vm.expectRevert(FeeBurner.BadBurnBps.selector);
        burner.setBurnBps(10_001);
        // A partial burn requires a secondary treasury for the remainder.
        vm.expectRevert(FeeBurner.ZeroAddress.selector);
        burner.setBurnBps(9_000);
        vm.stopPrank();
    }

    function test_lotPriceBounds() public {
        vm.startPrank(timelockOwner);
        vm.expectRevert(FeeBurner.BadLotPrices.selector);
        burner.setLot(IERC20(address(token)), true, 0, 1, MIN_LOT);
        vm.expectRevert(FeeBurner.BadLotPrices.selector);
        burner.setLot(IERC20(address(token)), true, 10, 0, MIN_LOT);
        vm.expectRevert(FeeBurner.BadLotPrices.selector);
        burner.setLot(IERC20(address(token)), true, 10, 11, MIN_LOT); // floor above the seed
        vm.stopPrank();
    }

    /// An enabled lot needs a non-zero `minLot`: without one, any dust fill is
    /// ratchet-eligible and the donate-and-clear loop is back.
    function test_revert_BadMinLot_zeroMinLotWhenEnabled() public {
        vm.prank(timelockOwner);
        vm.expectRevert(FeeBurner.BadMinLot.selector);
        burner.setLot(IERC20(address(token)), true, SEED_PRICE, MIN_PRICE, 0);
    }

    /// A disabled lot cannot be bought, so disabling one needs no `minLot`.
    function test_disabledLotAcceptsZeroMinLot() public {
        _enableLot();
        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(token)), false, 0, 0, 0);

        (bool enabled,, uint128 minLot,,,,) = burner.lots(IERC20(address(token)));
        assertFalse(enabled);
        assertEq(minLot, 0);
    }

    function test_rescueMovesTokensOut() public {
        _seedBurner(10e18);
        address dest = makeAddr("bridge");
        vm.prank(timelockOwner);
        burner.rescue(IERC20(address(token)), dest, 10e18);
        assertEq(token.balanceOf(dest), 10e18);
    }
}
