// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YieldIndex } from "../../src/yield/YieldIndex.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { YieldBase } from "./YieldBase.t.sol";

/// Property tests on the index arithmetic, driven through the real pool rather
/// than a harness over the library's internals: the properties that matter are
/// about the *composition* of pricing, fee and rounding across a whole
/// operation, and a unit-level harness would not see a leak introduced by the
/// order those are applied in.
///
/// The recurring shape is "the pool never rounds in the user's favour". Every
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

    /// A round trip that earned nothing must never return more than it cost.
    /// This is the leak test: deposit rounds up, withdraw rounds down, and any
    /// inversion shows up here as the pool paying out more than it took.
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
    function testFuzz_firstShieldChargesUnitFeeExactly(uint64 rawN) public {
        uint64 n = _boundN(rawN);
        (, uint256 paidIn) = _deposit(YIELD_ID, n, 0x101);

        uint256 nFee = (uint256(n) * FEE_BPS) / 10_000;
        assertEq(paidIn, (uint256(n) + nFee) * SCALE, "fee charged in units, converted once on the total");
        assertEq(masp.index(YIELD_ID), RAY, "empty pool prices at RAY");
    }

    /// The performance fee is a cut of growth and nothing else: it can never
    /// exceed `perfBps` of what the venue actually earned.
    function testFuzz_perfFeeNeverExceedsItsShareOfGrowth(uint64 rawN, uint96 rawGrowth, uint16 rawPerf) public {
        uint64 n = _boundN(rawN);
        uint16 perfBps = uint16(bound(uint256(rawPerf), 0, 2_000));
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, perfBps);

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

    /// A loss can never be billed for. The high-water mark holds until the pool
    /// climbs back past its old peak, whatever the sequence of moves.
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

    /// Switching the fee on must not reach back over growth that accrued while
    /// it was off.
    ///
    /// `_accruePerf` returns on `perfBps == 0` before it touches `lastIdx`, so
    /// the mark sits frozen for the whole time a fee is disabled. Without a
    /// re-mark when the rate changes, the first accrual after re-enabling bills
    /// against the mark from *inception* — charging holders a cut of everything
    /// they earned during an explicitly fee-free period.
    function testFuzz_enablingTheFeeDoesNotBillEarlierGrowth(uint64 rawN, uint96 rawGrowth) public {
        uint64 n = _boundN(rawN);
        // Large enough that a cut of it would round to at least one unit, so a
        // regression cannot hide behind `m == 0`.
        uint256 early = bound(uint256(rawGrowth), 1e13, 1e22);

        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, 0);

        _deposit(YIELD_ID, n, 0x101);
        _earn(early);
        masp.accruePerf(YIELD_ID);
        assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, 0, "charged while the rate was zero");

        // Enabling the fee re-marks the water line to here, so nothing already
        // earned is billable.
        vm.prank(OWNER);
        masp.setYieldParams(YIELD_ID, BUFFER_BPS, PERF_BPS);
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

    // ============== Escrow ===================================================

    /// A cancellation returns the escrowed units at the current index and never
    /// more than the pool holds for them.
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
            PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(uint256(0x102)), feeCvDep: [uint256(0), 0] })
        );
        uint256 refunded = token.balanceOf(payer) - before;

        assertLe(refunded, grossBefore, "refund exceeded what the pool held");
        assertLe(refunded, paidIn + growth, "refund exceeded the deposit plus everything it earned");
        assertEq(masp.yieldState(YIELD_ID).totalNormalized, 0, "holder liability released in full");
    }

    // ============== Scale ====================================================

    /// `scale` must not leak into the index.
    ///
    /// Two assets holding the same number of units, whose venues grew by the
    /// same *proportion*, must report the same index — the underlying amounts
    /// differ by `scale`, and that factor has to cancel. This is the bug a
    /// USDC-only suite cannot see: at `scale = 1` an index formula that omits
    /// `scale` is accidentally correct.
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
