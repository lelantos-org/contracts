// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { YieldIndex } from "../../src/yield/YieldIndex.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { YieldBase } from "./YieldBase.t.sol";

/// Property tests on the index arithmetic, driven through the real pool rather
/// than a harness over the library's internals: the properties concern the
/// composition of pricing, fee and rounding across a whole operation, and a
/// unit-level harness would not detect a leak introduced by their ordering.
///
/// The recurring property is that the pool never rounds in the user's favour. Every
/// conversion is ceil on the way in and floor on the way out, so any sequence
/// that returns more than it cost is a leak, and at these magnitudes a
/// one-unit slip is worth `scale` base units.
contract YieldArithmeticFuzzTest is YieldBase {
    /// Wide enough to cross rounding boundaries, small enough that the pull
    /// stays inside `uint160` for the Permit2 allowance path.
    uint64 internal constant MIN_N = 1_000;
    uint64 internal constant MAX_N = 1e12;

    function _boundN(uint64 raw) internal pure returns (uint64) {
        return uint64(bound(uint256(raw), MIN_N, MAX_N));
    }

    // ============== Rounding direction =======================================

    /// A round trip that earned nothing never returns more than it cost.
    /// Deposit rounds up and withdraw rounds down; any inversion shows up here
    /// as the pool paying out more than it took.
    function testFuzz_roundTripWithoutYieldNeverProfits(uint64 rawN) public {
        uint64 n = _boundN(rawN);
        (, uint256 paidIn) = _deposit(YIELD_ID, n, 0x101);

        uint256 before = token.balanceOf(RECIPIENT);
        _withdraw(YIELD_ID, n, 0x1111);
        uint256 paidOut = token.balanceOf(RECIPIENT) - before;

        assertLe(paidOut, paidIn, "round trip returned more than it cost");
    }

    /// The same, with the venue having earned in between: the exit may now
    /// exceed the deposit, but never by more than the pool actually gained.
    function testFuzz_roundTripWithYieldIsBoundedByRealGrowth(uint64 rawN, uint96 rawGrowth) public {
        uint64 n = _boundN(rawN);
        (, uint256 paidIn) = _deposit(YIELD_ID, n, 0x101);
        uint256 growth = bound(uint256(rawGrowth), 0, 1e24);
        _earn(growth);

        uint256 before = token.balanceOf(RECIPIENT);
        _withdraw(YIELD_ID, n, 0x1111);
        uint256 paidOut = token.balanceOf(RECIPIENT) - before;

        assertLe(paidOut, paidIn + growth, "exit exceeded deposit plus everything the venue earned");
    }

    /// The pool must still hold what it says it holds after any single
    /// operation, whatever the amounts.
    function testFuzz_poolCoversItsBookedIdle(uint64 rawN, uint96 rawGrowth) public {
        uint64 n = _boundN(rawN);
        _deposit(YIELD_ID, n, 0x101);
        _earn(bound(uint256(rawGrowth), 0, 1e24));
        _withdraw(YIELD_ID, n / 2, 0x1111);

        assertGe(token.balanceOf(address(masp)), _idle(YIELD_ID), "pool holds less than its booked idle");
    }

    // ============== Fees =====================================================

    /// A shield is charged principal plus exactly the deposit fee, in units,
    /// converted once. At the first deposit the index is `RAY`, so the whole
    /// arithmetic is checkable in closed form.
    ///
    /// The unit fee rounds up (`Fees.unitFee`). A unit is worth `scale` base
    /// units, so flooring would give away up to a whole `scale` per deposit and
    /// charge nothing below `10_000 / FEE_BPS` units.
    function testFuzz_firstShieldChargesUnitFeeExactly(uint64 rawN) public {
        uint64 n = _boundN(rawN);
        (, uint256 paidIn) = _deposit(YIELD_ID, n, 0x101);

        uint256 nFee = Math.ceilDiv(uint256(n) * FEE_BPS, 10_000);
        assertEq(paidIn, (uint256(n) + nFee) * SCALE, "fee charged in units, converted once on the total");
        assertEq(masp.index(YIELD_ID), RAY, "empty pool prices at RAY");
    }

    /// No deposit size is fee-free. A floored unit fee would be zero for every
    /// `publicIn` under `10_000 / FEE_BPS`, and deposit size has no lower bound,
    /// so the fee could be avoided by splitting deposits, which is material at a
    /// large `scale`.
    ///
    /// Swept across the entire sub-threshold range rather than fuzzed, because
    /// the range is small and the boundary is the property under test.
    function test_noSubThresholdDepositIsFree() public {
        uint64 threshold = 10_000 / FEE_BPS; // 400 at 25 bps
        for (uint64 n = 1; n <= threshold; ++n) {
            uint256 nFee = Math.ceilDiv(uint256(n) * FEE_BPS, 10_000);
            assertEq(nFee, 1, "sub-threshold deposit rounds to a one-unit fee");
        }
        // And the fee is still exact, not inflated, once past the boundary.
        assertEq(Math.ceilDiv(uint256(threshold + 1) * FEE_BPS, 10_000), 2, "just past the boundary");
        assertEq(Math.ceilDiv(uint256(2 * threshold) * FEE_BPS, 10_000), 2, "exactly two units' worth");
    }

    /// The performance fee is a cut of growth only: it never exceeds `perfBps`
    /// of what the venue earned.
    function testFuzz_perfFeeNeverExceedsItsShareOfGrowth(uint64 rawN, uint96 rawGrowth, uint16 rawPerf) public {
        uint64 n = _boundN(rawN);
        uint16 perfBps = uint16(bound(uint256(rawPerf), 0, 2_000));
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, perfBps);
        // A rate above the registered one is queued; land it before any growth.
        if (perfBps > PERF_BPS) _commit(YIELD_ID);
        assertEq(masp.yieldState(YIELD_ID).perfBps, perfBps);

        _deposit(YIELD_ID, n, 0x101);
        uint256 growth = bound(uint256(rawGrowth), 0, 1e24);
        _earn(growth);
        masp.accruePerf(YIELD_ID);

        YieldIndex.YieldState memory st = masp.yieldState(YIELD_ID);
        uint256 supply = st.totalNormalized + st.accruedFeeNormalized;
        if (supply == 0 || st.accruedFeeNormalized == 0) return;

        uint256 treasuryValue = (st.accruedFeeNormalized * _gross(YIELD_ID)) / supply;
        assertLe(treasuryValue, (growth * perfBps) / 10_000, "treasury took more than its share of the growth");
    }

    /// A loss is never billed. The high-water mark holds until the pool climbs
    /// back past its previous peak, for any sequence of moves.
    function testFuzz_noPerfFeeWhileUnderWater(uint64 rawN, uint96 rawGrowth, uint96 rawLoss) public {
        uint64 n = _boundN(rawN);
        _deposit(YIELD_ID, n, 0x101);

        uint256 growth = bound(uint256(rawGrowth), 1, 1e22);
        _earn(growth);
        masp.accruePerf(YIELD_ID);
        uint256 feeAtPeak = masp.yieldState(YIELD_ID).accruedFeeNormalized;

        uint256 loss = bound(uint256(rawLoss), 1, vault.totalAssetsHeld());
        vault.lose(loss);
        masp.accruePerf(YIELD_ID);
        assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, feeAtPeak, "charged a fee through a loss");

        // Recovering by strictly less than the loss still owes nothing.
        if (loss > 1) {
            _earn(loss - 1);
            masp.accruePerf(YIELD_ID);
            assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, feeAtPeak, "charged before regaining the peak");
        }
    }

    /// Enabling the fee does not bill growth that accrued while it was off.
    ///
    /// `_accruePerf` returns on `perfBps == 0` before it touches `lastIdx`, so
    /// the mark stays fixed while the fee is disabled. Without a re-mark when
    /// the rate changes, the first accrual after re-enabling would bill against
    /// the mark from inception, charging holders a cut of growth earned while
    /// the fee was zero.
    function testFuzz_enablingTheFeeDoesNotBillEarlierGrowth(uint64 rawN, uint96 rawGrowth) public {
        uint64 n = _boundN(rawN);
        // Large enough that a cut of it rounds to at least one unit, so a
        // violation is not masked by `m == 0`.
        uint256 early = bound(uint256(rawGrowth), 1e13, 1e22);

        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, 0);

        _deposit(YIELD_ID, n, 0x101);
        _earn(early);
        masp.accruePerf(YIELD_ID);
        assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, 0, "charged while the rate was zero");

        // Enabling the fee is a raise, so it lands at the commit, which
        // re-marks the water line to there: nothing already earned is billable.
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, PERF_BPS);
        _commit(YIELD_ID);
        assertEq(masp.yieldState(YIELD_ID).perfBps, PERF_BPS);
        masp.accruePerf(YIELD_ID);
        assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, 0, "billed growth that predates the fee");

        // Only growth from this point on is billable, and only its `perfBps`.
        uint256 late = 1e18;
        _earn(late);
        masp.accruePerf(YIELD_ID);

        YieldIndex.YieldState memory st = masp.yieldState(YIELD_ID);
        uint256 treasuryValue =
            (st.accruedFeeNormalized * _gross(YIELD_ID)) / (st.totalNormalized + st.accruedFeeNormalized);
        assertLe(treasuryValue, (late * PERF_BPS) / 10_000, "billed more than its share of post-enable growth");
    }

    /// A depositor arriving after sub-unit growth is not billed for it.
    ///
    /// A performance cut worth less than one unit mints nothing and carries the
    /// growth forward. Were the mark left there when the supply grows, the next
    /// accrual would bill the entrant's units for growth that predates them. At
    /// `scale = 1` a unit is one base unit, so a tiny position can carry a
    /// large sub-unit backlog, and the victim's loss would be a real fraction of
    /// their deposit.
    ///
    /// Two measures: the first accrual after arrival, with no growth since,
    /// mints nothing; and the entrant's units are worth what it paid, less
    /// rounding. The pull rounds up and the value down (one base unit), and the
    /// mock vault floors the shares it mints, which can cost up to one share's
    /// worth of underlying; neither is a fee.
    function testFuzz_entrantIsNeverBilledPreArrivalGrowth(uint16 rawSeed, uint64 rawGrowth, uint64 rawN, bool poke)
        public
    {
        uint64 seedUnits = uint64(bound(uint256(rawSeed), 1, 1_000));
        uint256 growth = bound(uint256(rawGrowth), 0, 1e12);
        uint64 n = _boundN(rawN);

        _deposit(FINE_ID, seedUnits, 0x101);
        _earnInto(vaultFine, growth);
        // A permissionless accrual between the growth and the arrival must not
        // change the outcome.
        if (poke) masp.accruePerf(FINE_ID);

        uint256 sharePrice = Math.ceilDiv(vaultFine.totalAssetsHeld(), vaultFine.totalSupply());
        uint256 unitsBefore = masp.yieldState(FINE_ID).totalNormalized;
        (, uint256 paidIn) = _deposit(FINE_ID, n, 0x301);
        uint256 entrantUnits = masp.yieldState(FINE_ID).totalNormalized - unitsBefore;
        uint256 feeAtArrival = masp.yieldState(FINE_ID).accruedFeeNormalized;

        // No growth since arrival: anything minted now is billed on the past.
        masp.accruePerf(FINE_ID);
        assertEq(masp.yieldState(FINE_ID).accruedFeeNormalized, feeAtArrival, "billed growth that predates the entrant");

        uint256 value = (entrantUnits * _grossFine()) / _supply(FINE_ID);
        assertGe(value + 1 + sharePrice, paidIn, "entrant lost more than rounding");
    }

    // ============== Escrow ===================================================

    /// A cancellation returns the escrowed units at the current index, capped at
    /// the amount pulled at submit, and never more than the pool holds for them.
    function testFuzz_cancelRefundIsBounded(uint64 rawN, uint96 rawGrowth) public {
        uint64 n = _boundN(rawN);
        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id, uint256 paidIn) = _deposit(YIELD_ID, n, 0x101);

        uint256 growth = bound(uint256(rawGrowth), 0, 1e24);
        _earn(growth);
        vm.roll(block.number + 7_201);

        uint256 grossBefore = _gross(YIELD_ID);
        uint256 before = token.balanceOf(payer);
        masp.cancelDeposit(
            id,
            uint48(n),
            bytes32(uint256(0x101)),
            [uint256(0), 0],
            YIELD_ID,
            FEE_BPS,
            payer,
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0x102)), feeCvDep: [uint256(0), 0] })
        );
        uint256 refunded = token.balanceOf(payer) - before;

        assertLe(refunded, paidIn, "refund exceeded the submit-time pull");
        assertLe(refunded, grossBefore, "refund exceeded what the pool held");
        assertLe(refunded, paidIn + growth, "refund exceeded the deposit plus everything it earned");
        assertEq(masp.yieldState(YIELD_ID).totalNormalized, 0, "holder liability released in full");
    }

    // ============== Scale ====================================================

    /// `scale` does not affect the index.
    ///
    /// Two assets holding the same number of units, whose venues grew by the
    /// same proportion, report the same index: the underlying amounts differ by
    /// `scale`, and that factor cancels. A USDC-only suite cannot detect this,
    /// since at `scale = 1` an index formula that omits `scale` is correct.
    function testFuzz_scaleDoesNotDistortTheIndex(uint64 rawN, uint96 rawGrowth) public {
        uint64 n = _boundN(rawN);
        uint256 growth = bound(uint256(rawGrowth), 0, 1e18);

        _deposit(YIELD_ID, n, 0x101); // scale 1e10
        _deposit(FINE_ID, n, 0x301); // scale 1
        assertEq(masp.index(YIELD_ID), masp.index(FINE_ID), "empty pools disagree before any growth");

        // Same proportional growth: the coarse asset's underlying is `SCALE`
        // times the fine one's, so its interest must be too.
        _earnInto(vault, growth * SCALE);
        _earnInto(vaultFine, growth * FINE_SCALE);

        assertEq(masp.index(YIELD_ID), masp.index(FINE_ID), "index diverged on scale alone");
    }
}
