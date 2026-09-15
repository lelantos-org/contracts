// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LelantosToken } from "../../src/governance/LelantosToken.sol";
import { FeeBurner } from "../../src/burn/FeeBurner.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// Drives random buys, waits, fee arrivals, donate-and-clear loops and decay
/// parameter changes against one lot, accumulating ghost totals the invariants
/// check against.
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
    /// Successful fills below `minLot`, which are admitted only as clearing
    /// fills. Shows the dust path ran at all.
    uint256 public ghostDustFills;
    /// Of those, fills that moved `startPrice`, `startedAt` or the lot's decay
    /// curve snapshot. A sub-`minLot` fill must never re-anchor.
    uint256 public ghostDustReanchors;

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
        _buy(_bidder(seed), amount);
    }

    /// The donate-and-clear loop: while the balance is under `minLot`, donate a
    /// sub-`minLot` amount and buy the whole balance back, `rounds` times in one
    /// block. Any resting balance of `minLot` or more is cleared first by an
    /// ordinary fill, so the loop always starts from dust.
    function donateAndClearDust(uint256 seed, uint256 dust, uint256 rounds) external {
        (,, uint128 minLot,,,,) = BURNER.lots(IERC20(address(TOKEN)));
        if (minLot < 2) return;
        address who = _bidder(seed);

        uint256 bal = TOKEN.balanceOf(address(BURNER));
        if (bal >= minLot && !_buy(who, bal)) return;

        rounds = bound(rounds, 1, 8);
        for (uint256 i = 0; i < rounds; ++i) {
            bal = TOKEN.balanceOf(address(BURNER));
            if (bal >= minLot - 1) return;
            uint256 d = bound(dust, 1, minLot - 1 - bal);
            TOKEN.mint(address(BURNER), d);
            ghostFeesIn += d;
            dust = uint256(keccak256(abi.encode(dust)));
            if (!_buy(who, bal + d)) return;
        }
    }

    /// Buys `amount` and records the ghosts. A fill below `minLot` is checked
    /// against the lot's clock before and after.
    function _buy(address who, uint256 amount) internal returns (bool ok) {
        (, uint48 startedAt, uint128 minLot, uint32 halfLife, uint8 maxHalvings, uint256 startPrice,) =
            BURNER.lots(IERC20(address(TOKEN)));
        uint256 supplyBefore = GOV.totalSupply();
        vm.prank(who);
        try BURNER.buy(IERC20(address(TOKEN)), amount, type(uint256).max, who) returns (uint256) {
            ok = true;
            ghostBought += amount;
            ghostBurned += supplyBefore - GOV.totalSupply();
            lastSupply = GOV.totalSupply();
        } catch {
            return false;
        }
        if (amount >= minLot) return true;

        ++ghostDustFills;
        (, uint48 startedAt2,, uint32 halfLife2, uint8 maxHalvings2, uint256 startPrice2,) =
            BURNER.lots(IERC20(address(TOKEN)));
        if (
            startPrice2 != startPrice || startedAt2 != startedAt || halfLife2 != halfLife || maxHalvings2 != maxHalvings
        ) ++ghostDustReanchors;
    }

    /// Models fee arrival as a plain transfer in, which is how `sweep` delivers fees.
    function accrueFees(uint256 amount) external {
        amount = bound(amount, 1, 1_000e18);
        TOKEN.mint(address(BURNER), amount);
        ghostFeesIn += amount;
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 10 days));
    }

    function reseed(uint256 startPrice, uint256 minPrice, uint256 minLot) external {
        startPrice = bound(startPrice, 1e6, 1e24);
        minPrice = bound(minPrice, 1, startPrice);
        minLot = bound(minLot, 1, 10e18);
        vm.prank(OWNER);
        BURNER.setLot(IERC20(address(TOKEN)), true, startPrice, minPrice, uint128(minLot));
    }

    /// Changes the global curve. A running lot keeps its snapshot until it is
    /// reseeded or re-anchored.
    function setDecayParams(uint256 halfLife, uint256 maxHalvings, uint256 restartMultBps) external {
        halfLife = bound(halfLife, 1, 30 days);
        maxHalvings = bound(maxHalvings, 1, 32);
        restartMultBps = bound(restartMultBps, 10_000, 50_000);
        vm.prank(OWNER);
        BURNER.setDecayParams(uint32(halfLife), uint8(maxHalvings), uint16(restartMultBps));
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

/// Properties that hold under any sequence of auction actions.
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
        burner.setLot(IERC20(address(token)), true, 2e18, 1e12, 1e18);
        token.mint(address(burner), 1_000e18);

        handler = new FeeBurnerHandler(burner, gov, token, owner, bidders);
        targetContract(address(handler));
    }

    /// Supply is fixed with no mint, so the total never increases.
    function invariant_supplyNeverIncreases() public view {
        assertLe(gov.totalSupply(), SUPPLY);
    }

    /// All GOV removed from circulation is burned by a sale, so
    /// `INITIAL_SUPPLY - totalSupply()` equals the total burned.
    function invariant_burnedMatchesSupplyDelta() public view {
        assertEq(SUPPLY - gov.totalSupply(), handler.ghostBurned());
        assertEq(gov.totalBurned(), handler.ghostBurned());
    }

    /// GOV is received and burned within one call, so the burner holds none. A
    /// non-zero balance indicates GOV paid in that was neither burned nor forwarded.
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

    /// The price never decays below the lot's floor.
    function invariant_priceNeverBelowFloor() public view {
        (bool enabled,,,,,, uint256 minPrice) = burner.lots(IERC20(address(token)));
        if (!enabled) return;
        assertGe(burner.priceOf(IERC20(address(token))), minPrice);
    }

    function invariant_startPriceNeverBelowFloor() public view {
        (bool enabled,,,,, uint256 startPrice, uint256 minPrice) = burner.lots(IERC20(address(token)));
        if (!enabled) return;
        assertGe(startPrice, minPrice);
    }

    /// A fill below `minLot` gets in only by clearing the balance, which anyone
    /// can shrink to dust by donating first, so it never moves the start price,
    /// the clock or the curve snapshot.
    function invariant_dustFillsNeverRatchet() public view {
        assertEq(handler.ghostDustReanchors(), 0);
    }

    /// An enabled lot always carries a non-zero `minLot` and a usable curve
    /// snapshot: a zero half-life would divide by zero in `priceOf`.
    function invariant_enabledLotHasMinLotAndCurve() public view {
        (bool enabled,, uint128 minLot, uint32 halfLife, uint8 maxHalvings,,) = burner.lots(IERC20(address(token)));
        if (!enabled) return;
        assertGt(minLot, 0);
        assertGt(halfLife, 0);
        assertGt(maxHalvings, 0);
        assertLe(maxHalvings, 32);
    }
}
