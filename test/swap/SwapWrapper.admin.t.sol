// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";

import { SwapWrapperUnitBase } from "./SwapWrapperUnitBase.sol";

/// Owner and deployment surface of `SwapWrapper`: the adapter allowlist, the
/// treasury setter, constructor zero-address checks, `prepareToken`, and the
/// same-token guard.
contract SwapWrapperAdminTest is SwapWrapperUnitBase {
    // -------- admin -----------------------------------------------------

    function test_onlyOwnerCanAllowAdapter() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        wrapper.setAdapterAllowed(address(adapter), false);
    }

    function test_ownerCanFlipAllowlist() public {
        assertTrue(wrapper.adapterAllowed(address(adapter)));
        vm.prank(OWNER);
        wrapper.setAdapterAllowed(address(adapter), false);
        assertFalse(wrapper.adapterAllowed(address(adapter)));
    }

    function test_revert_sameToken() public {
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE,
            minOut: 990 * SCALE,
            piOut: 1_000,
            depositIn: 990,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
        a.tokenOut = a.tokenIn;
        vm.expectRevert(SwapWrapper.SameToken.selector);
        _swap(a);
    }

    function test_constructorRejectsZeroPool() public {
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        new SwapWrapper(IMASPPool(address(0)), permit2, OWNER, TREASURY);
    }

    function test_constructorRejectsZeroPermit2() public {
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        new SwapWrapper(pool, IAllowanceTransfer(address(0)), OWNER, TREASURY);
    }

    function test_constructorRejectsZeroTreasury() public {
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        new SwapWrapper(pool, permit2, OWNER, address(0));
    }

    function test_setTreasuryRejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        wrapper.setTreasury(address(0));
    }

    function test_setAdapterAllowedRejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(MaspEscrowSatellite.ZeroAddress.selector);
        wrapper.setAdapterAllowed(address(0), true);
    }

    function test_prepareTokenSetsBothAllowances() public {
        // tokenA has no Permit2 allowance until prepareToken runs.
        wrapper.prepareToken(IERC20(address(tokenA)));
        assertEq(tokenA.allowance(address(wrapper), address(permit2)), type(uint256).max);
        (uint160 cap,,) = permit2.allowance(address(wrapper), address(tokenA), address(pool));
        assertEq(cap, type(uint160).max, "permit2 to pool allowance");
    }

    function test_setTreasuryUpdatesDestination() public {
        address newTreasury = address(0xDEAD5E7);
        vm.expectEmit(true, true, true, true, address(wrapper));
        emit SwapWrapper.TreasurySet(newTreasury);
        vm.prank(OWNER);
        wrapper.setTreasury(newTreasury);
        assertEq(wrapper.treasury(), newTreasury, "treasury updated");
    }

    function test_onlyOwnerCanSetTreasury() public {
        vm.expectRevert();
        wrapper.setTreasury(address(0xDEAD5E7));
    }
}
