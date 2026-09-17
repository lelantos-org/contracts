// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { ERC4626Venue } from "../../src/yield/ERC4626Venue.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { deployPoolUniform, singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";

import { YieldHandler } from "./YieldHandler.sol";

/// Deployment and helpers shared by the suites below.
///
/// Separate from the properties so the coverage test can reuse the fixture
/// without inheriting the invariants.
abstract contract YieldInvariantBase is Test {
    uint64 internal constant PLAIN_ID = 1;
    uint64 internal constant YIELD_ID = 9;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant TREASURY = TestConstants.TREASURY;

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

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), PLAIN_ID, SCALE);

        masp = deployPoolUniform(
            tub, bv, ISignatureTransfer(permit2), ids, tokens, scales, FEE_BPS, TREASURY, address(this)
        );

        vault = new MockERC4626(IERC20(address(token)));
        venue = new ERC4626Venue(address(masp), address(vault), address(token));
        masp.addYieldAsset(YIELD_ID, IERC20(address(token)), SCALE, FEE_BPS, FEE_BPS, address(venue), 500, _perfBps());

        Stubs.acceptAllProofs(tub, bv);

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
    /// The pool holds the idle balance it has booked, on top of everything the
    /// plain id and the treasury are owed out of the same ERC-20. Two asset ids
    /// over one token put this property at risk, which is why `idle` is tracked
    /// rather than read from `balanceOf`.
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

    /// Over any history, what the yield id has paid out does not exceed what
    /// went into it plus what its venue earned.
    ///
    /// A rounding leak, a double-credited fee, or a refund priced off a stale
    /// index all surface here as the pool distributing value that was never
    /// deposited or earned.
    function invariant_paysOutNoMoreThanCameInPlusYield() public view {
        assertLe(
            handler.yieldPaidOut(),
            handler.yieldPaidIn() + handler.venueEarned(),
            "paid out more than was deposited and earned"
        );
    }

    /// No cancel, of either id, refunds more than its escrow pulled at submit.
    /// A plain escrow refunds its pull exactly; a yield escrow refunds its value
    /// at the current index capped at the pull, so the growth its units carried
    /// while pending stays with the holders.
    function invariant_cancelNeverRefundsMoreThanThePull() public view {
        assertFalse(handler.refundExceededPull(), "a cancel refunded more than its escrow pulled");
    }

    /// Booked idle never exceeds the asset's total backing, of which it is a
    /// component. Detects drift between `_fundVenue` and `_ensureIdle`.
    function invariant_idleNeverExceedsGross() public view {
        assertLe(_state().idle, _gross(), "booked idle exceeds the asset's backing");
    }

    /// `lastIdx` is a high-water mark and never decreases. A fall would mean the
    /// mark was reset and the treasury could bill twice for the same growth.
    function invariant_highWaterMarkNeverFalls() public view {
        assertFalse(handler.markFell(), "the fee high-water mark moved backwards");
    }

    /// The venue binding is permanent: no call or sequence of calls in the
    /// handler's surface changes it.
    function invariant_venueBindingIsImmutable() public view {
        assertEq(_state().venue, address(venue), "venue binding moved");
        assertTrue(masp.isYieldAsset(YIELD_ID), "asset stopped being indexed");
    }
}

/// Index monotonicity, with the performance fee switched off.
///
/// The index is not monotone non-decreasing absent a venue loss when the
/// performance fee is on: the fee is charged by minting units to the treasury,
/// which raises `supply` against an unchanged `gross` and lowers the per-unit
/// value by design. `sweepNormalized` both mints and clears in one call, so the
/// dilution is not visible as a change in the accumulator afterwards.
///
/// With `perfBps = 0` there is no dilution channel and monotonicity holds
/// exactly: only a venue loss or the fee may move the index down.
contract YieldIndexMonotonicityInvariantTest is YieldSolvencyInvariantTest {
    function _perfBps() internal view override returns (uint16) {
        return 0;
    }

    function invariant_indexMonotoneAbsentLossWithNoPerfFee() public view {
        assertFalse(handler.indexFellWithoutLoss(), "index fell with neither a loss nor a fee to explain it");
    }
}

/// Checks that the handler reaches every path it exposes.
///
/// The handler wraps each call in `try`, so a handler with incorrect escrow
/// arguments would revert on every attempt, catch without signal, and leave
/// every invariant trivially true over a history that never settled an escrow.
/// This drives each path deterministically and asserts it executes.
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

        // Off, then on: the transition on which the mark is re-set. Turning the
        // fee on is a raise, so it lands only at the commit.
        handler.setParams(500, 0);
        handler.setParams(500, 1000);
        assertEq(handler.feeEnabled(), 0, "a raise applied without notice");
        handler.commitParams();
        assertEq(handler.commits(), 1, "commit path");
        assertEq(handler.feeEnabled(), 1, "fee off-to-on transition");

        handler.rebalance();
        handler.unwind();
        assertEq(handler.unwinds(), 1, "unwind path");
        handler.resume();
        handler.rebalance();
        assertGt(vault.balanceOf(address(venue)), 0, "resume re-supplied the bound vault");
    }
}
