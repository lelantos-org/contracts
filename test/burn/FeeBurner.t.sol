// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FeeBurnerTestBase } from "./FeeBurnerTestBase.sol";

/// Integration of `FeeBurner` with a real pool: fees accrued at flush reach the
/// burner through the permissionless `sweep` and through `harvest`.
///
/// The auction itself is covered by `FeeBurner.{price,buy,admin}.t.sol`.
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
}
