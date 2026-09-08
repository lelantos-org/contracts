// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LelantosToken } from "../../src/governance/LelantosToken.sol";
import { FeeBurner } from "../../src/burn/FeeBurner.sol";

import { EscrowFlowBase } from "../utils/EscrowFlowBase.sol";

/// A pool whose `treasury` is the burner, so fees arrive through the production
/// accrual and sweep paths rather than a mint.
///
/// The Governor is not deployed here; the burner's owner is a stand-in address.
/// Governance reaching these setters is covered by
/// `test/governance/Governor.lifecycle.t.sol`.
abstract contract FeeBurnerTestBase is EscrowFlowBase {
    uint256 internal constant GOV_SUPPLY = 1_000_000_000e18;
    uint32 internal constant HALF_LIFE = 1 hours;
    uint8 internal constant MAX_HALVINGS = 12;
    uint16 internal constant RESTART_MULT_BPS = 20_000;

    /// 1 fee-token base unit costs 2 GOV wei, i.e. a 1:2 ratio at 18 decimals.
    uint256 internal constant SEED_PRICE = 2e18;
    uint256 internal constant MIN_PRICE = 1e12;

    LelantosToken internal gov;
    FeeBurner internal burner;

    address internal timelockOwner = makeAddr("timelockOwner");
    address internal govHolder = makeAddr("govHolder");
    address internal bidder = makeAddr("bidder");
    address internal bidder2 = makeAddr("bidder2");

    function setUp() public virtual override {
        // The burner must exist before the pool, since it is the pool's treasury.
        gov = new LelantosToken("Lelantos", "LNT", GOV_SUPPLY, govHolder);
        burner = new FeeBurner(gov, timelockOwner, HALF_LIFE, MAX_HALVINGS, RESTART_MULT_BPS, 10_000, address(0));
        treasury = address(burner);

        super.setUp();

        vm.startPrank(govHolder);
        gov.transfer(bidder, 100_000e18);
        gov.transfer(bidder2, 100_000e18);
        vm.stopPrank();
        vm.prank(bidder);
        gov.approve(address(burner), type(uint256).max);
        vm.prank(bidder2);
        gov.approve(address(burner), type(uint256).max);
    }

    /// Fees reaching the burner through a deposit and flush. Requires no protocol
    /// changes: `sweep` is permissionless and pays `treasury`.
    function _accrueRealFees(uint64 publicIn) internal returns (uint256 fee) {
        return _depositAndFlush(publicIn, bytes32(uint256(0x111)));
    }

    /// Fee tokens placed directly in the burner, for auction mechanics that do
    /// not require the pool flow.
    function _seedBurner(uint256 amount) internal {
        token.mint(address(burner), amount);
    }

    function _enableLot() internal {
        vm.prank(timelockOwner);
        burner.setLot(IERC20(address(token)), true, SEED_PRICE, MIN_PRICE, 0);
    }
}
