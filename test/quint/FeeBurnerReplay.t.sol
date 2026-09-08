// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FeeBurner } from "../../src/burn/FeeBurner.sol";
import { LelantosToken } from "../../src/governance/LelantosToken.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { FeeBurnerSpec } from "./generated/FeeBurnerSpec.sol";
import { FeeBurnerSpecReplay } from "./generated/FeeBurnerSpecReplay.sol";

/// Driver for [spec/fee_burner.qnt](../../spec/fee_burner.qnt).
///
/// Deliberately does *not* extend
/// [test/burn/FeeBurnerTestBase.sol](../burn/FeeBurnerTestBase.sol): that base
/// stands the whole pool up so fees can arrive through the real accrual path,
/// and this spec does not model `harvest`. A mint straight into the burner is
/// what `sweep` does anyway, so the pool would only add state to compare.
///
/// Every field of `_project` is a live read - there is no driver shadow at all,
/// which means the triage question "is this the driver's bookkeeping?" never
/// arises here.
///
/// `abstract` so Foundry does not collect it as a test contract; the generated
/// `FeeBurnerTraces` inherits it and holds one test per trace.
abstract contract FeeBurnerReplay is FeeBurnerSpecReplay {
    // Must match the spec. `setUp` asserts the deployed burner agrees on every
    // one of them, which is the copy nothing else would catch.
    uint32 internal constant HALF_LIFE = 3600;
    uint8 internal constant MAX_HALVINGS = 12;
    /// Not 20_000: at 20_000 the term `(restartMultBps - BPS) * fillBps / BPS`
    /// is exactly `fillBps` and the rounding in the ratchet disappears.
    uint16 internal constant RESTART_MULT_BPS = 17_777;
    /// Not 10_000: at 10_000 the burn split is exact and the remainder is
    /// always zero, so the secondary-treasury leg is never exercised.
    uint16 internal constant BURN_BPS = 6_667;
    /// Odd, and not a multiple of 1e18, so `ceil` differs from `floor` in
    /// `govIn` and `startPrice >> periods` loses bits.
    uint256 internal constant SEED_PRICE = 1_234_567_890_123_456_789;
    /// Above `SEED_PRICE >> MAX_HALVINGS`, so the floor binds once decay clamps.
    uint256 internal constant MIN_PRICE = 400_000_000_000_000;

    uint256 internal constant GOV_SUPPLY = 1_000_000_000e18;
    uint256 internal constant BIDDER_START = 100_000e18;

    uint256 internal constant T0 = 1_000_000;

    LelantosToken internal gov;
    FeeBurner internal burner;
    MockERC20 internal feeToken;

    address internal owner = makeAddr("timelockOwner");
    address internal bidder = makeAddr("bidder");
    address internal secondary = makeAddr("secondaryTreasury");
    address internal govHolder = makeAddr("govHolder");

    /// Model seconds since T0, so every warp is absolute.
    uint256 internal elapsed;

    function setUp() public virtual {
        vm.warp(T0);

        gov = new LelantosToken("Lelantos", "LNT", GOV_SUPPLY, govHolder);
        burner = new FeeBurner(gov, owner, HALF_LIFE, MAX_HALVINGS, RESTART_MULT_BPS, BURN_BPS, secondary);
        feeToken = new MockERC20("Fee", "FEE", 18);

        vm.prank(govHolder);
        gov.transfer(bidder, BIDDER_START);
        vm.prank(bidder);
        gov.approve(address(burner), type(uint256).max);

        assertEq(burner.halfLife(), HALF_LIFE, "spec and burner disagree on halfLife");
        assertEq(burner.maxHalvings(), MAX_HALVINGS, "spec and burner disagree on maxHalvings");
        assertEq(burner.restartMultBps(), RESTART_MULT_BPS, "spec and burner disagree on restartMultBps");
        assertEq(burner.burnBps(), BURN_BPS, "spec and burner disagree on burnBps");
        assertEq(gov.totalSupply(), GOV_SUPPLY, "spec and token disagree on supply");
        assertEq(gov.balanceOf(bidder), BIDDER_START, "spec and token disagree on the bidder's start");
    }

    // --- the switch -------------------------------------------------------

    function apply_(FeeBurnerSpec.Action action, FeeBurnerSpec.Picks memory picks) external override {
        require(msg.sender == address(this), "self-call only");

        if (action == FeeBurnerSpec.Action.AccrueFees) {
            // What `FeeConfig.sweep` does when the burner is the treasury: fee
            // tokens simply arrive. The route is not what this spec is about.
            uint256 amt = picks.p;
            feeToken.mint(address(burner), amt);
        } else if (action == FeeBurnerSpec.Action.Buy) {
            uint256 amt = picks.p;
            vm.prank(bidder);
            burner.buy(IERC20(address(feeToken)), amt, type(uint256).max, bidder);
        } else if (action == FeeBurnerSpec.Action.Wait) {
            uint256 dt = picks.p;
            elapsed += dt;
            vm.warp(T0 + elapsed);
        } else if (action == FeeBurnerSpec.Action.SetLot) {
            // `setLot` overwrites the whole struct in either direction, so the
            // same prices go in whether enabling or disabling. `p` is the
            // spec's quarters draw: enabled on three of the four, which is how
            // `buy` gets reached often enough to matter.
            vm.prank(owner);
            burner.setLot(IERC20(address(feeToken)), picks.p > 0, SEED_PRICE, MIN_PRICE, 0);
        } else if (action == FeeBurnerSpec.Action.SetPaused) {
            vm.prank(owner);
            burner.setPaused(picks.p == 0);
        } else {
            revert("unhandled action");
        }
    }

    /// An uncacheable read of the clock. `_project` is inlined into the replay
    /// loop, and under `via_ir` a plain `block.timestamp` there is hoisted out
    /// of it - every step would then read T0 however many times `wait` warped.
    function quintNow() external view returns (uint256) {
        return block.timestamp;
    }

    // --- projection -------------------------------------------------------

    function _project() internal view override returns (FeeBurnerSpec.State memory s) {
        s.nowTs = this.quintNow() - T0;

        (bool enabled, uint48 startedAt,, uint256 startPrice, uint256 minPrice) = burner.lots(IERC20(address(feeToken)));
        s.lotEnabled = enabled;
        s.startedAt = startedAt == 0 ? 0 : uint256(startedAt) - T0;
        s.startPrice = startPrice;
        s.minPrice = minPrice;

        s.paused = burner.paused();
        s.burnerTokenBal = feeToken.balanceOf(address(burner));
        s.burnerGovBal = gov.balanceOf(address(burner));
        s.govSupply = gov.totalSupply();
        s.bidderGov = gov.balanceOf(bidder);
        s.secondaryGov = gov.balanceOf(secondary);
    }
}
