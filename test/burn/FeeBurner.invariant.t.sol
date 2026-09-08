// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LelantosToken } from "../../src/governance/LelantosToken.sol";
import { FeeBurner } from "../../src/burn/FeeBurner.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// Drives random buys, waits and fee arrivals against one lot, accumulating
/// ghost totals the invariants check against.
contract FeeBurnerHandler is Test {
    FeeBurner public immutable BURNER;
    LelantosToken public immutable GOV;
    MockERC20 public immutable TOKEN;
    address public immutable OWNER;

    uint256 public ghostBurned;
    uint256 public ghostBought;
    uint256 public ghostRescued;
    uint256 public ghostFeesIn;
    uint256 public lastSupply;

    address[] internal bidders;

    constructor(FeeBurner b, LelantosToken g, MockERC20 t, address owner_, address[] memory bidders_) {
        BURNER = b;
        GOV = g;
        TOKEN = t;
        OWNER = owner_;
        bidders = bidders_;
        lastSupply = g.totalSupply();
    }

    function _bidder(uint256 seed) internal view returns (address) {
        return bidders[seed % bidders.length];
    }

    function buy(uint256 seed, uint256 amount) external {
        uint256 bal = TOKEN.balanceOf(address(BURNER));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        address who = _bidder(seed);

        uint256 supplyBefore = GOV.totalSupply();
        vm.prank(who);
        try BURNER.buy(IERC20(address(TOKEN)), amount, type(uint256).max, who) returns (uint256) {
            ghostBought += amount;
            ghostBurned += supplyBefore - GOV.totalSupply();
            lastSupply = GOV.totalSupply();
        } catch { }
    }

    /// Fees arriving is a plain transfer in — exactly how `sweep` delivers them.
    function accrueFees(uint256 amount) external {
        amount = bound(amount, 1, 1_000e18);
        TOKEN.mint(address(BURNER), amount);
        ghostFeesIn += amount;
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 10 days));
    }

    function reseed(uint256 startPrice, uint256 minPrice) external {
        startPrice = bound(startPrice, 1e6, 1e24);
        minPrice = bound(minPrice, 1, startPrice);
        vm.prank(OWNER);
        BURNER.setLot(IERC20(address(TOKEN)), true, startPrice, minPrice, 0);
    }

    function rescue(uint256 amount) external {
        uint256 bal = TOKEN.balanceOf(address(BURNER));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(OWNER);
        BURNER.rescue(IERC20(address(TOKEN)), address(0xdead), amount);
        ghostRescued += amount;
    }
}

/// The properties that must hold no matter how the auction is driven.
contract FeeBurnerInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    LelantosToken internal gov;
    FeeBurner internal burner;
    MockERC20 internal token;
    FeeBurnerHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal holder = makeAddr("holder");

    function setUp() public {
        vm.warp(1_000_000);
        gov = new LelantosToken("Lelantos", "LNT", SUPPLY, holder);
        token = new MockERC20("Fee", "FEE", 18);
        burner = new FeeBurner(gov, owner, 1 hours, 12, 20_000, 10_000, address(0));

        address[] memory bidders = new address[](3);
        bidders[0] = makeAddr("b1");
        bidders[1] = makeAddr("b2");
        bidders[2] = makeAddr("b3");

        for (uint256 i = 0; i < bidders.length; ++i) {
            vm.prank(holder);
            gov.transfer(bidders[i], 100_000_000e18);
            vm.prank(bidders[i]);
            gov.approve(address(burner), type(uint256).max);
        }

        vm.prank(owner);
        burner.setLot(IERC20(address(token)), true, 2e18, 1e12, 0);
        token.mint(address(burner), 1_000e18);

        handler = new FeeBurnerHandler(burner, gov, token, owner, bidders);
        targetContract(address(handler));
    }

    /// Fixed supply, no mint: the total can only ever fall.
    function invariant_supplyNeverIncreases() public view {
        assertLe(gov.totalSupply(), SUPPLY);
    }

    /// Every wei of GOV that left circulation was burned by a sale — the public
    /// claim `INITIAL_SUPPLY - totalSupply()` makes.
    function invariant_burnedMatchesSupplyDelta() public view {
        assertEq(SUPPLY - gov.totalSupply(), handler.ghostBurned());
        assertEq(gov.totalBurned(), handler.ghostBurned());
    }

    /// GOV is received and burned inside one call, so none may rest here. A
    /// balance would mean value was paid in and neither burned nor forwarded.
    function invariant_burnerHoldsNoGov() public view {
        assertEq(gov.balanceOf(address(burner)), 0);
    }

    /// Fee tokens leave only by being bought or rescued.
    function invariant_feeTokensAreConserved() public view {
        assertEq(
            token.balanceOf(address(burner)),
            1_000e18 + handler.ghostFeesIn() - handler.ghostBought() - handler.ghostRescued()
        );
    }

    /// The floor always holds, so a lot can never decay toward free.
    function invariant_priceNeverBelowFloor() public view {
        (bool enabled,,,, uint256 minPrice) = burner.lots(IERC20(address(token)));
        if (!enabled) return;
        assertGe(burner.priceOf(IERC20(address(token))), minPrice);
    }

    function invariant_startPriceNeverBelowFloor() public view {
        (bool enabled,,, uint256 startPrice, uint256 minPrice) = burner.lots(IERC20(address(token)));
        if (!enabled) return;
        assertGe(startPrice, minPrice);
    }
}
