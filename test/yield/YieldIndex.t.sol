// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";
import { YieldOps } from "../../src/yield/YieldOps.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";

import { YieldBase } from "./YieldBase.t.sol";

/// Behaviour of the pool-managed yield index.
contract YieldIndexTest is YieldBase {
    uint64 internal constant N = 1_000_000; // units; fee at 25bps is 2_500

    // ============== Shielding ================================================

    /// An empty asset has no ratio yet, so one unit is worth exactly `scale`
    /// and the index reads `RAY`. This is what pins the first deposit.
    function test_firstDeposit_indexIsRay_andPullIsExact() public {
        (, uint256 pulled) = _deposit(YIELD_ID, N, 0x101);
        uint256 nFee = (uint256(N) * FEE_BPS) / 10_000;
        uint256 expected = (uint256(N) + nFee) * SCALE;

        assertEq(pulled, expected, "pull is (publicIn + fee) * scale");
        assertEq(masp.index(YIELD_ID), RAY, "index starts at RAY");
        assertEq(_supply(YIELD_ID), uint256(N) + nFee, "fee units held as principal until flush");
    }

    /// Everything above the buffer target is put to work at submit, not at
    /// flush — a note minted at `n` must be backed by `n` at the index the pool
    /// actually received.
    function test_deposit_fundsVenueDownToBuffer() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 g = _gross(YIELD_ID);
        assertEq(_idle(YIELD_ID), (g * BUFFER_BPS) / 10_000, "idle held at the buffer target");
        assertGt(vault.balanceOf(address(venue)), 0, "remainder supplied to the venue");
    }

    // ============== Earning ==================================================

    /// The whole point: units do not move, their value does.
    function test_earn_thenWithdraw_paysMoreThanWasDeposited() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 perUnitBefore = masp.index(YIELD_ID);

        _earn(1_000 * SCALE);
        assertGt(masp.index(YIELD_ID), perUnitBefore, "index rises with the venue");

        uint256 recipientBefore = token.balanceOf(RECIPIENT);
        _withdraw(YIELD_ID, N, 0x1111);
        uint256 paid = token.balanceOf(RECIPIENT) - recipientBefore;

        uint256 nFee = (uint256(N) * FEE_BPS) / 10_000;
        assertGt(paid, (uint256(N) - nFee) * SCALE, "payout exceeds the flat-rate value of the same units");
    }

    /// `publicOut == publicIn` across a round trip that earned. The circuit
    /// never sees the index, so the published integers are unchanged.
    function test_unitsAreStableAcrossEarning() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 unitsAfterDeposit = _supply(YIELD_ID);
        _earn(5_000 * SCALE);
        assertEq(_supply(YIELD_ID), unitsAfterDeposit, "earning mints no units to holders");
    }

    // ============== Performance fee ==========================================

    function test_perfFee_accruesOnGrowthOnly() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 feeBefore = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertEq(feeBefore, 0, "nothing owed before any growth");

        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);
        uint256 feeAfter = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertGt(feeAfter, 0, "treasury minted units against the growth");

        // ~10% of the growth, valued at the post-accrual index.
        // Floored to whole normalized units, so at `scale = 1e10` the cut can
        // land up to one unit short of the nominal 10%. Never over: rounding
        // points away from the treasury at every step.
        uint256 treasuryValue = (feeAfter * _gross(YIELD_ID)) / _supply(YIELD_ID);
        uint256 nominal = (1_000 * SCALE * PERF_BPS) / 10_000;
        assertLe(treasuryValue, nominal, "never charges more than perfBps of the growth");
        assertGe(treasuryValue + SCALE, nominal, "and is short by less than one unit");
    }

    /// The high-water mark, which costs no extra state: a loss leaves `lastIdx`
    /// untouched, so nothing is charged until the old peak is passed again.
    function test_perfFee_highWaterMark_chargesNothingUntilRecovered() public {
        _deposit(YIELD_ID, N, 0x101);
        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);
        uint256 afterFirst = masp.yieldState(YIELD_ID).accruedFeeNormalized;

        vault.lose(800 * SCALE);
        masp.accruePerf(YIELD_ID);
        uint256 afterLoss = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertEq(afterLoss, afterFirst, "no fee charged through a loss");

        // Recovering only part of the way back still owes nothing.
        _earn(500 * SCALE);
        masp.accruePerf(YIELD_ID);
        uint256 afterPartial = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertEq(afterPartial, afterFirst, "no fee until the old peak is exceeded");

        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);
        uint256 afterRecovery = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertGt(afterRecovery, afterFirst, "charged again only above the mark");
    }

    function test_sweepNormalized_paysTreasuryAndClears() public {
        _deposit(YIELD_ID, N, 0x101);
        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);

        uint256 before = token.balanceOf(TREASURY);
        uint256 amount = masp.sweepNormalized(YIELD_ID);
        assertGt(amount, 0, "treasury paid");
        assertEq(token.balanceOf(TREASURY) - before, amount, "tokens actually moved");
        uint256 feeAfter = masp.yieldState(YIELD_ID).accruedFeeNormalized;
        assertEq(feeAfter, 0, "accumulator cleared");
    }

    /// A sweep worth less than one base unit must leave the accrual alone.
    ///
    /// The accumulator used to be zeroed before the payout was checked, so a
    /// single permissionless call while the pool was deeply under water threw
    /// the treasury's entire balance away for nothing — and silently, since the
    /// `NormalizedFeeSwept` emit sits past that early return.
    function test_sweepNormalized_zeroValueSweepKeepsTheAccrual() public {
        // Zero buffer, so a vault loss can drive `gross` down to dust; `scale`
        // of one is what lets the floored payout reach zero at all.
        vm.prank(OWNER);
        masp.setYieldParams(FINE_ID, 0, PERF_BPS);

        _deposit(FINE_ID, N, 0x101);
        _earnInto(vaultFine, 5e17);
        masp.accruePerf(FINE_ID);
        masp.rebalance(FINE_ID);

        uint256 accrued = masp.yieldState(FINE_ID).accruedFeeNormalized;
        assertGt(accrued, 0, "fee accrued");

        // Near-total loss: those units are now worth less than one base unit.
        vaultFine.lose(vaultFine.totalAssetsHeld() - 1);

        uint256 treasuryBefore = token.balanceOf(TREASURY);
        assertEq(masp.sweepNormalized(FINE_ID), 0, "payout floors to zero");
        assertEq(token.balanceOf(TREASURY), treasuryBefore, "nothing moved");
        assertEq(masp.yieldState(FINE_ID).accruedFeeNormalized, accrued, "accrual survives");

        // Still claimable once the vault recovers.
        _earnInto(vaultFine, 5e17);
        assertGt(masp.sweepNormalized(FINE_ID), 0, "claimable after recovery");
    }

    /// A parameter change must not hand the treasury a fresh water line.
    ///
    /// `setParams` re-marks `lastIdx` so that enabling a fee cannot bill
    /// earlier growth — but it raises the mark only. Were it a plain
    /// assignment, an owner could drop the mark to the post-loss index with a
    /// no-op parameter change and then bill the recovery, defeating the
    /// high-water mark entirely.
    function test_setYieldParams_cannotResetTheHighWaterMarkAfterALoss() public {
        _deposit(YIELD_ID, N, 0x101);
        _earn(2_000 * SCALE);
        masp.accruePerf(YIELD_ID);

        uint256 markAtPeak = masp.yieldState(YIELD_ID).lastIdx;
        uint256 feeAtPeak = masp.yieldState(YIELD_ID).accruedFeeNormalized;

        vault.lose(1_500 * SCALE);

        // A no-op parameter change, at the bottom.
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, PERF_BPS);
        assertEq(masp.yieldState(YIELD_ID).lastIdx, markAtPeak, "mark moved down on a parameter change");

        // Recovering part of the way back must still owe nothing.
        _earn(1_000 * SCALE);
        masp.accruePerf(YIELD_ID);
        assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, feeAtPeak, "billed a recovery below the old peak");
    }

    // ============== Venue liveness ===========================================

    /// A drained venue is a liveness failure, not a loss: the spend reverts
    /// whole, so its nullifiers stay unspent and the note is still there.
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

    /// External so `vm.expectRevert` has a call boundary to catch.
    function attemptWithdraw(uint64 id, uint64 publicOut, uint256 seed) external {
        _withdraw(id, publicOut, seed);
    }

    /// After an unwind the venue is no longer on the withdrawal path at all —
    /// the property the whole liveness story rests on.
    function test_emergencyUnwind_takesVenueOffTheWithdrawalPath() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 idxBefore = masp.index(YIELD_ID);

        vm.prank(OWNER);
        masp.emergencyUnwind(YIELD_ID);

        assertEq(masp.index(YIELD_ID), idxBefore, "unwind moves tokens, it does not revalue notes");
        assertEq(_idle(YIELD_ID), _gross(YIELD_ID), "everything is idle");

        // The vault now dies completely; withdrawals must still work.
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
    /// withdrawal to exceed the buffer would strand `idle` at zero and every
    /// later one — however small — would reach the venue as well.
    function test_venueDraw_refillsTheBuffer() public {
        _deposit(YIELD_ID, N, 0x101);
        // Larger than the 5% buffer, so the venue must be drawn on.
        _withdraw(YIELD_ID, N / 4, 0x7001);

        uint256 g = _gross(YIELD_ID);
        assertApproxEqRel(_idle(YIELD_ID), (g * BUFFER_BPS) / 10_000, 1e16, "buffer restored in the same draw");
    }

    /// Funding is banded: a deposit only supplies the venue once idle has
    /// reached twice the target, then takes it back down to the target. The
    /// band is what keeps the ERC-4626 mint off the common deposit path.
    function test_funding_isBandedNotPerDeposit() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 shares = vault.balanceOf(address(venue));

        // A deposit far too small to cross the band leaves the venue untouched.
        _deposit(YIELD_ID, 1_000, 0x501);
        assertEq(vault.balanceOf(address(venue)), shares, "small deposit does not touch the venue");
        assertGt(_idle(YIELD_ID), (_gross(YIELD_ID) * BUFFER_BPS) / 10_000, "it accumulates as idle instead");
    }

    /// `rebalance` targets the buffer exactly, so calling it twice does not
    /// oscillate — the second call must be a no-op.
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

    // ============== Immutability =============================================

    /// The binding is permanent because the registry is add-only; there is no
    /// `setVenue` to call in the first place.
    function test_venueBindingIsImmutable() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.DuplicateAsset.selector, YIELD_ID));
        masp.addYieldAsset(
            YIELD_ID, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(venue), BUFFER_BPS, PERF_BPS
        );
    }

    /// A venue pinned to some other pool cannot be bound here.
    function test_addYieldAsset_rejectsUnpinnedVenue() public {
        ERC4626VenueStub bad = new ERC4626VenueStub(address(0xdead), address(vault));
        vm.prank(OWNER);
        vm.expectRevert(YieldOps.VenueNotPinned.selector);
        masp.addYieldAsset(77, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(bad), BUFFER_BPS, PERF_BPS);
    }

    // ============== Isolation ================================================

    /// Two ids over one ERC-20: the plain id is ordinary custody and is
    /// untouched by anything the venue does.
    function test_plainIdIsUnaffectedByTheYieldId() public {
        _deposit(PLAIN_ID, N, 0x201);

        _deposit(YIELD_ID, N, 0x301);
        _earn(1_000 * SCALE);
        vault.lose(500 * SCALE);

        assertFalse(masp.isYieldAsset(PLAIN_ID), "plain id carries no venue");
        uint256 before = token.balanceOf(RECIPIENT);
        _withdraw(PLAIN_ID, N, 0x4444);
        uint256 paid = token.balanceOf(RECIPIENT) - before;
        uint256 outAmt = uint256(N) * SCALE;
        assertEq(paid, outAmt - (outAmt * FEE_BPS) / 10_000, "flat-rate payout, unmoved by the venue");
    }

    /// A donation to the pool cannot move the index, because `idle` is tracked
    /// rather than read from `balanceOf` — which is also what lets two ids
    /// share a token.
    function test_donationToPoolCannotMoveTheIndex() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 idxBefore = masp.index(YIELD_ID);
        token.mint(address(masp), 10_000 * SCALE);
        assertEq(masp.index(YIELD_ID), idxBefore, "index is blind to unattributed balance");
    }

    /// A donation to the *venue* is indistinguishable from interest and is
    /// treated as such.
    function test_donationToVenueIsTreatedAsYield() public {
        _deposit(YIELD_ID, N, 0x101);
        uint256 idxBefore = masp.index(YIELD_ID);
        _earn(1_000 * SCALE);
        assertGt(masp.index(YIELD_ID), idxBefore, "venue growth reaches holders");
    }

    // ============== Withdraw-only retirement =================================

    /// `setAssetDisabled` stops new deposits and nothing else. `transfer` in
    /// particular must keep working, or a holder cannot decompose an odd note
    /// into ladder denominations before exiting.
    function test_disabledYieldAsset_blocksDepositsButNotExits() public {
        _deposit(YIELD_ID, N, 0x101);
        vm.prank(OWNER);
        masp.setAssetDisabled(YIELD_ID, true);

        token.mint(payer, type(uint128).max);
        _allow(type(uint160).max);
        PubInputs.DepositRequest memory d = _request(YIELD_ID, N, 0, 0x401);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetDisabled.selector, YIELD_ID));
        masp.depositAuthorized(d, SpendFixture.validAux()[0], SpendFixture.validAux()[1]);

        uint256 before = token.balanceOf(RECIPIENT);
        _withdraw(YIELD_ID, N / 2, 0x5555);
        assertGt(token.balanceOf(RECIPIENT) - before, 0, "holders can still exit");
    }
}

/// A venue that answers `POOL`/`VAULT` but is pinned elsewhere.
contract ERC4626VenueStub {
    address public immutable POOL;
    address public immutable VAULT;

    constructor(address pool, address vault) {
        POOL = pool;
        VAULT = vault;
    }
}
