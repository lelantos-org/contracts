// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { MASP } from "../../src/MASP.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";
import { YieldOps } from "../../src/yield/YieldOps.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";

import { YieldTestBase } from "../utils/YieldTestBase.sol";

/// The escrow half of the index: what flush and cancel do to the books.
contract YieldEscrowTest is YieldTestBase {
    uint64 internal constant N = 1_000_000;

    /// Settles escrow `id` of `YIELD_ID` into a note, as a relayer's flush would.
    function _flush(uint256 id, uint64 publicIn, uint256 seed, uint32 submittedAt) internal {
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xfeed0000) + seed);
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        tpi.cms[0] = bytes32(seed);
        tpi.cms[1] = bytes32(seed + 1);
        tpi.leafAsset[0] = YIELD_ID;
        tpi.leafPublicIn[0] = publicIn;
        tpi.isDeposit[0] = 1;
        tpi.isDeposit[1] = 1;

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: payer, submittedAt: submittedAt, fbps: FEE_BPS, pulled: pulledOf[id] });

        masp.flushBatch(ids, meta, FixtureLoader.emptyProof(), tpi);
    }

    /// Value of `units` of `YIELD_ID` at the current index.
    function _valueOf(uint256 units) internal view returns (uint256) {
        return (units * _gross(YIELD_ID)) / _supply(YIELD_ID);
    }

    /// A cancellation refunds at most what was pulled at submit. The escrow's
    /// units still share the index while it waits, but every one is burned on
    /// cancel, so the growth they carried stays with the remaining holders.
    ///
    /// Without the cap a deposit that is never flushed would be a fee-free
    /// position in the venue: it refunds its deposit fee and never pays
    /// `withdrawBps`.
    function test_cancel_refundCappedAtSubmitPull_escrowYieldStaysWithHolders() public {
        // A settled holder, so the escrow's forgone growth has somewhere to go.
        uint32 holderAt = uint32(vm.getBlockNumber());
        (uint256 holderId,) = _deposit(YIELD_ID, N, 0x201);
        _flush(holderId, N, 0x201, holderAt);
        uint256 holderUnits = masp.yieldState(YIELD_ID).totalNormalized;
        uint256 feeAfterFlush = masp.yieldState(YIELD_ID).accruedFeeNormalized;

        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id, uint256 pulled) = _deposit(YIELD_ID, N, 0x101);

        _earn(1_000 * SCALE);
        vm.roll(block.number + 7_201); // past the default cancelDelay

        uint256 holderValueBefore = _valueOf(holderUnits);
        uint256 before = token.balanceOf(payer);
        _cancel(id, N, 0x101, submittedAt);
        uint256 refunded = token.balanceOf(payer) - before;

        assertEq(refunded, pulled, "refund is exactly the submit-time pull, no escrow-window yield");

        // Every escrow unit is burned; the value above the cap accrues to the
        // holder even net of the performance fee the cancel settled.
        YieldIndex.YieldState memory st = masp.yieldState(YIELD_ID);
        assertEq(st.totalNormalized, holderUnits, "escrow units burned in full");
        assertGt(_valueOf(holderUnits), holderValueBefore, "the escrow's forgone growth went to the holder");
        assertGt(st.accruedFeeNormalized, feeAfterFlush, "treasury keeps its cut of the escrow-window growth");
    }

    /// A loss is shared: below the cap the refund is the escrow's floored value
    /// at the current index, not the pull.
    function test_cancel_refundIsTheFloorAfterALoss() public {
        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id, uint256 pulled) = _deposit(YIELD_ID, N, 0x101);

        vault.lose(vault.totalAssetsHeld() / 10);
        vm.roll(block.number + 7_201);

        uint256 nTotal = uint256(N) + Math.ceilDiv(uint256(N) * FEE_BPS, 10_000);
        uint256 expected = Math.mulDiv(nTotal, _gross(YIELD_ID), _supply(YIELD_ID));

        uint256 before = token.balanceOf(payer);
        _cancel(id, N, 0x101, submittedAt);
        uint256 refunded = token.balanceOf(payer) - before;

        assertEq(refunded, expected, "refund is the floored value at the post-loss index");
        assertLt(refunded, pulled, "and carries its share of the loss");
    }

    /// The cap is the amount pulled at submit, published in `DepositEscrowed`
    /// and nowhere else: a yield escrow reports its pull, a plain one zero.
    /// `pulledOf` holds what each deposit's log carried.
    function test_cap_isThePullAndIsPublishedInTheEvent() public {
        (uint256 yieldId, uint256 yieldPull) = _deposit(YIELD_ID, N, 0x101);
        (uint256 plainId,) = _deposit(PLAIN_ID, N, 0x501);

        assertGt(yieldPull, 0, "a yield escrow always pulls");
        assertEq(pulledOf[yieldId], yieldPull, "the event carries the pull");
        assertEq(pulledOf[plainId], 0, "a plain escrow carries no cap");
    }

    /// The digest binds the cap, so neither exit accepts another value: a
    /// canceller cannot raise its own refund ceiling, lower someone else's, or
    /// drop the cap altogether.
    function test_revert_cap_isBoundByTheDigest() public {
        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id, uint256 pulled) = _deposit(YIELD_ID, N, 0x101);
        _earn(1_000 * SCALE);
        vm.roll(block.number + 7_201);

        uint256[3] memory wrong = [pulled + 1, pulled - 1, uint256(0)];
        for (uint256 k; k < wrong.length; ++k) {
            // What the caller hands back in place of the submitted cap.
            pulledOf[id] = wrong[k];

            vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
            this.attemptCancel(id, N, 0x101, submittedAt);

            vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
            this.attemptFlush(id, N, 0x101, submittedAt);
        }
        assertTrue(masp.escrowed(id) != bytes32(0), "escrow survives every rejected exit");

        pulledOf[id] = pulled;
        uint256 before = token.balanceOf(payer);
        _cancel(id, N, 0x101, submittedAt);
        assertEq(token.balanceOf(payer) - before, pulled, "the submitted cap settles it");
    }

    /// Round trip of a deposit made deliberately unflushable: escrowed, left in
    /// the venue through a large gain, then canceled. It gets back exactly what
    /// it paid, so parking funds in escrow is never a free venue position.
    function test_cancel_unflushableEscrowEarnsNothing() public {
        uint32 holderAt = uint32(vm.getBlockNumber());
        (uint256 holderId,) = _deposit(YIELD_ID, N, 0x201);
        _flush(holderId, N, 0x201, holderAt);

        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id, uint256 pulled) = _deposit(YIELD_ID, N * 10, 0x101);

        // The venue doubles.
        _earn(_gross(YIELD_ID));
        vm.roll(block.number + 7_201);

        uint256 before = token.balanceOf(payer);
        _cancel(id, N * 10, 0x101, submittedAt);
        assertEq(token.balanceOf(payer) - before, pulled, "an unflushed escrow earned nothing");
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

        _flush(id, N, 0x101, submittedAt);

        YieldIndex.YieldState memory afterFlush = masp.yieldState(YIELD_ID);
        uint256 nFee = (uint256(N) * FEE_BPS) / 10_000;
        assertEq(_supply(YIELD_ID), supplyBefore, "flush creates and destroys no units");
        assertEq(afterFlush.accruedFeeNormalized, nFee, "fee recomputed in units, with no scale and no index");
        assertEq(before.totalNormalized - afterFlush.totalNormalized, nFee, "and debited from the holders' pot");
    }

    /// Escrowed funds are supplied to the venue at submit, not at flush;
    /// otherwise a note minted at `n` would claim `n` at the flush-time index
    /// while the pool received `n` at the submit-time index.
    function test_escrowedFundsEarnBeforeFlush() public {
        _deposit(YIELD_ID, N, 0x101);
        assertGt(vault.balanceOf(address(venue)), 0, "escrow reached the venue at submit");

        uint256 idxBefore = masp.index(YIELD_ID);
        _earn(1_000 * SCALE);
        assertGt(masp.index(YIELD_ID), idxBefore, "and earned while still escrowed");
    }

    /// A drained venue blocks a refund, not only a withdrawal.
    ///
    /// `cancel` draws through `_ensureIdle` like every other exit, so the venue
    /// liveness dependency extends to the escrow path: past `cancelDelay`, a
    /// depositor cannot be repaid while the vault is illiquid and the buffer is
    /// short, and at that point holds only a pending escrow, not a note.
    ///
    /// This is a liveness failure, not a loss: the reverted call leaves the
    /// escrow intact, and `emergencyUnwind` removes the venue from the path.
    function test_cancel_blockedByDrainedVenue_thenFreedByUnwind() public {
        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id,) = _deposit(YIELD_ID, N, 0x101);
        vm.roll(block.number + 7_201);

        // The vault can service nothing; the 5% buffer cannot cover the refund.
        vault.setLiquidityCap(0);
        // Partial match: only the selector is asserted, not the reported
        // shortfall and availability.
        vm.expectPartialRevert(YieldOps.VenueDrained.selector);
        this.attemptCancel(id, N, 0x101, submittedAt);
        assertTrue(masp.escrowed(id) != bytes32(0), "escrow survives the reverted cancel");

        // The vault recovers enough to be unwound, and the owner takes the
        // position back to idle.
        vault.setLiquidityCap(type(uint256).max);
        vm.prank(OWNER);
        masp.emergencyUnwind(YIELD_ID);

        // The vault becomes illiquid again; the refund is served entirely from
        // idle.
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

    /// External so `vm.expectRevert` has a call boundary to catch.
    function attemptFlush(uint256 id, uint64 publicIn, uint256 seedValue, uint32 submittedAt) external {
        _flush(id, publicIn, seedValue, submittedAt);
    }
}
