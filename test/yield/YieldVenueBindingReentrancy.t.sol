// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YieldBase } from "./YieldBase.t.sol";

/// A venue that tries to act on the pool while `YieldOps.initAsset` is
/// verifying its binding. `POOL()` is the first external call that path makes,
/// so it is the earliest point an operator-supplied contract runs inside
/// `addYieldAsset`.
contract ReenteringVenue {
    address public immutable POOL_ADDR;
    address public immutable VAULT_ADDR;

    /// Written from `POOL()`. A plain storage write is the cheapest proof that
    /// the caller allowed state modification.
    uint256 public touched;

    constructor(address pool_, address vault_) {
        POOL_ADDR = pool_;
        VAULT_ADDR = vault_;
    }

    /// Declared non-view deliberately. `IYieldVenue.POOL()` is `view`, so the
    /// pool reaches this through STATICCALL and the write below reverts.
    // solhint-disable-next-line no-empty-blocks
    function POOL() external returns (address) {
        touched = 1;
        return POOL_ADDR;
    }

    function VAULT() external view returns (address) {
        return VAULT_ADDR;
    }

    function deposit(uint256) external { }
    function withdraw(uint256) external { }

    function totalAssets() external pure returns (uint256) {
        return 0;
    }

    function maxWithdraw() external pure returns (uint256) {
        return 0;
    }
}

/// The venue-binding path cannot be re-entered, and the property is structural
/// rather than guarded.
///
/// `initAsset` reads `POOL()`, `VAULT()` and the vault's `asset()`, and every
/// one is `view` on its interface, so Solidity emits STATICCALL. An
/// operator-supplied venue therefore cannot write storage, call a
/// state-changing pool entry point, or observe the pool mid-registration in any
/// way that outlives the call.
///
/// This is what makes the ordering inside `addYieldAsset` — registry write
/// before venue binding — safe without a reentrancy guard. Dropping `view` from
/// any of those three declarations would open a window in which `_assets[id]`
/// exists while `params[id].venue` is still zero, so `id` reads as a plain
/// asset: a deposit taken there prices on the plain branch and is then
/// unresolvable, because `flushBatch` and `cancelDeposit` both take the yield
/// branch afterwards and underflow a `totalNormalized` that was never credited.
///
/// The assertion below is what stops that change from landing silently.
contract YieldVenueBindingReentrancyTest is YieldBase {
    uint64 internal constant NEW_ID = 77;

    function test_venueCannotMutateDuringBinding() public {
        ReenteringVenue v = new ReenteringVenue(address(masp), address(vault));

        // The staticcall makes the venue's storage write fail, which surfaces
        // as the whole registration reverting.
        vm.prank(OWNER);
        vm.expectRevert();
        masp.addYieldAsset(NEW_ID, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(v), BUFFER_BPS, PERF_BPS);

        assertEq(v.touched(), 0, "venue mutated state during addYieldAsset: POOL() is no longer a staticcall");
        assertFalse(masp.isYieldAsset(NEW_ID), "binding survived a reverted registration");
    }
}
