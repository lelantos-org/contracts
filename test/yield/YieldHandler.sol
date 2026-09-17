// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";
import { ERC4626Venue } from "../../src/yield/ERC4626Venue.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// Drives random sequences over one plain id and one yield id sharing a single
/// ERC-20, across the whole surface: shield, escrow flush and cancel, unshield,
/// venue growth and loss, rebalance, sweep, unwind and resume, and parameter
/// changes with their delayed commit.
///
/// Every call is wrapped in `try`, so an invalid sequence (cancelling before
/// the delay, withdrawing more than exists) advances the run instead of
/// aborting it.
///
/// Payouts are attributed by measuring balance deltas around each call, with a
/// distinct recipient per asset id, so the conservation invariant can separate
/// the two ids' claims on one shared token balance.
contract YieldHandler is Test {
    uint64 internal constant PLAIN_ID = 1;
    uint64 internal constant YIELD_ID = 9;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;

    address internal constant YIELD_RECIPIENT = address(0xF00D);
    address internal constant PLAIN_RECIPIENT = address(0xBEEF);
    address internal constant TREASURY = TestConstants.TREASURY;

    MASP public masp;
    MockERC20 public token;
    MockERC4626 public vault;
    ERC4626Venue public venue;
    address public permit2;
    address public payer;
    address public owner;

    /// A pending escrow, kept so `flush` and `cancel` can resupply the digest
    /// preimage the pool demands.
    struct Escrow {
        uint256 id;
        uint64 assetId;
        uint64 publicIn;
        uint256 seed;
        uint32 submittedAt;
        bool settled;
        /// Underlying pulled at submit; a cancel refunds no more.
        uint256 pulled;
    }

    Escrow[] public escrows;

    /// Base units the plain id has taken in and not yet paid out.
    ///
    /// Measured from actual transfers rather than recomputed from the fee
    /// rates: at flush the fee stops backing notes and becomes `accruedFee`, so
    /// a `units + fee` model would double count. The treasury's claim is
    /// included in this figure because it stays in the pool until swept.
    uint256 public plainHeld;
    uint256 public seed = 0x1000;

    /// Ceiling the owner may set for `perfBps`. The monotonicity suite pins it
    /// to zero, since that property only holds with the dilution channel shut.
    uint16 public maxPerfBps;

    // --- conservation ghosts -------------------------------------------------
    /// Tokens the yield id has taken in, paid out, and earned net of losses.
    uint256 public yieldPaidIn;
    uint256 public yieldPaidOut;
    uint256 public venueEarned;
    uint256 public venueLost;

    // --- coverage counters ---------------------------------------------------
    /// Every handler call is wrapped in `try`, so a path can fail on every
    /// attempt without signal and the invariants then pass over histories that
    /// never reach it. `YieldHandlerCoverageTest` drives each path directly and
    /// asserts its counter moves.
    uint256 public shields;
    uint256 public flushes;
    uint256 public cancels;
    uint256 public exits;
    uint256 public sweeps;
    uint256 public unwinds;
    /// Times the fee went from off to on. The high-water-mark re-mark applies
    /// on this transition, so the runs must be shown to reach it. Only a
    /// commit can enable the fee: going from zero is always a raise.
    uint256 public feeEnabled;
    /// Queued raises committed.
    uint256 public commits;

    // --- monotonicity ghosts -------------------------------------------------
    bool public sawLoss;
    uint256 public lastIndex;
    /// False until a non-empty observation exists to compare against.
    bool public hasBaseline;
    bool public indexFellWithoutLoss;
    uint256 public lastMark = 1e27;
    bool public markFell;

    // --- escrow ghosts -------------------------------------------------------
    /// Set when a cancel refunds more than its escrow pulled at submit. The
    /// escrow shares the index while it waits but is capped at its pull, so
    /// parking funds in an escrow that is never flushed cannot earn.
    bool public refundExceededPull;

    constructor(
        MASP m,
        MockERC20 t,
        MockERC4626 v,
        ERC4626Venue ven,
        address p2,
        address payer_,
        address owner_,
        uint16 maxPerfBps_
    ) {
        maxPerfBps = maxPerfBps_;
        masp = m;
        token = t;
        vault = v;
        venue = ven;
        permit2 = p2;
        payer = payer_;
        owner = owner_;
    }

    function escrowCount() external view returns (uint256) {
        return escrows.length;
    }

    function _observe() internal {
        YieldIndex.YieldState memory st = masp.yieldState(YIELD_ID);

        // An empty asset reports `RAY` by convention: with no units outstanding
        // there is no rate. Comparing across that boundary is not meaningful
        // (the last holder exiting a grown pool reads as a fall from its final
        // index back to `RAY`), so monotonicity is asserted only between two
        // non-empty observations.
        if (st.totalNormalized + st.accruedFeeNormalized == 0) {
            hasBaseline = false;
        } else {
            if (hasBaseline && st.index < lastIndex && !sawLoss) indexFellWithoutLoss = true;
            lastIndex = st.index;
            hasBaseline = true;
        }

        // The high-water mark is only ever raised by `_accruePerf`.
        if (st.lastIdx < lastMark) markFell = true;
        lastMark = st.lastIdx;
    }

    function _fund() internal {
        token.mint(payer, type(uint96).max);
        vm.prank(payer);
        IAllowanceTransfer(permit2).approve(address(token), address(masp), type(uint160).max, type(uint48).max);
    }

    // ============== Shield ===================================================

    function deposit(uint64 amount, bool yieldSide) external {
        uint64 n = uint64(bound(amount, 1_000, 1_000_000));
        uint64 id = yieldSide ? YIELD_ID : PLAIN_ID;
        _fund();

        uint256 s = ++seed;
        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = id;
        d.publicIn = n;
        d.payer = payer;
        d.recipient = YIELD_RECIPIENT;
        d.outCm = bytes32(s);
        d.feeCm = bytes32(s + 1);
        seed++;

        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        uint256 before = token.balanceOf(payer);
        vm.prank(payer);
        try masp.depositAuthorized(d, aux[0], aux[1]) returns (uint256 depositId) {
            shields++;
            uint256 pulled = before - token.balanceOf(payer);
            if (yieldSide) yieldPaidIn += pulled;
            else plainHeld += pulled;
            escrows.push(
                Escrow({
                    id: depositId,
                    assetId: id,
                    publicIn: n,
                    seed: s,
                    submittedAt: uint32(vm.getBlockNumber()),
                    settled: false,
                    pulled: pulled
                })
            );
        } catch { }
        _observe();
    }

    // ============== Escrow settlement ========================================

    function flush(uint256 pick) external {
        if (escrows.length == 0) return;
        Escrow storage e = escrows[bound(pick, 0, escrows.length - 1)];
        if (e.settled) return;

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(++seed + 0x900_0000);
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        tpi.cms[0] = bytes32(e.seed);
        tpi.cms[1] = bytes32(e.seed + 1);
        tpi.leafAsset[0] = e.assetId;
        // leafPublicIn[1] stays 0, so the fee leaf's asset must be 0 too:
        // `tree_update_batch.circom` step 6a canonicalises the asset of a leaf
        // whose Pedersen binding cannot see it.
        tpi.leafAsset[1] = 0;
        tpi.leafPublicIn[0] = e.publicIn;
        tpi.isDeposit[0] = 1;
        tpi.isDeposit[1] = 1;

        uint256[] memory ids = new uint256[](1);
        ids[0] = e.id;
        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: payer, submittedAt: e.submittedAt, fbps: FEE_BPS });

        try masp.flushBatch(ids, meta, FixtureLoader.emptyProof(), tpi) {
            e.settled = true;
            flushes++;
        } catch { }
        _observe();
    }

    function cancel(uint256 pick) external {
        if (escrows.length == 0) return;
        Escrow storage e = escrows[bound(pick, 0, escrows.length - 1)];
        if (e.settled) return;
        vm.roll(block.number + 7_201);

        uint256 before = token.balanceOf(payer);
        try masp.cancelDeposit(
            e.id,
            uint48(e.publicIn),
            bytes32(e.seed),
            [uint256(0), 0],
            e.assetId,
            FEE_BPS,
            payer,
            e.submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(e.seed + 1), feeCvDep: [uint256(0), 0] })
        ) {
            e.settled = true;
            cancels++;
            uint256 refunded = token.balanceOf(payer) - before;
            if (refunded > e.pulled) refundExceededPull = true;
            if (e.assetId == YIELD_ID) yieldPaidOut += refunded;
            else plainHeld -= refunded;
        } catch { }
        _observe();
    }

    // ============== Unshield =================================================

    function withdraw(uint64 amount, bool yieldSide) external {
        uint64 id = yieldSide ? YIELD_ID : PLAIN_ID;
        // The plain id keeps no unit counter on chain, so the handler bounds
        // its exits by what it has actually paid in.
        uint256 cap = yieldSide ? masp.yieldState(id).totalNormalized : plainHeld / SCALE;
        if (cap == 0) return;
        uint64 n = uint64(bound(amount, 1, cap));
        address to = yieldSide ? YIELD_RECIPIENT : PLAIN_RECIPIENT;

        PubInputs.Transact memory pi;
        pi.chainId = block.chainid;
        pi.publicAssetId = id;
        pi.publicOut = n;
        pi.recipient = to;
        pi.payer = address(0xBEEF);
        pi.relayer = address(this);
        // `fillOutputs` writes `TRANSACT_IN` consecutive nullifiers and
        // `TRANSACT_OUT` consecutive commitments from their seeds, so two exits
        // must be spaced by more than either width. Overlapping nullifiers
        // would revert `DoubleSpend` into the `catch` below, and the invariants
        // would pass over histories with few successful withdrawals.
        seed += 0x100;
        SpendFixture.fillOutputs(pi, seed, seed + 0x5000);
        pi.merkleRoot = masp.currentRoot();
        PubInputs.SpendTree memory tpi =
            SpendFixture.spendTree(bytes32(seed + 0x90000), masp.committedCount(), uint8(masp.rootIndex()));

        uint256 before = token.balanceOf(to);
        try masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux()) {
            exits++;
            if (yieldSide) yieldPaidOut += token.balanceOf(to) - before;
            else plainHeld -= token.balanceOf(to) - before;
        } catch { }
        _observe();
    }

    // ============== Venue ====================================================

    function earn(uint96 amount) external {
        uint256 amt = bound(amount, 1, 1e22);
        token.mint(address(this), amt);
        token.approve(address(vault), amt);
        vault.earn(amt);
        venueEarned += amt;
        _observe();
    }

    function lose(uint96 amount) external {
        uint256 held = vault.totalAssetsHeld();
        if (held == 0) return;
        uint256 amt = bound(amount, 1, held);
        sawLoss = true;
        vault.lose(amt);
        venueLost += amt;
        _observe();
    }

    /// A vault that reports a position it cannot currently pay out.
    function squeeze(uint96 cap) external {
        vault.setLiquidityCap(bound(cap, 0, type(uint96).max));
        _observe();
    }

    // ============== Maintenance and administration ===========================

    function rebalance() external {
        try masp.rebalance(YIELD_ID) { } catch { }
        _observe();
    }

    function accruePerf() external {
        try masp.accruePerf(YIELD_ID) { } catch { }
        _observe();
    }

    function sweep() external {
        uint256 before = token.balanceOf(TREASURY);
        try masp.sweepNormalized(YIELD_ID) returns (uint256 paid) {
            if (paid != 0) sweeps++;
            yieldPaidOut += token.balanceOf(TREASURY) - before;
        } catch { }
        _observe();
    }

    function unwind() external {
        vm.prank(owner);
        try masp.emergencyUnwind(YIELD_ID) returns (uint256) {
            unwinds++;
        } catch { }
        _observe();
    }

    function resume() external {
        vm.prank(owner);
        try masp.setHalted(YIELD_ID, false) { } catch { }
        _observe();
    }

    /// A lower or equal rate lands here; a higher one is only queued, and
    /// reaches the pool through `commitParams`.
    function setParams(uint16 buffer, uint16 perf) external {
        uint16 newPerf = uint16(bound(perf, 0, maxPerfBps));
        uint16 oldPerf = masp.yieldState(YIELD_ID).perfBps;
        vm.prank(owner);
        try masp.setYieldParams(YIELD_ID, uint16(bound(buffer, 0, 10_000)), newPerf) { } catch { }
        _countFeeEnabled(oldPerf);
        _observe();
    }

    /// Waits out the raise notice and commits whatever is queued, so raised
    /// rates, and the re-mark on the off-to-on transition, stay reachable.
    /// Nothing else in the handler reads the clock.
    function commitParams() external {
        uint16 oldPerf = masp.yieldState(YIELD_ID).perfBps;
        vm.warp(vm.getBlockTimestamp() + ExitTerms.DELAY);
        try masp.commitExitTerms(YIELD_ID) {
            commits++;
        } catch { }
        _countFeeEnabled(oldPerf);
        _observe();
    }

    function _countFeeEnabled(uint16 oldPerf) internal {
        if (oldPerf == 0 && masp.yieldState(YIELD_ID).perfBps != 0) feeEnabled++;
    }
}
