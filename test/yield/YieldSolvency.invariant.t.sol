// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { ERC4626Venue } from "../../src/yield/ERC4626Venue.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { uniformBps } from "../utils/FeeArrays.sol";

/// Drives random sequences over one plain id and one yield id sharing a single
/// ERC-20, across the whole surface: shield, escrow flush and cancel, unshield,
/// venue growth and loss, rebalance, sweep, unwind and resume.
///
/// Every call is wrapped in `try`, so a sequence that happens to be invalid —
/// cancelling before the delay, withdrawing more than exists — advances the run
/// instead of aborting it.
///
/// Payouts are attributed by measuring balance deltas around each call, with a
/// distinct recipient per asset id. That is what lets the conservation
/// invariant separate the two ids' claims on one shared token balance.
contract YieldHandler is Test {
    uint64 internal constant PLAIN_ID = 1;
    uint64 internal constant YIELD_ID = 9;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;

    address internal constant YIELD_RECIPIENT = address(0xF00D);
    address internal constant PLAIN_RECIPIENT = address(0xBEEF);
    address internal constant TREASURY = address(0xfee);

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
    }

    Escrow[] public escrows;

    /// Base units the plain id has taken in and not yet paid out.
    ///
    /// Measured from actual transfers rather than recomputed from the fee
    /// rates. An earlier version modelled it as `units + fee` and double
    /// counted at flush, where the fee stops backing notes and becomes
    /// `accruedFee` — the treasury's claim sits inside this figure either way,
    /// because it does not leave the pool until it is swept.
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
    /// Every handler call is wrapped in `try`, which makes it easy for a whole
    /// path to silently never execute and for the invariants to pass over a
    /// history that never reached it. `YieldHandlerCoverageTest` drives each of
    /// these directly and asserts it moves.
    uint256 public shields;
    uint256 public flushes;
    uint256 public cancels;
    uint256 public exits;
    uint256 public sweeps;
    uint256 public unwinds;
    /// Times the fee went from off to on. The stale-high-water-mark bug lived
    /// exactly on this transition, so the runs must be shown to reach it.
    uint256 public feeEnabled;

    // --- monotonicity ghosts -------------------------------------------------
    bool public sawLoss;
    uint256 public lastIndex;
    /// False until a non-empty observation exists to compare against.
    bool public hasBaseline;
    bool public indexFellWithoutLoss;
    uint256 public lastMark = 1e27;
    bool public markFell;

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

        // An empty asset reports `RAY` by convention, not by measurement: with
        // no units outstanding there is no rate to speak of. Comparing across
        // that boundary is meaningless — the last holder exiting a pool that
        // had grown reads as a fall from its final index back to `RAY` — so
        // monotonicity is only asserted between two non-empty observations.
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
                    settled: false
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
        tpi.leafAsset[1] = e.assetId;
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
            PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(e.seed + 1), feeCvDep: [uint256(0), 0] })
        ) {
            e.settled = true;
            cancels++;
            uint256 refunded = token.balanceOf(payer) - before;
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
        // `TRANSACT_OUT` consecutive commitments from their seeds, so two
        // exits must be spaced by more than either width. Advancing by one per
        // call overlapped the last nullifier of one spend with the first of the
        // next, and every second exit reverted `DoubleSpend` into the `catch`
        // below — leaving the invariants to pass over histories that barely
        // withdrew at all.
        seed += 0x100;
        SpendFixture.fillOutputs(pi, seed, seed + 0x5000);
        pi.merkleRoot = masp.currentRoot();
        PubInputs.TreeUpdateBatch memory tpi =
            SpendFixture.batchFor(pi, masp.currentRoot(), bytes32(seed + 0x90000), masp.committedCount());

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

    function setParams(uint16 buffer, uint16 perf) external {
        uint16 newPerf = uint16(bound(perf, 0, maxPerfBps));
        uint16 oldPerf = masp.yieldState(YIELD_ID).perfBps;
        vm.prank(owner);
        try masp.setYieldParams(YIELD_ID, uint16(bound(buffer, 0, 10_000)), newPerf) {
            if (oldPerf == 0 && newPerf != 0) feeEnabled++;
        } catch { }
        _observe();
    }
}

/// Deployment and helpers shared by the suites below.
///
/// Separated from the properties so the coverage test can reuse the fixture
/// without re-running every invariant a third time.
abstract contract YieldInvariantBase is Test {
    uint64 internal constant PLAIN_ID = 1;
    uint64 internal constant YIELD_ID = 9;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant TREASURY = address(0xfee);

    MASP internal masp;
    MockERC20 internal token;
    MockERC4626 internal vault;
    ERC4626Venue internal venue;
    YieldHandler internal handler;

    /// Overridden by the monotonicity suite below.
    function _perfBps() internal view virtual returns (uint16) {
        return 1000;
    }

    function setUp() public {
        token = new MockERC20("M", "M", 18);
        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        MockBatchVerifier bv = new MockBatchVerifier();
        address permit2 = new DeployPermit2().deployPermit2();

        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = PLAIN_ID;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;

        masp = new MASP(
            tub,
            bv,
            ISignatureTransfer(permit2),
            ids,
            tokens,
            scales,
            uniformBps(1, FEE_BPS),
            uniformBps(1, FEE_BPS),
            TREASURY,
            address(this)
        );

        vault = new MockERC4626(IERC20(address(token)));
        venue = new ERC4626Venue(address(masp), address(vault), address(token));
        masp.addYieldAsset(YIELD_ID, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(venue), 500, _perfBps());

        bv.setResult(true);
        vm.mockCall(address(tub), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));

        address payer = address(0xa11ce);
        vm.prank(payer);
        token.approve(permit2, type(uint256).max);

        handler = new YieldHandler(masp, token, vault, venue, permit2, payer, address(this), _perfBps());
        targetContract(address(handler));
    }

    function _state() internal view returns (YieldIndex.YieldState memory) {
        return masp.yieldState(YIELD_ID);
    }

    function _gross() internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(venue))) + _state().idle;
    }
}

/// The properties the index must never break, over arbitrary histories.
contract YieldSolvencyInvariantTest is YieldInvariantBase {
    /// The pool must actually hold the idle balance it has booked, on top of
    /// everything the plain id and the treasury are owed out of the same ERC-20.
    /// This is the property that two asset ids over one token puts at risk, and
    /// the reason `idle` is tracked rather than read from `balanceOf`.
    function invariant_poolCoversIdlePlusPlainLiability() public view {
        assertGe(
            token.balanceOf(address(masp)),
            _state().idle + handler.plainHeld(),
            "pool holds less than both ids are owed"
        );
    }

    /// Every outstanding unit is backed. `supply` includes the treasury's
    /// unswept fee, so this covers that claim too.
    function invariant_everyUnitIsBacked() public view {
        YieldIndex.YieldState memory st = _state();
        if (st.totalNormalized + st.accruedFeeNormalized != 0) {
            assertGt(_gross(), 0, "units outstanding with no backing behind them");
        }
    }

    /// No free money. Over any history, what the yield id has paid out cannot
    /// exceed what went into it plus what its venue genuinely earned.
    ///
    /// This is the strongest of the set: a rounding leak, a double-credited
    /// fee, or a refund priced off a stale index all surface here as the pool
    /// distributing value that was never deposited or earned.
    function invariant_paysOutNoMoreThanCameInPlusYield() public view {
        assertLe(
            handler.yieldPaidOut(),
            handler.yieldPaidIn() + handler.venueEarned(),
            "paid out more than was deposited and earned"
        );
    }

    /// Booked idle can never exceed the asset's total backing — it is a
    /// component of it. Catches drift between `_fundVenue` and `_ensureIdle`.
    function invariant_idleNeverExceedsGross() public view {
        assertLe(_state().idle, _gross(), "booked idle exceeds the asset's backing");
    }

    /// `lastIdx` is a high-water mark: `_accruePerf` only ever raises it, and
    /// nothing else writes it. A fall would mean the mark was reset and the
    /// treasury could bill twice for the same growth.
    function invariant_highWaterMarkNeverFalls() public view {
        assertFalse(handler.markFell(), "the fee high-water mark moved backwards");
    }

    /// The venue binding is permanent — nothing in the handler's surface can
    /// change it, and no sequence of calls may either.
    function invariant_venueBindingIsImmutable() public view {
        assertEq(_state().venue, address(venue), "venue binding moved");
        assertTrue(masp.isYieldAsset(YIELD_ID), "asset stopped being indexed");
    }
}

/// Index monotonicity, with the performance fee switched off.
///
/// The research note asserts the index is "monotone non-decreasing absent a
/// venue loss". That is false as written: the performance fee is charged by
/// *minting* units to the treasury, which raises `supply` against an unchanged
/// `gross` and so lowers the per-unit value by design — and `sweepNormalized`
/// both mints and clears in one call, so the dilution is not even visible as a
/// change in the accumulator afterwards.
///
/// With `perfBps = 0` there is no dilution channel left and the claim holds
/// exactly, which is the form worth pinning: nothing other than a venue loss
/// and the fee may ever move the index down.
contract YieldIndexMonotonicityInvariantTest is YieldSolvencyInvariantTest {
    function _perfBps() internal view override returns (uint16) {
        return 0;
    }

    function invariant_indexMonotoneAbsentLossWithNoPerfFee() public view {
        assertFalse(handler.indexFellWithoutLoss(), "index fell with neither a loss nor a fee to explain it");
    }
}

/// Proves the handler actually reaches every path it claims to.
///
/// The invariants above wrap each call in `try`, so a handler whose escrow
/// arguments were subtly wrong would revert on every attempt, catch silently,
/// and leave every invariant trivially true over a history that never settled
/// an escrow. This drives each path deterministically and asserts it fires.
contract YieldHandlerCoverageTest is YieldInvariantBase {
    function test_handlerReachesEveryPath() public {
        handler.deposit(50_000, true);
        handler.deposit(50_000, false);
        assertEq(handler.shields(), 2, "shield path");

        handler.flush(0);
        assertEq(handler.flushes(), 1, "flush path");

        handler.deposit(50_000, true);
        handler.cancel(2);
        assertEq(handler.cancels(), 1, "cancel path");

        handler.withdraw(1_000, true);
        handler.withdraw(1_000, false);
        assertEq(handler.exits(), 2, "unshield path, both ids");

        handler.earn(1e18);
        handler.accruePerf();
        handler.sweep();
        assertEq(handler.sweeps(), 1, "sweep path");

        // Off, then on: the transition the stale-mark bug lived on.
        handler.setParams(500, 0);
        handler.setParams(500, 1000);
        assertEq(handler.feeEnabled(), 1, "fee off-to-on transition");

        handler.rebalance();
        handler.unwind();
        assertEq(handler.unwinds(), 1, "unwind path");
        handler.resume();
        handler.rebalance();
        assertGt(vault.balanceOf(address(venue)), 0, "resume re-supplied the bound vault");
    }
}
