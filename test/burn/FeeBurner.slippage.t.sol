// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FeeBurner } from "../../src/burn/FeeBurner.sol";

import { FeeBurnerTestBase } from "./FeeBurnerTestBase.sol";
import { ReentrantOnTransferERC20 } from "./mocks/ReentrantOnTransferERC20.sol";

/// The sandwich argument, made mechanical.
///
/// The reason to prefer an auction to a router swap is that `priceOf` reads no
/// external state, so there is nothing a flash loan can move. These tests assert
/// that rather than asserting it in a comment.
contract FeeBurnerSlippageTest is FeeBurnerTestBase {
    /// No ordering advantage exists within a block: price is a pure function of
    /// stored state and `block.timestamp`, identical for everyone.
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

        // The second pays slightly more, because the first fill ratcheted the
        // price up — never less. Front-running is not free.
        assertGe(govB, govA, "the follower must not get a better price");
    }

    /// A flash loan cannot move what the burner charges: the price is unchanged
    /// across arbitrary external state mutation at a fixed timestamp.
    function test_priceIsUnaffectedByExternalStateChanges() public {
        _seedBurner(100e18);
        _enableLot();
        uint256 before = burner.priceOf(IERC20(address(token)));

        // Mint a fortune, move balances, donate to the burner — none of it is an
        // input to the curve.
        token.mint(address(burner), 1_000_000e18);
        vm.prank(govHolder);
        gov.transfer(bidder, 1_000e18);

        assertEq(burner.priceOf(IERC20(address(token))), before, "price moved with external state");
    }

    /// Taking a partial lot raises the price for whoever comes next, so a
    /// front-runner pays for the privilege instead of extracting from it.
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

    /// Every buy must cost the bidder something, at any point on the curve.
    function testFuzz_buyAlwaysCostsGov(uint32 wait, uint64 amount) public {
        vm.assume(amount > 0);
        _seedBurner(100e18);
        _enableLot();

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
        burner.setLot(IERC20(address(evil)), true, SEED_PRICE, MIN_PRICE, 0);

        evil.arm(
            address(burner), abi.encodeCall(FeeBurner.buy, (IERC20(address(evil)), 1e18, type(uint256).max, bidder))
        );

        vm.prank(bidder);
        vm.expectRevert();
        burner.buy(IERC20(address(evil)), 1e18, type(uint256).max, bidder);
    }

    /// CEI, asserted rather than assumed: by the time the token is paid out the
    /// lot has already been re-priced, so a re-entrant call could never observe
    /// the old price even without the guard.
    function test_lotIsRepricedBeforeThePayoutTransfer() public {
        ReentrantOnTransferERC20 evil = new ReentrantOnTransferERC20();
        evil.mint(address(burner), 10e18);

        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(evil)), true, SEED_PRICE, MIN_PRICE, 0);

        // Re-entering with a read-only call: record the stored start price at the
        // moment of the payout.
        evil.arm(address(this), abi.encodeCall(this.recordStartPrice, (address(evil))));

        vm.prank(bidder);
        burner.buy(IERC20(address(evil)), 10e18, type(uint256).max, bidder);

        assertEq(observedStartPrice, SEED_PRICE * RESTART_MULT_BPS / 10_000, "state was not written before payout");
    }

    uint256 internal observedStartPrice;

    function recordStartPrice(address t) external {
        (,,, uint256 startPrice,) = burner.lots(IERC20(t));
        observedStartPrice = startPrice;
    }
}
