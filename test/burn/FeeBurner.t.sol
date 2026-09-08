// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { FeeBurner } from "../../src/burn/FeeBurner.sol";

import { FeeBurnerTestBase } from "./FeeBurnerTestBase.sol";

contract FeeBurnerTest is FeeBurnerTestBase {
    // ============== The integration ==========================================

    /// The claim the whole design rests on: fees reach the burner with **no
    /// protocol changes**, because `sweep` is already permissionless and already
    /// pays `treasury`. Driven through a real deposit and flush, so the accrual
    /// comes from `FeeConfig._accrueFee` at its real call site.
    function test_permissionlessSweepDeliversRealFeesToTheBurner() public {
        uint256 fee = _accrueRealFees(1_000);
        assertGt(fee, 0, "fixture must accrue something");
        assertEq(masp.accruedFee(IERC20(address(token))), fee, "fee accrued at flush");
        assertEq(token.balanceOf(address(burner)), 0, "nothing swept yet");

        // An unrelated party sweeps; the destination is pinned, not chosen.
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

    /// A pool that reverts must not block the others.
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

    /// Halfway through a period the linear interpolation must sit at three
    /// quarters, so the curve is continuous across each halving boundary.
    function test_priceInterpolatesWithinAPeriod() public {
        _enableLot();
        vm.warp(T0 + HALF_LIFE / 2);
        assertEq(burner.priceOf(IERC20(address(token))), SEED_PRICE - (SEED_PRICE / 2) / 2);
    }

    /// Unbounded decay would eventually make a lot free. Two independent clamps
    /// prevent it, and whichever binds first wins. Here `maxHalvings` binds,
    /// because 12 halvings of the seed is still above the floor.
    function test_priceStopsDecayingAtMaxHalvings() public {
        _enableLot();
        vm.warp(T0 + 365 days);
        uint256 floorFromHalvings = SEED_PRICE >> MAX_HALVINGS;
        assertGt(floorFromHalvings, MIN_PRICE, "this test is only meaningful while halvings bind first");
        assertEq(burner.priceOf(IERC20(address(token))), floorFromHalvings, "decayed past the halving clamp");
    }

    /// And when the floor is the tighter of the two, it binds instead.
    function test_priceClampsAtMinPriceWhenItBindsFirst() public {
        uint256 highFloor = SEED_PRICE / 2;
        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(token)), true, SEED_PRICE, highFloor, 0);

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
        // A price that cannot divide evenly.
        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(token)), true, 3, 1, 0);

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

    /// A full fill applies the whole multiplier.
    function test_fullFillAppliesFullRatchet() public {
        _seedBurner(10e18);
        _enableLot();

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), 10e18, type(uint256).max, bidder);

        (, uint48 startedAt,, uint256 startPrice,) = burner.lots(IERC20(address(token)));
        assertEq(startPrice, SEED_PRICE * RESTART_MULT_BPS / 10_000, "full fill must double the price");
        assertEq(startedAt, uint48(T0), "clock not restarted");
    }

    /// The griefing fix: a dust fill must barely move the price. With a flat
    /// ratchet a 0.01% buy would double it and restart the clock, letting an
    /// adversary keep a lot from ever clearing for almost nothing.
    function test_dustFillBarelyMovesThePrice() public {
        _seedBurner(10_000e18);
        _enableLot();

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), 1e18, type(uint256).max, bidder); // 0.01% of the lot

        (,,, uint256 startPrice,) = burner.lots(IERC20(address(token)));
        // fillBps = 1, so mult = 10_000 + (10_000 * 1 / 10_000) = 10_001.
        assertEq(startPrice, SEED_PRICE * 10_001 / 10_000);
        assertLt(startPrice, SEED_PRICE * 101 / 100, "dust buy moved the price more than 1%");
    }

    function test_halfFillAppliesHalfTheRatchet() public {
        _seedBurner(10e18);
        _enableLot();

        vm.prank(bidder);
        burner.buy(IERC20(address(token)), 5e18, type(uint256).max, bidder);

        (,,, uint256 startPrice,) = burner.lots(IERC20(address(token)));
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

    // ============== Dust rules ===============================================

    function test_belowMinLotReverts() public {
        _seedBurner(10e18);
        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(token)), true, SEED_PRICE, MIN_PRICE, 1e18);

        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(FeeBurner.BelowMinLot.selector, 0.5e18, 1e18));
        burner.buy(IERC20(address(token)), 0.5e18, type(uint256).max, bidder);
    }

    /// The tail escape: a remainder under `minLot` must still be clearable, or
    /// dust would accumulate forever.
    function test_belowMinLotAllowedWhenItClearsTheBalance() public {
        _seedBurner(0.5e18);
        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(token)), true, SEED_PRICE, MIN_PRICE, 1e18);

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

    /// A lot must never be takeable for nothing. Rounding up is what guarantees
    /// it: even one base unit at the lowest representable price still costs GOV,
    /// so there is no amount an attacker can pick that clears for free.
    function test_smallestPossibleBuyStillCostsGov() public {
        _seedBurner(10e18);
        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(token)), true, 2, 1, 0);

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

    /// Auctioning GOV for GOV is meaningless and would corrupt the ratchet.
    function test_govCannotBeConfiguredAsALot() public {
        vm.prank(timelockOwner);
        vm.expectRevert(FeeBurner.CannotAuctionGov.selector);
        burner.setLot(IERC20(address(gov)), true, SEED_PRICE, MIN_PRICE, 0);
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
        burner.setLot(IERC20(address(token)), true, 1, 1, 0);
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
        // Anything not burned must have somewhere to go.
        vm.expectRevert(FeeBurner.ZeroAddress.selector);
        burner.setBurnBps(9_000);
        vm.stopPrank();
    }

    function test_lotPriceBounds() public {
        vm.startPrank(timelockOwner);
        vm.expectRevert(FeeBurner.BadLotPrices.selector);
        burner.setLot(IERC20(address(token)), true, 0, 1, 0);
        vm.expectRevert(FeeBurner.BadLotPrices.selector);
        burner.setLot(IERC20(address(token)), true, 10, 0, 0);
        vm.expectRevert(FeeBurner.BadLotPrices.selector);
        burner.setLot(IERC20(address(token)), true, 10, 11, 0); // floor above the seed
        vm.stopPrank();
    }

    function test_rescueMovesTokensOut() public {
        _seedBurner(10e18);
        address dest = makeAddr("bridge");
        vm.prank(timelockOwner);
        burner.rescue(IERC20(address(token)), dest, 10e18);
        assertEq(token.balanceOf(dest), 10e18);
    }
}
