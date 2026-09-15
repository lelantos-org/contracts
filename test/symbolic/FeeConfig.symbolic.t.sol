// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { SymTest } from "halmos-cheatcodes/SymTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FeeConfig } from "../../src/FeeConfig.sol";
import { OwnableInit } from "../../src/OwnableInit.sol";
import { FeeConfigHarness } from "../core/FeeConfig.t.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// Symbolic proofs for fee accrual and the owner-pinned sweep destination.
///
/// The treasury determines where swept fees go, and `sweep` is permissionless.
/// `check_noNonOwnerCallMovesTreasuryOrOwner` quantifies over symbolic calldata
/// rather than enumerating owner-gated functions, so any added external function
/// is covered without editing the test.
contract FeeConfigSymbolicTest is GuardAsserts, SymTest {
    FeeConfigHarness internal fc;
    MockERC20 internal token;
    IERC20 internal t;

    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0xB0B);

    function setUp() public {
        token = new MockERC20("T", "T", 18);
        fc = new FeeConfigHarness(TREASURY, OWNER);
        t = IERC20(address(token));
        // Covers every sweep of the bounded accruals below.
        token.mint(address(fc), type(uint128).max);
    }

    // --- Access control ----------------------------------------------------

    /// No non-owner call moves the treasury or the owner, for any calldata.
    /// `svm.createCalldata` includes permissionless functions (`sweep`, the
    /// harness's `accrue`) that may succeed, so the property concerns resulting
    /// state rather than reverts.
    ///
    /// Reverting calls are discarded, since a revert rolls back all state.
    function check_noNonOwnerCallMovesTreasuryOrOwner(address caller) public {
        vm.assume(caller != OWNER);

        bytes memory data = svm.createCalldata("FeeConfigHarness");

        vm.prank(caller);
        (bool success,) = address(fc).call(data);
        vm.assume(success);

        assertEq(fc.treasury(), TREASURY);
        assertEq(fc.owner(), OWNER);
    }

    /// `setTreasury` from a non-owner reverts with the OZ-compatible error, for
    /// every caller and every proposed destination.
    function check_setTreasury_rejectsEveryNonOwner(address caller, address newTreasury) public {
        vm.assume(caller != OWNER);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(fc).call(abi.encodeCall(FeeConfig.setTreasury, (newTreasury)));

        _assertRejected(ok, ret, OwnableInit.OwnableUnauthorizedAccount.selector);
        assertEq(fc.treasury(), TREASURY);
    }

    /// The owner can set any non-zero treasury, and zero is the only rejected
    /// value. Both directions are proved, ruling out an over-strict guard.
    function check_setTreasury_ownerAcceptsExactlyNonZero(address newTreasury) public {
        vm.prank(OWNER);
        (bool ok,) = address(fc).call(abi.encodeCall(FeeConfig.setTreasury, (newTreasury)));

        assertEq(ok, newTreasury != address(0));
        assertEq(fc.treasury(), newTreasury == address(0) ? TREASURY : newTreasury);
    }

    /// Ownership can never be dropped, whatever the owner does.
    ///
    /// `OwnableInit` omits `renounceOwnership` and rejects a zero `newOwner`,
    /// because an unowned pool cannot register assets, change fees or be
    /// transferred to governance. Stated over the owner's whole calldata surface
    /// rather than only `transferOwnership`, so any added function that could
    /// zero the owner is covered.
    function check_ownershipCannotBeDropped() public {
        bytes memory data = svm.createCalldata("FeeConfigHarness");

        vm.prank(OWNER);
        (bool success,) = address(fc).call(data);
        vm.assume(success);

        assertTrue(fc.owner() != address(0), "pool is never left unowned");
    }

    // --- Accrual and sweep -------------------------------------------------

    /// Accrual is additive for every pair of amounts, zero included. The
    /// `uint120` widths keep the sum within the pre-funded balance.
    function check_accrue_isAdditive(uint120 a, uint120 b) public {
        fc.accrue(t, a);
        fc.accrue(t, b);
        assertEq(fc.accruedFee(t), uint256(a) + uint256(b));
    }

    /// Sweep transfers exactly the accrued amount to the treasury and clears the
    /// accrual, so a second sweep returns zero. Proved for every accrual pair;
    /// `test/fuzz/FeeConfig.fuzz.t.sol` samples the same property.
    function check_sweep_drainsExactlyAccrual(uint120 a, uint120 b) public {
        uint256 total = uint256(a) + uint256(b);
        uint256 poolBefore = token.balanceOf(address(fc));
        uint256 treasuryBefore = token.balanceOf(TREASURY);

        fc.accrue(t, a);
        fc.accrue(t, b);

        assertEq(fc.sweep(t), total);
        assertEq(fc.accruedFee(t), 0);
        assertEq(token.balanceOf(TREASURY), treasuryBefore + total);
        assertEq(token.balanceOf(address(fc)), poolBefore - total);
        assertEq(fc.sweep(t), 0);
    }
}
