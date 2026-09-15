// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FeeBurner } from "../../src/burn/FeeBurner.sol";

import { FeeBurnerTestBase } from "./FeeBurnerTestBase.sol";
import { ReentrantOnTransferERC20 } from "./mocks/ReentrantOnTransferERC20.sol";

/// Sandwich and flash-loan resistance of the auction.
///
/// `priceOf` reads no external state, so a flash loan has no input to move.
/// These tests assert that property.
contract FeeBurnerSlippageTest is FeeBurnerTestBase {
    /// Price is a pure function of stored state and `block.timestamp`, so no
    /// ordering within a block yields a better price.
    function test_twoBiddersInTheSameBlockSeeTheSamePrice() public {
        _seedBurner(100e18);
        _enableLot();

        uint256 p1 = burner.priceOf(IERC20(address(token)));
        uint256 p2 = burner.priceOf(IERC20(address(token)));
        assertEq(p1, p2);

        vm.prank(bidder);
        uint256 govA = burner.buy(IERC20(address(token)), 1e18, type(uint256).max, bidder);
        vm.prank(bidder2);
        uint256 govB = burner.buy(IERC20(address(token)), 1e18, type(uint256).max, bidder2);

        // The first fill ratchets the price up, so the second bidder pays at
        // least as much.
        assertGe(govB, govA, "the follower must not get a better price");
    }

    /// The price is unchanged across external state mutation at a fixed
    /// timestamp, so a flash loan cannot move it.
    function test_priceIsUnaffectedByExternalStateChanges() public {
        _seedBurner(100e18);
        _enableLot();
        uint256 before = burner.priceOf(IERC20(address(token)));

        // Minting, balance moves and donations to the burner are not inputs to
        // the curve.
        token.mint(address(burner), 1_000_000e18);
        vm.prank(govHolder);
        gov.transfer(bidder, 1_000e18);

        assertEq(burner.priceOf(IERC20(address(token))), before, "price moved with external state");
    }

    /// A partial fill raises the price for the next bidder, so front-running
    /// increases cost rather than extracting value.
    function test_frontRunningRaisesThePriceForTheFollower() public {
        _seedBurner(100e18);
        _enableLot();

        uint256 priceBefore = burner.priceOf(IERC20(address(token)));
        vm.prank(bidder);
        burner.buy(IERC20(address(token)), 50e18, type(uint256).max, bidder);
        uint256 priceAfter = burner.priceOf(IERC20(address(token)));

        assertGt(priceAfter, priceBefore, "a partial fill must ratchet the price up");
    }

    /// Under any sequence of waits and partial buys the clearing price stays at or
    /// above the configured floor.
    function testFuzz_clearingPriceNeverFallsBelowTheFloor(uint32 wait1, uint32 wait2, uint8 frac) public {
        _seedBurner(100e18);
        _enableLot();
        uint256 amount = 1e18 + (uint256(frac) * 1e17);

        vm.warp(T0 + uint256(wait1));
        uint256 p1 = burner.priceOf(IERC20(address(token)));
        assertGe(p1, MIN_PRICE);
        vm.prank(bidder);
        burner.buy(IERC20(address(token)), amount, type(uint256).max, bidder);

        vm.warp(T0 + uint256(wait1) + uint256(wait2));
        uint256 p2 = burner.priceOf(IERC20(address(token)));
        assertGe(p2, MIN_PRICE, "price fell through the floor");
    }

    /// Every buy costs a non-zero amount of GOV at any point on the curve. The
    /// lot takes the smallest `minLot`, so every amount down to one base unit is
    /// buyable.
    function testFuzz_buyAlwaysCostsGov(uint32 wait, uint64 amount) public {
        vm.assume(amount > 0);
        _seedBurner(100e18);
        _enableLot(1);

        vm.warp(T0 + uint256(wait));
        vm.prank(bidder);
        uint256 govIn = burner.buy(IERC20(address(token)), uint256(amount), type(uint256).max, bidder);
        assertGt(govIn, 0, "a lot cleared for free");
    }

    // ============== Reentrancy ===============================================

    /// A hostile fee token re-entering on payout hits the guard.
    function test_reentrantFeeTokenIsBlocked() public {
        ReentrantOnTransferERC20 evil = new ReentrantOnTransferERC20();
        evil.mint(address(burner), 10e18);

        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(evil)), true, SEED_PRICE, MIN_PRICE, MIN_LOT);

        evil.arm(
            address(burner), abi.encodeCall(FeeBurner.buy, (IERC20(address(evil)), 1e18, type(uint256).max, bidder))
        );

        vm.prank(bidder);
        vm.expectRevert();
        burner.buy(IERC20(address(evil)), 1e18, type(uint256).max, bidder);
    }

    /// Checks-effects-interactions: the lot is re-priced before the payout
    /// transfer, so a re-entrant call cannot observe the old price even without
    /// the guard.
    function test_lotIsRepricedBeforeThePayoutTransfer() public {
        ReentrantOnTransferERC20 evil = new ReentrantOnTransferERC20();
        evil.mint(address(burner), 10e18);

        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(evil)), true, SEED_PRICE, MIN_PRICE, MIN_LOT);

        // Re-enters with a call that records the stored start price at the
        // moment of the payout.
        evil.arm(address(this), abi.encodeCall(this.recordStartPrice, (address(evil))));

        vm.prank(bidder);
        burner.buy(IERC20(address(evil)), 10e18, type(uint256).max, bidder);

        assertEq(observedStartPrice, SEED_PRICE * RESTART_MULT_BPS / 10_000, "state was not written before payout");
    }

    uint256 internal observedStartPrice;

    function recordStartPrice(address t) external {
        (,,,,, uint256 startPrice,) = burner.lots(IERC20(t));
        observedStartPrice = startPrice;
    }
}
