// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { SymTest } from "halmos-cheatcodes/SymTest.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { Fees } from "../../src/libs/Fees.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";

/// Minimal concrete `AssetRegistry`.
///
/// The registry has no arithmetic and no external calls, so nothing is mocked.
/// The harness adds an owner and read access to internal lookups, including
/// the withdraw raise queued in the `ExitTerms` namespace.
contract AssetRegistryHarness is AssetRegistry {
    constructor(address owner_) {
        _initOwner(owner_);
    }

    function getAsset(uint64 id) external view returns (AssetEntry memory) {
        return _getAsset(id);
    }

    function pendingWithdraw(uint64 id) external view returns (uint256 value, uint256 notBefore) {
        ExitTerms.Pending storage p = ExitTerms.$().withdrawBps[id];
        return (p.value, p.notBefore);
    }
}

/// Symbolic proofs for the asset registry.
///
/// The registry is add-only: an id's token and scale underlie the escrow digest
/// and every unit conversion, and `MASP.addYieldAsset` pairs registration with a
/// permanent venue binding. The proofs quantify over asset ids, since per-id
/// isolation and add-only permanence are statements about mapping keys.
contract AssetRegistrySymbolicTest is GuardAsserts, SymTest {
    AssetRegistryHarness internal reg;

    address internal constant OWNER = address(0xA11CE);
    IERC20 internal constant TOKEN = IERC20(address(0xBEEF));
    uint256 internal constant SCALE = 1e10;

    function setUp() public {
        reg = new AssetRegistryHarness(OWNER);
    }

    /// Registration succeeds exactly when the inputs satisfy the conjunction of
    /// the four guards: non-zero token, non-zero scale, scale at most 1e18, and
    /// both rates within `MAX_FEE_BPS`.
    ///
    /// Both directions are checked: an over-strict guard would reject a needed
    /// asset, and an over-loose one would admit a zero token, a zero scale
    /// (division by zero in conversions), or a rate above the 20% ceiling.
    function check_addAsset_acceptsExactlyValidInputs(
        uint64 id,
        address token,
        uint256 scale,
        uint16 depositBps,
        uint16 withdrawBps
    ) public {
        bool valid = token != address(0) && scale != 0 && scale <= 1e18 && depositBps <= Fees.MAX_FEE_BPS
            && withdrawBps <= Fees.MAX_FEE_BPS;

        vm.prank(OWNER);
        (bool ok,) = address(reg)
            .call(abi.encodeCall(AssetRegistry.addAsset, (id, IERC20(token), scale, depositBps, withdrawBps)));

        assertEq(ok, valid);
    }

    /// A successful registration writes exactly the requested entry, enabled,
    /// for any id.
    function check_addAsset_writesTheRequestedEntry(uint64 id, uint256 scale, uint16 depositBps, uint16 withdrawBps)
        public
    {
        vm.assume(scale != 0 && scale <= 1e18);
        vm.assume(depositBps <= Fees.MAX_FEE_BPS && withdrawBps <= Fees.MAX_FEE_BPS);

        vm.prank(OWNER);
        reg.addAsset(id, TOKEN, scale, depositBps, withdrawBps);

        AssetRegistry.AssetEntry memory a = reg.getAsset(id);
        assertEq(address(a.token), address(TOKEN));
        assertEq(a.scale, scale);
        assertEq(a.depositBps, depositBps);
        assertEq(a.withdrawBps, withdrawBps);
        assertFalse(a.disabled);
    }

    /// An id can be registered once. A second attempt reverts regardless of its
    /// arguments, so re-adding cannot change the token or scale.
    function check_addAsset_rejectsDuplicateId(uint64 id, address token2, uint256 scale2) public {
        vm.assume(scale2 != 0 && scale2 <= 1e18);

        vm.startPrank(OWNER);
        reg.addAsset(id, TOKEN, SCALE, 0, 0);
        (bool ok,) = address(reg).call(abi.encodeCall(AssetRegistry.addAsset, (id, IERC20(token2), scale2, 0, 0)));
        vm.stopPrank();

        assertFalse(ok);
        assertEq(address(reg.getAsset(id).token), address(TOKEN));
        assertEq(reg.getAsset(id).scale, SCALE);
    }

    /// Add-only over the whole owner-callable surface: no successful call by the
    /// owner, the most privileged account, changes a registered id's token or
    /// scale.
    ///
    /// The escrow digest and every unit conversion depend on this.
    /// `svm.createCalldata` quantifies over the harness ABI, so any added function
    /// that could change an asset is covered without editing the test.
    function check_registeredAssetIsPermanent(uint64 id) public {
        vm.prank(OWNER);
        reg.addAsset(id, TOKEN, SCALE, 100, 100);

        bytes memory data = svm.createCalldata("AssetRegistryHarness");

        vm.prank(OWNER);
        (bool success,) = address(reg).call(data);
        vm.assume(success);

        AssetRegistry.AssetEntry memory a = reg.getAsset(id);
        assertEq(address(a.token), address(TOKEN));
        assertEq(a.scale, SCALE);
    }

    /// A fee change affects only the id named in the call. The registry has no
    /// pool-wide rate and no unset sentinel, and the proof quantifies over both
    /// ids to cover mapping-key errors.
    function check_setAssetFee_touchesOnlyTheNamedId(uint64 id, uint64 other, uint16 depositBps, uint16 withdrawBps)
        public
    {
        vm.assume(id != other);
        vm.assume(depositBps <= Fees.MAX_FEE_BPS && withdrawBps <= Fees.MAX_FEE_BPS);

        vm.startPrank(OWNER);
        reg.addAsset(id, TOKEN, SCALE, 10, 20);
        reg.addAsset(other, TOKEN, SCALE, 30, 40);
        reg.setAssetFee(id, depositBps, withdrawBps);
        vm.stopPrank();

        // A withdraw raise above the registered 20 is queued, not applied.
        AssetRegistry.AssetEntry memory a = reg.getAsset(id);
        assertEq(a.depositBps, depositBps);
        assertEq(a.withdrawBps, withdrawBps <= 20 ? withdrawBps : 20);
        (uint256 otherPending,) = reg.pendingWithdraw(other);
        assertEq(otherPending, 0);

        AssetRegistry.AssetEntry memory b = reg.getAsset(other);
        assertEq(b.depositBps, 30);
        assertEq(b.withdrawBps, 40);
    }

    /// Disabling one asset leaves every other id enabled.
    function check_setAssetDisabled_touchesOnlyTheNamedId(uint64 id, uint64 other) public {
        vm.assume(id != other);

        vm.startPrank(OWNER);
        reg.addAsset(id, TOKEN, SCALE, 0, 0);
        reg.addAsset(other, TOKEN, SCALE, 0, 0);
        reg.setAssetDisabled(id, true);
        vm.stopPrank();

        assertTrue(reg.getAsset(id).disabled);
        assertFalse(reg.getAsset(other).disabled);
    }

    /// A withdraw-rate raise never takes effect in the call that sets it, for
    /// any start, target and deposit rate; a decrease always does.
    ///
    /// The withdraw rate is read at execution rather than snapshotted, so an
    /// immediate raise would reach every holder, including those leaving ahead
    /// of an upgrade. A raise is queued with the full notice instead, which no
    /// call order can shorten. The deposit rate is bound into the escrow digest
    /// at submit and applies at once; the proof covers both legs.
    function check_setAssetFee_withdrawRaiseNeverTakesEffectImmediately(
        uint16 startWithdraw,
        uint16 newWithdraw,
        uint16 newDeposit
    ) public {
        vm.assume(startWithdraw <= Fees.MAX_FEE_BPS && newWithdraw <= Fees.MAX_FEE_BPS);
        vm.assume(newDeposit <= Fees.MAX_FEE_BPS);

        vm.prank(OWNER);
        reg.addAsset(1, TOKEN, SCALE, 0, startWithdraw);

        vm.prank(OWNER);
        (bool ok,) = address(reg).call(abi.encodeCall(AssetRegistry.setAssetFee, (1, newDeposit, newWithdraw)));
        assertTrue(ok);

        bool raise = newWithdraw > startWithdraw;
        AssetRegistry.AssetEntry memory a = reg.getAsset(1);
        assertEq(a.depositBps, newDeposit);
        assertEq(a.withdrawBps, raise ? startWithdraw : newWithdraw);

        (uint256 value, uint256 notBefore) = reg.pendingWithdraw(1);
        assertEq(value, raise ? newWithdraw : 0);
        assertEq(notBefore, raise ? block.timestamp + ExitTerms.DELAY : 0);
    }

    /// A decrease applies at once and withdraws a queued raise, for any queued
    /// value and any rate at or below the live one.
    function check_setAssetFee_decreaseIsImmediateAndDropsAQueuedRaise(
        uint16 startWithdraw,
        uint16 raised,
        uint16 lowered
    ) public {
        vm.assume(raised <= Fees.MAX_FEE_BPS && startWithdraw < raised && lowered <= startWithdraw);

        vm.startPrank(OWNER);
        reg.addAsset(1, TOKEN, SCALE, 0, startWithdraw);
        reg.setAssetFee(1, 0, raised);
        reg.setAssetFee(1, 0, lowered);
        vm.stopPrank();

        assertEq(reg.getAsset(1).withdrawBps, lowered);
        (uint256 value, uint256 notBefore) = reg.pendingWithdraw(1);
        assertEq(value, 0);
        assertEq(notBefore, 0);
    }
}
