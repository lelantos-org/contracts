// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { ERC4626Venue } from "../../src/yield/ERC4626Venue.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { MockTreeUpdateVerifier } from "../mocks/MockTreeUpdateVerifier.sol";
import { EchidnaRoots } from "./EchidnaRoots.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { deployPoolUniform, singleAsset } from "../utils/PoolDeployer.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// Echidna target for the indexed-asset (yield) accounting.
///
/// Deliberately *not* a port of `test/yield/YieldSolvency.invariant.t.sol`.
/// That suite is thorough — seven invariants over thirteen handlers, covering
/// growth, loss, illiquidity, rebalance, unwind and the fee high-water mark —
/// and re-stating it here would buy almost nothing. What it cannot express is
/// magnitude, and that is what this file is for.
///
/// `invariant_paysOutNoMoreThanCameInPlusYield` asks whether the yield id ever
/// distributes value that was neither deposited nor earned. It is a yes/no
/// question, and the answer is no. The question it cannot ask is *how close*
/// the pool gets, which is the one that separates a rounding residue bounded
/// by a few wei from a leak that grows with volume — and yield is where that
/// distinction lives, since every conversion between units and assets is a
/// `mulDiv` with a rounding direction. `optimize_freeMoney` below maximises
/// exactly that slack, which no Foundry invariant can do.
///
/// The handler surface is therefore only as wide as it needs to be to move the
/// index: shield, settle, exit, grow, lose, and the maintenance calls that
/// re-price. Two asset ids share one ERC-20 on purpose — that sharing is what
/// puts the yield id's booked `idle` at risk of being spent against the plain
/// id's liability.
contract EchidnaMaspYield {
    uint64 internal constant PLAIN_ID = 1;
    uint64 internal constant YIELD_ID = 9;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant TREASURY = TestConstants.TREASURY;

    /// Distinct per id, so a payout can be attributed to the id that made it
    /// even though both ids settle in the same ERC-20.
    address internal constant YIELD_RECIPIENT = address(0xF00D);
    address internal constant PLAIN_RECIPIENT = address(0xBEEF);

    MASP public masp;
    MockERC20 public token;
    MockERC4626 public vault;
    ERC4626Venue public venue;
    address internal permit2;

    struct Escrow {
        uint256 id;
        uint64 assetId;
        uint64 publicIn;
        uint256 seed;
        uint32 submittedAt;
        bool settled;
    }

    Escrow[] internal escrows;
    uint256 internal seed = 0x1000;

    // --- conservation ghosts ---
    /// Base units the yield id has taken in, paid out, and its venue earned or
    /// lost. Measured from actual transfers rather than recomputed from the
    /// fee rates, so a pricing bug cannot cancel itself out of the ledger.
    uint256 public yieldPaidIn;
    uint256 public yieldPaidOut;
    uint256 public venueEarned;
    uint256 public venueLost;
    /// Base units the plain id holds and has not paid out.
    uint256 public plainHeld;

    // --- monotonicity ghosts ---
    bool internal sawLoss;
    uint256 internal lastIndex;
    bool internal hasBaseline;
    bool internal indexFellWithoutLoss;
    uint256 internal lastMark = 1e27;
    bool internal markFell;

    // --- coverage counters ---
    uint256 public shields;
    uint256 public flushes;
    uint256 public exits;
    uint256 public sweeps;
    uint256 public earns;
    uint256 public losses;

    constructor() {
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("M", "M", 18);

        // Both verifiers accept: the subject is the index arithmetic, not the
        // pairings. The consequence is the same as in EchidnaMasp — the fuzzer
        // supplies public inputs a circuit would have constrained — which is
        // why `withdrawYield` bounds its exit by the units actually
        // outstanding rather than by anything it chooses.
        IVerifier tub = IVerifier(address(new MockTreeUpdateVerifier(true)));
        MockBatchVerifier bv = new MockBatchVerifier();
        bv.setResult(true);

        // Only the plain id is registered up front. The yield id is created
        // by `addYieldAsset` below, and registering it here first would make
        // that call revert `DuplicateAsset`.
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), PLAIN_ID, SCALE);

        masp = deployPoolUniform(
            tub,
            IBatchVerifier(address(bv)),
            ISignatureTransfer(permit2),
            ids,
            tokens,
            scales,
            FEE_BPS,
            TREASURY,
            address(this)
        );

        vault = new MockERC4626(IERC20(address(token)));
        venue = new ERC4626Venue(address(masp), address(vault), address(token));
        // 500 bps buffer, perf fee at the same rate as the asset fee.
        masp.addYieldAsset(YIELD_ID, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(venue), 500, FEE_BPS);

        // This contract is the payer. `depositAuthorized` requires
        // `msg.sender == d.payer`, which suits Echidna exactly: no signature,
        // no ERC-1271 stub and no impersonation — the target simply funds and
        // authorises itself.
        token.mint(address(this), type(uint128).max);
        token.approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(address(token), address(masp), type(uint160).max, type(uint48).max);
    }

    // -----------------------------------------------------------------------
    // Shield
    // -----------------------------------------------------------------------

    function depositYield(uint64 amount) public {
        _deposit(amount, true);
    }

    /// The plain id shares the yield id's ERC-20. Its presence is the point:
    /// it gives the pool a second, differently-priced claim on one balance,
    /// which is what `echidna_poolCoversIdlePlusPlainLiability` protects.
    function depositPlain(uint64 amount) public {
        _deposit(amount, false);
    }

    function _deposit(uint64 amount, bool yieldSide) internal {
        uint64 n = uint64(1_000 + (amount % 999_001));
        uint64 id = yieldSide ? YIELD_ID : PLAIN_ID;

        uint256 s = ++seed;
        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = id;
        d.publicIn = n;
        d.payer = address(this);
        d.recipient = yieldSide ? YIELD_RECIPIENT : PLAIN_RECIPIENT;
        d.outCm = bytes32(s);
        d.feeCm = bytes32(s + 1);
        seed++;

        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        uint256 before = token.balanceOf(address(this));
        try masp.depositAuthorized(d, aux[0], aux[1]) returns (uint256 depositId) {
            uint256 pulled = before - token.balanceOf(address(this));
            if (yieldSide) yieldPaidIn += pulled;
            else plainHeld += pulled;
            escrows.push(
                Escrow({
                    id: depositId, assetId: id, publicIn: n, seed: s, submittedAt: uint32(block.number), settled: false
                })
            );
            shields++;
        } catch { }
        _observe();
    }

    // -----------------------------------------------------------------------
    // Settlement
    // -----------------------------------------------------------------------

    function flush(uint256 pick) public {
        if (escrows.length == 0) return;
        Escrow storage e = escrows[pick % escrows.length];
        if (e.settled) return;

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = EchidnaRoots.fresh(abi.encode("y", ++seed));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        tpi.cms[0] = bytes32(e.seed);
        tpi.cms[1] = bytes32(e.seed + 1);
        tpi.leafAsset[0] = e.assetId;
        // leafPublicIn[1] stays 0, so the fee leaf's asset must be 0 too:
        // `tree_update_batch.circom` step 7a canonicalises the asset of a leaf
        // whose Pedersen binding cannot see it.
        tpi.leafAsset[1] = 0;
        tpi.leafPublicIn[0] = e.publicIn;
        tpi.isDeposit[0] = 1;
        tpi.isDeposit[1] = 1;

        uint256[] memory ids = new uint256[](1);
        ids[0] = e.id;
        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: address(this), submittedAt: e.submittedAt, fbps: FEE_BPS });

        MASP.Proof memory proof;
        try masp.flushBatch(ids, meta, proof, tpi) {
            e.settled = true;
            flushes++;
        } catch { }
        _observe();
    }

    // -----------------------------------------------------------------------
    // Exit
    // -----------------------------------------------------------------------

    function withdrawYield(uint64 amount) public {
        _withdraw(amount, true);
    }

    function withdrawPlain(uint64 amount) public {
        _withdraw(amount, false);
    }

    function _withdraw(uint64 amount, bool yieldSide) internal {
        uint64 id = yieldSide ? YIELD_ID : PLAIN_ID;
        // Bounded by what is actually outstanding. With the spend verifier
        // stubbed nothing else would stop the fuzzer withdrawing value that
        // was never deposited, and the conservation ghosts would then be
        // reporting an artifact of the stub rather than a defect.
        uint256 cap = yieldSide ? masp.yieldState(id).totalNormalized : plainHeld / SCALE;
        if (cap == 0) return;
        uint64 n = uint64(1 + (amount % cap));
        address to = yieldSide ? YIELD_RECIPIENT : PLAIN_RECIPIENT;

        PubInputs.Transact memory pi;
        pi.chainId = block.chainid;
        pi.publicAssetId = id;
        pi.publicOut = n;
        pi.recipient = to;
        pi.payer = PLAIN_RECIPIENT;
        pi.relayer = address(this); // _validateRequest pins relayer == msg.sender
        // Spaced by more than either array width. `fillOutputs` writes
        // TRANSACT_IN consecutive nullifiers from the seed, so advancing by
        // one per call would overlap the last nullifier of one spend with the
        // first of the next and every second exit would revert `DoubleSpend`
        // into the catch — leaving the properties true over a history that
        // barely withdrew.
        seed += 0x100;
        SpendFixture.fillOutputs(pi, seed, seed + 0x5000);
        pi.merkleRoot = masp.currentRoot();
        PubInputs.TreeUpdateBatch memory tpi = SpendFixture.batchFor(
            pi, masp.currentRoot(), EchidnaRoots.fresh(abi.encode("yx", seed)), masp.committedCount()
        );

        uint256 before = token.balanceOf(to);
        MASP.Proof memory p;
        MASP.Proof memory tp;
        try masp.withdraw(p, pi, tp, tpi, SpendFixture.validAux()) {
            exits++;
            uint256 paid = token.balanceOf(to) - before;
            if (yieldSide) yieldPaidOut += paid;
            else plainHeld -= paid;
        } catch { }
        _observe();
    }

    // -----------------------------------------------------------------------
    // Venue
    // -----------------------------------------------------------------------

    /// Genuine venue growth. Counted into `venueEarned`, which is the only
    /// thing that licenses the pool to pay out more than came in.
    function earn(uint96 amount) public {
        uint256 amt = 1 + (uint256(amount) % 1e22);
        token.mint(address(this), amt);
        token.approve(address(vault), amt);
        vault.earn(amt);
        venueEarned += amt;
        earns++;
        _observe();
    }

    function lose(uint96 amount) public {
        uint256 held = vault.totalAssetsHeld();
        if (held == 0) return;
        uint256 amt = 1 + (uint256(amount) % held);
        sawLoss = true;
        vault.lose(amt);
        venueLost += amt;
        losses++;
        _observe();
    }

    /// A venue that reports a position it cannot presently pay out, which is
    /// what forces the idle buffer to do its job.
    function squeeze(uint96 cap) public {
        vault.setLiquidityCap(uint256(cap));
        _observe();
    }

    // -----------------------------------------------------------------------
    // Maintenance
    // -----------------------------------------------------------------------

    function rebalance() public {
        try masp.rebalance(YIELD_ID) { } catch { }
        _observe();
    }

    function accruePerf() public {
        try masp.accruePerf(YIELD_ID) { } catch { }
        _observe();
    }

    function sweepYield() public {
        try masp.sweepNormalized(YIELD_ID) returns (uint256 paid) {
            // Swept fees leave the pool for the treasury, so they are a payout
            // of the yield id like any other and must be accounted as one.
            yieldPaidOut += paid;
            sweeps++;
        } catch { }
        _observe();
    }

    function setParams(uint16 buffer, uint16 perf) public {
        try masp.setYieldParams(YIELD_ID, buffer % 10_001, perf % (FEE_BPS + 1)) { } catch { }
        _observe();
    }

    // -----------------------------------------------------------------------
    // Observation
    // -----------------------------------------------------------------------

    /// Sampled after every call, because both facts below are about a
    /// transition rather than a state and are unobservable from the end value.
    function _observe() internal {
        YieldIndex.YieldState memory st = masp.yieldState(YIELD_ID);

        // An empty asset reports RAY by convention, not by measurement: with
        // no units outstanding there is no rate to speak of. Comparing across
        // that boundary is meaningless — the last holder exiting a pool that
        // had grown reads as a fall from its final index back to RAY — so
        // monotonicity is only judged between two non-empty observations.
        if (st.totalNormalized + st.accruedFeeNormalized == 0) {
            hasBaseline = false;
        } else {
            if (hasBaseline && st.index < lastIndex && !sawLoss) indexFellWithoutLoss = true;
            lastIndex = st.index;
            hasBaseline = true;
        }

        if (st.lastIdx < lastMark) markFell = true;
        lastMark = st.lastIdx;
    }

    function _state() internal view returns (YieldIndex.YieldState memory) {
        return masp.yieldState(YIELD_ID);
    }

    /// Everything backing the yield id: the venue position at its current
    /// value, plus the idle buffer the pool holds directly.
    function _gross() internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(venue))) + _state().idle;
    }

    // -----------------------------------------------------------------------
    // Properties
    // -----------------------------------------------------------------------

    /// No free money: over any history, what the yield id paid out cannot
    /// exceed what went into it plus what its venue genuinely earned.
    ///
    /// The strongest of the set. A rounding leak, a double-credited fee, or a
    /// refund priced off a stale index all surface here as the pool
    /// distributing value that was never deposited or earned.
    function echidna_noFreeMoney() public view returns (bool) {
        return yieldPaidOut <= yieldPaidIn + venueEarned;
    }

    /// The pool actually holds the idle balance it has booked, on top of what
    /// the plain id is owed out of the same ERC-20. This is the property that
    /// two ids over one token puts at risk.
    function echidna_poolCoversIdlePlusPlainLiability() public view returns (bool) {
        return token.balanceOf(address(masp)) >= _state().idle + plainHeld;
    }

    /// Booked idle is a component of the backing and can never exceed it.
    function echidna_idleNeverExceedsGross() public view returns (bool) {
        return _state().idle <= _gross();
    }

    /// Units outstanding are never unbacked.
    function echidna_everyUnitIsBacked() public view returns (bool) {
        YieldIndex.YieldState memory st = _state();
        if (st.totalNormalized + st.accruedFeeNormalized == 0) return true;
        return _gross() > 0;
    }

    /// `lastIdx` is a high-water mark that only `_accruePerf` raises. A fall
    /// would mean the mark was reset and the treasury could bill twice for the
    /// same growth.
    function echidna_highWaterMarkNeverFalls() public view returns (bool) {
        return !markFell;
    }

    /// The venue binding is permanent, and the asset stays indexed.
    function echidna_venueBindingImmutable() public view returns (bool) {
        return _state().venue == address(venue) && masp.isYieldAsset(YIELD_ID);
    }

    // -----------------------------------------------------------------------
    // Optimization targets
    //
    // The reason this file exists. Everything above answers yes or no; these
    // answer "by how much", which is the question that distinguishes a bounded
    // rounding residue from a leak that scales with volume. Both should report
    // 0, and a small positive maximum is a finding to read rather than a test
    // failure to fix.
    // -----------------------------------------------------------------------

    /// Largest amount by which the yield id has ever overpaid relative to what
    /// was deposited and earned.
    ///
    /// This is `echidna_noFreeMoney` restated as a magnitude. Every conversion
    /// between normalized units and assets is a `mulDiv` with a rounding
    /// direction, so the interesting question is not whether the slack is ever
    /// non-zero but whether it stays bounded as volume grows.
    function optimize_freeMoney() public view returns (int256) {
        return int256(yieldPaidOut) - int256(yieldPaidIn + venueEarned);
    }

    /// Largest amount by which booked idle has exceeded the actual backing.
    ///
    /// Positive means the pool believes it holds a buffer that is not there —
    /// drift between what funds the venue and what tops the buffer back up.
    function optimize_idleOverGross() public view returns (int256) {
        return int256(_state().idle) - int256(_gross());
    }
}
