// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";
import { YieldOps } from "../../src/yield/YieldOps.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";

import { YieldBase } from "./YieldBase.t.sol";

/// The escrow half of the index: what flush and cancel do to the books.
contract YieldEscrowTest is YieldBase {
    uint64 internal constant N = 1_000_000;

    function _feeNote(uint256 seed) internal pure returns (PubInputs.FeeNote memory) {
        return PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(seed + 1), feeCvDep: [uint256(0), 0] });
    }

    function _cancel(uint256 id, uint64 publicIn, uint256 seed, uint32 submittedAt) internal {
        masp.cancelDeposit(
            id, uint48(publicIn), bytes32(seed), [uint256(0), 0], YIELD_ID, FEE_BPS, payer, submittedAt, _feeNote(seed)
        );
    }

    /// A cancellation returns the escrowed units at today's index, so the payer
    /// keeps what their own money earned while it sat in the venue.
    function test_cancel_refundsUnitsAtTodaysIndex_includingEscrowYield() public {
        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id, uint256 pulled) = _deposit(YIELD_ID, N, 0x101);

        _earn(1_000 * SCALE);
        vm.roll(block.number + 7_201); // past the default cancelDelay

        uint256 before = token.balanceOf(payer);
        _cancel(id, N, 0x101, submittedAt);
        uint256 refunded = token.balanceOf(payer) - before;

        assertGt(refunded, pulled, "refund carries the escrow-window yield");

        // The holder's liability is fully released. What remains is the
        // treasury's cut of the growth the escrow itself produced — the
        // performance fee applies to escrowed funds exactly as it does to
        // settled ones, since `_accruePerf` runs before the units are burned.
        YieldIndex.YieldState memory st = masp.yieldState(YIELD_ID);
        assertEq(st.totalNormalized, 0, "holder liability fully released");
        assertGt(st.accruedFeeNormalized, 0, "treasury keeps its cut of the escrow-window growth");
    }

    /// The refund must never exceed the liability it releases: the pull rounds
    /// up and the refund rounds down, so a round trip can only leave the pool
    /// over-backed.
    function test_cancel_neverPaysOutMoreThanIsHeld() public {
        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id,) = _deposit(YIELD_ID, N, 0x101);
        vm.roll(block.number + 7_201);

        uint256 grossBefore = _gross(YIELD_ID);
        uint256 before = token.balanceOf(payer);
        _cancel(id, N, 0x101, submittedAt);
        assertLe(token.balanceOf(payer) - before, grossBefore, "refund bounded by what the pool held");
    }

    /// Flush hands the fee from the holders' pot to the treasury's. It must not
    /// create units: crediting without debiting would inflate `supply` and
    /// dilute every holder.
    function test_flush_isSupplyNeutral_andMovesTheFee() public {
        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id,) = _deposit(YIELD_ID, N, 0x101);

        uint256 supplyBefore = _supply(YIELD_ID);
        YieldIndex.YieldState memory before = masp.yieldState(YIELD_ID);
        assertEq(before.accruedFeeNormalized, 0, "nothing accrued to the treasury before flush");

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xfeedbeef));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        tpi.cms[0] = bytes32(uint256(0x101));
        tpi.cms[1] = bytes32(uint256(0x102));
        tpi.leafAsset[0] = YIELD_ID;
        tpi.leafPublicIn[0] = N;
        tpi.isDeposit[0] = 1;
        tpi.leafAsset[1] = YIELD_ID;
        tpi.leafPublicIn[1] = 0;
        tpi.isDeposit[1] = 1;

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: payer, submittedAt: submittedAt, fbps: FEE_BPS });

        masp.flushBatch(ids, meta, FixtureLoader.emptyProof(), tpi);

        YieldIndex.YieldState memory afterFlush = masp.yieldState(YIELD_ID);
        uint256 nFee = (uint256(N) * FEE_BPS) / 10_000;
        assertEq(_supply(YIELD_ID), supplyBefore, "flush creates and destroys no units");
        assertEq(afterFlush.accruedFeeNormalized, nFee, "fee recomputed in units, with no scale and no index");
        assertEq(before.totalNormalized - afterFlush.totalNormalized, nFee, "and debited from the holders' pot");
    }

    /// Escrowed funds are put to work at submit, not at flush — otherwise a
    /// note minted at `n` would claim `n` at the flush-time index while the
    /// pool had only ever received `n` at the submit-time one.
    function test_escrowedFundsEarnBeforeFlush() public {
        _deposit(YIELD_ID, N, 0x101);
        assertGt(vault.balanceOf(address(venue)), 0, "escrow reached the venue at submit");

        uint256 idxBefore = masp.index(YIELD_ID);
        _earn(1_000 * SCALE);
        assertGt(masp.index(YIELD_ID), idxBefore, "and earned while still escrowed");
    }

    /// A drained venue blocks a *refund*, not just a withdrawal.
    ///
    /// `cancel` draws through `_ensureIdle` like every other exit, so R1 venue
    /// liveness reaches the escrow path too: past `cancelDelay`, a depositor
    /// still cannot be repaid while the vault is illiquid and the buffer is
    /// short. This is worse to be surprised by than the withdrawal case,
    /// because the depositor has no note yet — only a pending escrow.
    ///
    /// It stays a liveness failure and never a loss: the escrow is untouched by
    /// the reverted call, and `emergencyUnwind` takes the venue off the path.
    function test_cancel_blockedByDrainedVenue_thenFreedByUnwind() public {
        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id,) = _deposit(YIELD_ID, N, 0x101);
        vm.roll(block.number + 7_201);

        // The vault can service nothing; the 5% buffer cannot cover the refund.
        vault.setLiquidityCap(0);
        // Partial match: the selector is the assertion, the reported shortfall
        // and availability are incidental.
        vm.expectPartialRevert(YieldOps.VenueDrained.selector);
        this.attemptCancel(id, N, 0x101, submittedAt);
        assertTrue(masp.escrowed(id) != bytes32(0), "escrow survives the reverted cancel");

        // The vault recovers enough to be unwound, and the owner takes the
        // position back to idle.
        vault.setLiquidityCap(type(uint256).max);
        vm.prank(OWNER);
        masp.emergencyUnwind(YIELD_ID);

        // It then dies again — and the refund is served entirely from idle.
        vault.setLiquidityCap(0);
        uint256 before = token.balanceOf(payer);
        _cancel(id, N, 0x101, submittedAt);
        assertGt(token.balanceOf(payer) - before, 0, "refund served from idle after the unwind");
        assertEq(masp.escrowed(id), bytes32(0), "escrow cleared");
    }

    /// External so `vm.expectRevert` has a call boundary to catch.
    function attemptCancel(uint256 id, uint64 publicIn, uint256 seedValue, uint32 submittedAt) external {
        _cancel(id, publicIn, seedValue, submittedAt);
    }
}
