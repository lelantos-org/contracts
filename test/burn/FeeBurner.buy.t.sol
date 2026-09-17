// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { FeeBurner } from "../../src/burn/FeeBurner.sol";

import { FeeBurnerTestBase } from "./FeeBurnerTestBase.sol";

/// `FeeBurner.buy`: payment, burn and rounding, the size-weighted ratchet and
/// which fills are eligible to re-anchor it, and the `minLot` dust rules.
contract FeeBurnerBuyTest is FeeBurnerTestBase {
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
}
