// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { YieldIndex } from "../../src/yield/YieldIndex.sol";
import { YieldOps } from "../../src/yield/YieldOps.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { YieldTestBase } from "../utils/YieldTestBase.sol";

/// Venue liveness for the pool-managed yield index: drained, capped, paused and
/// fee-charging vaults, emergency unwind and resume, and buffer banding.
contract YieldIndexLivenessTest is YieldTestBase {
    uint64 internal constant N = 1_000_000; // units; fee at 25bps is 2_500

    // ============== Venue liveness ===========================================

    /// A drained venue is a liveness failure, not a loss: the spend reverts
    /// entirely, so its nullifiers stay unspent and the note remains.
    function test_drainedVenue_revertsWithdraw_andLeavesNullifiersUnspent() public {
        _deposit(YIELD_ID, N, 0x101);
        vault.setLiquidityCap(0);

        PubInputs.Transact memory pi;
        pi.chainId = block.chainid;
        pi.publicAssetId = YIELD_ID;
        pi.publicOut = N;
        pi.recipient = RECIPIENT;
        pi.payer = SPEND_PAYER;
        pi.relayer = RELAYER;
        pi.merkleRoot = masp.currentRoot();

        vm.expectRevert();
        this.attemptWithdraw(YIELD_ID, N, 0x2222);

        assertFalse(masp.spent(bytes32(uint256(0x2222))), "nullifier untouched by the reverted spend");
    }

    /// After an unwind the venue is off the withdrawal path; venue liveness
    /// recovery depends on this.
    function test_emergencyUnwind_takesVenueOffTheWithdrawalPath() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 idxBefore = masp.index(YIELD_ID);

        vm.prank(OWNER);
        masp.emergencyUnwind(YIELD_ID);

        assertEq(masp.index(YIELD_ID), idxBefore, "unwind moves tokens, it does not revalue notes");
        assertEq(_idle(YIELD_ID), _gross(YIELD_ID), "everything is idle");

        // The vault becomes fully illiquid; withdrawals still succeed.
        vault.setLiquidityCap(0);
        uint256 before = token.balanceOf(RECIPIENT);
        _withdraw(YIELD_ID, N, 0x3333);
        assertGt(token.balanceOf(RECIPIENT) - before, 0, "served entirely from idle");
    }

    /// Unwind must not clear the binding: doing so would flip the asset onto
    /// the plain arithmetic, where the same integers mean underlying.
    function test_emergencyUnwind_keepsVenueBoundAndAssetIndexed() public {
        _deposit(YIELD_ID, N, 0x101);
        vm.prank(OWNER);
        masp.emergencyUnwind(YIELD_ID);

        YieldIndex.YieldState memory st = masp.yieldState(YIELD_ID);
        assertEq(st.venue, address(venue), "venue still bound after unwind");
        assertTrue(st.halted, "halted instead");
        assertTrue(masp.isYieldAsset(YIELD_ID), "still an indexed asset");
    }

    function test_setHalted_resumesFundingTheSameVault() public {
        _deposit(YIELD_ID, N, 0x101);
        vm.prank(OWNER);
        masp.emergencyUnwind(YIELD_ID);
        assertEq(vault.balanceOf(address(venue)), 0, "position closed");

        vm.prank(OWNER);
        masp.setHalted(YIELD_ID, false);
        masp.rebalance(YIELD_ID);
        assertGt(vault.balanceOf(address(venue)), 0, "re-supplied to the one bound vault");
    }

    /// A draw leaves the buffer replenished, not empty. Otherwise the first
    /// withdrawal to exceed the buffer would leave `idle` at zero and every
    /// later withdrawal, however small, would also reach the venue.
    function test_venueDraw_refillsTheBuffer() public {
        _deposit(YIELD_ID, N, 0x101);
        // Larger than the 5% buffer, so the venue must be drawn on.
        _withdraw(YIELD_ID, N / 4, 0x7001);

        uint256 g = _gross(YIELD_ID);
        assertApproxEqRel(_idle(YIELD_ID), (g * BUFFER_BPS) / 10_000, 1e16, "buffer restored in the same draw");
    }

    /// Funding is banded: a deposit supplies the venue only once idle reaches
    /// twice the target, then brings it back down to the target. The band keeps
    /// the ERC-4626 mint off the common deposit path.
    function test_funding_isBandedNotPerDeposit() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 shares = vault.balanceOf(address(venue));

        // A deposit far too small to cross the band leaves the venue untouched.
        _deposit(YIELD_ID, 1_000, 0x501);
        assertEq(vault.balanceOf(address(venue)), shares, "small deposit does not touch the venue");
        assertGt(_idle(YIELD_ID), (_gross(YIELD_ID) * BUFFER_BPS) / 10_000, "it accumulates as idle instead");
    }

    /// A vault at its deposit cap takes only what fits. The supply is clamped to
    /// `maxDeposit` and the rest stays idle, rather than the ERC-4626 deposit
    /// reverting and taking the shield with it.
    function test_deposit_capacityCappedVenueKeepsExcessIdle() public {
        uint256 room = 1_000 * SCALE;
        vault.setDepositCap(room);

        _deposit(YIELD_ID, N, 0x101);

        uint256 g = _gross(YIELD_ID);
        assertEq(vault.convertToAssets(vault.balanceOf(address(venue))), room, "venue filled to its cap");
        assertEq(_idle(YIELD_ID), g - room, "the excess stays idle");
        assertGt(_idle(YIELD_ID), (g * BUFFER_BPS) / 10_000, "above the buffer target");
        assertEq(token.balanceOf(address(masp)), _idle(YIELD_ID), "idle is exactly what the pool holds");
    }

    /// A paused vault (`maxDeposit == 0`) is skipped: the shield lands with
    /// everything idle, and the next `rebalance` after the vault reopens
    /// supplies it.
    function test_deposit_pausedVenueStillAcceptsShield() public {
        vault.setDepositCap(0);

        (uint256 id,) = _deposit(YIELD_ID, N, 0x101);

        assertTrue(masp.escrowed(id) != bytes32(0), "shield escrowed");
        assertEq(vault.balanceOf(address(venue)), 0, "nothing supplied to the paused vault");
        assertEq(_idle(YIELD_ID), _gross(YIELD_ID), "everything idle");

        vault.setDepositCap(type(uint256).max);
        masp.rebalance(YIELD_ID);
        assertEq(_idle(YIELD_ID), (_gross(YIELD_ID) * BUFFER_BPS) / 10_000, "rebalance supplies it once reopened");
    }

    /// `idle` is credited with what the venue delivered, not with what the pool
    /// asked for. A vault with an exit fee that still covers the withdrawal's
    /// shortfall lets it through, and the fee comes out of the refill: `idle`
    /// stays equal to the pool's balance, so nothing is paid from another id's
    /// share of the ERC-20.
    function test_venueDraw_creditsMeasuredDelivery() public {
        _deposit(YIELD_ID, N, 0x101);
        assertEq(token.balanceOf(address(masp)), _idle(YIELD_ID), "books match before the draw");
        vault.setWithdrawHaircut(1_000);

        // Larger than the 5% buffer, so the venue must be drawn on.
        _withdraw(YIELD_ID, N / 4, 0x7001);

        assertEq(token.balanceOf(address(masp)), _idle(YIELD_ID), "idle credits the delivery, not the request");
    }

    /// A venue that delivers less than the withdrawal's shortfall reverts the
    /// spend, as a drained one does, instead of paying the difference out of
    /// balances held for other ids.
    function test_revert_VenueUnderDelivered_drawShortOfTheNeed() public {
        _deposit(YIELD_ID, N, 0x101);
        _deposit(PLAIN_ID, N, 0x201);
        vault.setWithdrawHaircut(1_000 * SCALE * 100);

        vm.expectPartialRevert(YieldOps.VenueUnderDelivered.selector);
        this.attemptWithdraw(YIELD_ID, N / 4, 0x7002);
        assertFalse(masp.spent(bytes32(uint256(0x7002))), "nullifier untouched by the reverted spend");
    }

    /// An unwind from a vault with an exit fee credits what arrived. It does not
    /// revert, since it is the recovery path; the fee reads as a venue loss.
    function test_emergencyUnwind_creditsMeasuredRecovery() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 haircut = 1_000;
        vault.setWithdrawHaircut(haircut);
        uint256 position = vault.convertToAssets(vault.balanceOf(address(venue)));

        vm.prank(OWNER);
        uint256 recovered = masp.emergencyUnwind(YIELD_ID);

        assertEq(recovered, position - haircut, "reports the delivery");
        assertEq(token.balanceOf(address(masp)), _idle(YIELD_ID), "idle is exactly what the pool holds");
    }

    /// `rebalance` targets the buffer exactly, so calling it twice does not
    /// oscillate: the second call is a no-op.
    function test_rebalance_isIdempotent() public {
        _deposit(YIELD_ID, N, 0x101);
        _deposit(YIELD_ID, 1_000, 0x501);

        masp.rebalance(YIELD_ID);
        uint256 idleAfterFirst = _idle(YIELD_ID);
        uint256 sharesAfterFirst = vault.balanceOf(address(venue));

        masp.rebalance(YIELD_ID);
        assertEq(_idle(YIELD_ID), idleAfterFirst, "idle unchanged by a second rebalance");
        assertEq(vault.balanceOf(address(venue)), sharesAfterFirst, "and so is the position");
    }
}
