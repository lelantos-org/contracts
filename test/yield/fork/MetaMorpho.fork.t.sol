// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { ERC4626Venue } from "../../../src/yield/ERC4626Venue.sol";

/// `ERC4626Venue` against a real vault.
///
/// Skipped unless `FORK_TESTS=1`, matching `test/swap/fork/UniV4Adapter.fork.t.sol`,
/// so the default `forge test` stays offline. It also needs the vault naming
/// which is still open — the MetaMorpho vault per chain has not been chosen, and
/// the binding an `addYieldAsset` creates is permanent, so this suite takes the
/// vault from the environment rather than hardcoding a guess:
///
///   FORK_TESTS=1 \
///   MAINNET_RPC_URL=... \
///   YIELD_FORK_VAULT=0x... \
///   forge test --match-path 'test/yield/fork/*'
///
/// What this covers that the mock cannot: that a production vault's
/// `convertToAssets` / `maxWithdraw` / `deposit` / `withdraw` behave the way the
/// index assumes, in particular that a round trip never returns more than it
/// took and that `maxWithdraw` is a usable gate rather than an optimistic one.
contract MetaMorphoForkTest is Test {
    ERC4626Venue internal venue;
    IERC4626 internal vault;
    IERC20 internal underlying;
    address internal constant POOL = address(0xB0B0);

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        address vaultAddr = vm.envOr("YIELD_FORK_VAULT", address(0));
        if (vaultAddr == address(0)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.rpcUrl(vm.envOr("YIELD_FORK_CHAIN", string("mainnet"))));

        vault = IERC4626(vaultAddr);
        underlying = IERC20(vault.asset());
        venue = new ERC4626Venue(POOL, vaultAddr, address(underlying));
    }

    /// The constructor's binding check is the one thing standing between a
    /// typo and an asset id bound forever to the wrong vault.
    function test_constructorRejectsMismatchedUnderlying() public {
        vm.expectRevert();
        new ERC4626Venue(POOL, address(vault), address(0xdead));
    }

    /// Supply, then read the position back the way the index does.
    function test_depositThenTotalAssets_roundTrips() public {
        uint256 amount = 10 ** IERC20Metadata(address(underlying)).decimals() * 1_000;
        deal(address(underlying), address(venue), amount);

        vm.prank(POOL);
        venue.deposit(amount);

        // Vaults round in their own favour, so the position may read a hair
        // below what went in. It must never read above.
        assertLe(venue.totalAssets(), amount, "position never reads above what was supplied");
        assertApproxEqRel(venue.totalAssets(), amount, 1e15, "and lands within 0.1%");
    }

    /// `maxWithdraw` must be a gate the pool can trust: whatever it reports as
    /// available has to actually be withdrawable.
    function test_maxWithdrawIsHonoured() public {
        uint256 amount = 10 ** IERC20Metadata(address(underlying)).decimals() * 1_000;
        deal(address(underlying), address(venue), amount);
        vm.prank(POOL);
        venue.deposit(amount);

        uint256 avail = venue.maxWithdraw();
        assertGt(avail, 0, "a funded position reports something withdrawable");

        uint256 poolBefore = underlying.balanceOf(POOL);
        vm.prank(POOL);
        venue.withdraw(avail);
        assertEq(underlying.balanceOf(POOL) - poolBefore, avail, "withdraw sends the underlying straight to the pool");
    }

    /// Only the pinned pool may move the position.
    function test_onlyPoolMayDepositOrWithdraw() public {
        vm.expectRevert(ERC4626Venue.UnauthorizedCaller.selector);
        venue.deposit(1);
        vm.expectRevert(ERC4626Venue.UnauthorizedCaller.selector);
        venue.withdraw(1);
    }
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
