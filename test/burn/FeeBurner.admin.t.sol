// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { FeeBurner } from "../../src/burn/FeeBurner.sol";

import { FeeBurnerTestBase } from "./FeeBurnerTestBase.sol";

/// `FeeBurner` guards and administration: disabled, paused and GOV lots, burning
/// GOV that arrives as a fee, owner-only setters, parameter bounds and rescue.
contract FeeBurnerAdminTest is FeeBurnerTestBase {
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
