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
/// The treasury is the one address in `FeeConfig` that decides where swept fees
/// land, and `sweep` itself is permissionless. That split is what
/// `check_noNonOwnerCallMovesTreasuryOrOwner` covers: rather than enumerating
/// the owner-gated functions by hand, it lets halmos pick the calldata, so a
/// newly added external function is included in the proof the moment it
/// compiles.
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
        // Funds every sweep the uint128-bounded accruals below can ask for.
        token.mint(address(fc), type(uint128).max);
    }

    // --- Access control ----------------------------------------------------

    /// No call from a non-owner moves the treasury or the owner, whatever the
    /// calldata. `svm.createCalldata` enumerates the contract's external
    /// functions symbolically, including the permissionless ones — `sweep` and
    /// the harness's `accrue` may legitimately succeed here, so the property is
    /// about the resulting state, not about the call reverting.
    ///
    /// Reverting calls are dropped rather than asserted on: a reverted call
    /// rolls back all state, so it cannot violate the property.
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

    /// The owner can set any non-zero treasury, and zero is the only value
    /// rejected. Proving both directions rules out an over-strict guard that
    /// would leave fees strandable.
    function check_setTreasury_ownerAcceptsExactlyNonZero(address newTreasury) public {
        vm.prank(OWNER);
        (bool ok,) = address(fc).call(abi.encodeCall(FeeConfig.setTreasury, (newTreasury)));

        assertEq(ok, newTreasury != address(0));
        assertEq(fc.treasury(), newTreasury == address(0) ? TREASURY : newTreasury);
    }

    /// Ownership can never be dropped, whatever the owner does.
    ///
    /// `OwnableInit` deliberately omits `renounceOwnership` and rejects a zero
    /// `newOwner`, because an unowned pool cannot register assets, retune fees
    /// or be handed to governance. Stated over the owner's whole calldata
    /// surface rather than just `transferOwnership`, so a future function that
    /// could zero the slot fails this the moment it compiles.
    function check_ownershipCannotBeDropped() public {
        bytes memory data = svm.createCalldata("FeeConfigHarness");

        vm.prank(OWNER);
        (bool success,) = address(fc).call(data);
        vm.assume(success);

        assertTrue(fc.owner() != address(0), "pool is never left unowned");
    }

    // --- Accrual and sweep -------------------------------------------------

    /// Accrual is additive and order-independent, and a zero amount is a no-op
    /// rather than a write. Widths keep the sum inside the pre-funded balance.
    function check_accrue_isAdditive(uint120 a, uint120 b) public {
        fc.accrue(t, a);
        fc.accrue(t, b);
        assertEq(fc.accruedFee(t), uint256(a) + uint256(b));
    }

    /// Sweep drains exactly what accrued, to the pinned treasury, and leaves
    /// nothing behind — so a second sweep is a no-op. Proved for every accrual
    /// pair, where `test/fuzz/FeeConfig.fuzz.t.sol` samples them.
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
