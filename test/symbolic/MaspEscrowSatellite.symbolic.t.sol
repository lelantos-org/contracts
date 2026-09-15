// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockEscrowPool, MockEscrowToken } from "./mocks/MockEscrowPool.sol";

/// The concrete satellite the proofs drive.
///
/// `MaspEscrowSatellite` is abstract and both functions under proof are internal,
/// so a subclass is required; this one adds only external wrappers and a way to
/// seed a record. The production subclasses `NativeAdapter` and `SwapWrapper`
/// each wrap these two functions with their own payout, so the base-class
/// accounting can be proved independently of either.
///
/// The wrappers omit `nonReentrant`. The base class requires subclasses to apply
/// it, and both production subclasses do; here it would add a transient-storage
/// guard to every explored path, and no property below concerns re-entry.
contract SatelliteHarness is MaspEscrowSatellite {
    IERC20 internal immutable TOKEN;

    constructor(IMASPPool pool, IAllowanceTransfer permit2, IERC20 token) MaspEscrowSatellite(pool, permit2) {
        TOKEN = token;
    }

    function _escrowToken(uint256, uint64) internal view override returns (IERC20) {
        return TOKEN;
    }

    /// Writes the record a deposit would leave, so a cancel proof can quantify
    /// over the recorded amount directly rather than fixing it through a deposit.
    function seed(uint256 id, address refundTo, uint96 amount) external {
        _escrows[id] = Escrow({ refundTo: refundTo, amount: amount });
    }

    function recordOf(uint256 id) external view returns (address refundTo, uint96 amount) {
        Escrow memory e = _escrows[id];
        return (e.refundTo, e.amount);
    }

    function cancelAndVerify(
        uint256 id,
        uint48 publicIn,
        bytes32 cm,
        uint256[2] calldata cvDep,
        uint64 publicAssetId,
        uint16 fbps,
        uint32 submittedAt,
        PubInputs.FeeNote calldata feeNote
    ) external returns (IERC20, address, uint256) {
        return _cancelAndVerify(id, publicIn, cm, cvDep, publicAssetId, fbps, submittedAt, feeNote);
    }

    function escrowMeasured(
        uint256 baseline,
        uint256 minPull,
        uint256 maxPull,
        PubInputs.DepositRequest calldata d,
        AuxValidation.Output calldata aux,
        AuxValidation.Output calldata feeAux
    ) external returns (uint256, uint256) {
        return _escrowMeasured(TOKEN, baseline, minPull, maxPull, d, aux, feeAux);
    }
}

/// Symbolic proofs for the refund accounting every satellite inherits.
///
/// A satellite escrows into MASP as its own payer, so the pool refunds the
/// satellite on a cancel rather than the party that funded the deposit. The
/// satellite's funder record and its check that the refund arrived prevent a
/// misdirected or unfunded payout. The pool checks neither: to MASP a satellite
/// is one payer whose Permit2 allowance covers its entire balance.
///
/// Three properties, each over every amount the pool might move:
///
/// 1. **The delivered refund equals the reported one, for every amount.** The
///    satellite cannot recompute what it is owed (it cannot see the pool's
///    deposit fee, and a yield refund is priced at the current index and may
///    fall below the pull), so it checks a measured balance delta against the
///    refund the pool returns. A loose check would accept an underfunded refund;
///    a floor at the record would block a correct yield cancel.
/// 2. **An escrow is consumed once.** The record is the authorization; if it
///    survived a cancel, a second call would pay again against the same escrow.
/// 3. **The measured pull is bounded on both sides.** `d` is unauthenticated
///    calldata and the allowance covers the satellite's whole balance, so
///    without a ceiling an oversized `publicIn` would escrow balances held for
///    other parties.
///
/// Each is a boundary over the full `uint256` delta the pool can deliver; the
/// edge values (one off the report in either direction, zero, far below the
/// record) are unlikely to be sampled by a fuzzer. Both functions use only comparison and
/// subtraction, with no division, which keeps them tractable.
contract MaspEscrowSatelliteSymbolicTest is GuardAsserts {
    SatelliteHarness internal sat;
    MockEscrowPool internal pool;
    MockEscrowToken internal token;

    address internal constant FUNDER = address(0xF00D);
    uint256 internal constant ID = 1;

    /// Headroom on the satellite's balance, so a proof quantifying over a pull is
    /// not bounded by an insufficient balance.
    uint256 internal constant SEED_BALANCE = type(uint128).max;

    function setUp() public {
        token = new MockEscrowToken();
        pool = new MockEscrowPool(token);
        sat =
            new SatelliteHarness(IMASPPool(address(pool)), IAllowanceTransfer(address(0xBEEF)), IERC20(address(token)));
        token.credit(address(sat), SEED_BALANCE);
    }

    // --- The refund matches the pool's report -------------------------------

    /// Every refund whose delivered amount differs from the amount the pool
    /// reports paying is rejected.
    ///
    /// The satellite cannot recompute what it is owed (it cannot see the pool's
    /// deposit fee, and a yield refund is priced at the current index), so it
    /// takes the pool's returned refund as the claim and the balance delta as the
    /// evidence. A short delivery must not clear a record out of another
    /// escrow's coin, and a long one indicates fee-on-transfer or an unattributed
    /// balance movement. Quantified over the recorded, delivered and reported
    /// amounts.
    function check_cancel_rejectsEveryMisreportedRefund(uint96 amount, uint256 delivered, uint256 reported) public {
        vm.assume(delivered != reported);
        // The mock token credits the refund onto `SEED_BALANCE`, and checked
        // addition reverts before the satellite's check if the sum overflows.
        vm.assume(delivered <= type(uint256).max - SEED_BALANCE);

        sat.seed(ID, FUNDER, amount);
        pool.open(ID);
        pool.setRefund(delivered);
        pool.setReported(reported);

        (bool ok, bytes memory ret) = _cancel(ID);

        _assertRejected(ok, ret, MaspEscrowSatellite.RefundMismatch.selector, "a misreported refund cleared the record");
    }

    /// Every refund delivered exactly as reported is accepted, and the returned
    /// amount is the delivered amount, not the recorded one, even below it.
    ///
    /// The accepting side of the same boundary, so a correct cancel does not
    /// revert. A yield refund is capped at the pull and floored at the current
    /// index, so it falls below the recorded amount by rounding at a flat index
    /// or by a venue loss; a floor at the record would leave such an escrow with
    /// no refund path. Returning the recorded amount instead would pay the
    /// shortfall out of another escrow's coin.
    function check_cancel_acceptsEveryExactRefund(uint96 amount, uint256 delivered) public {
        vm.assume(delivered <= type(uint256).max - SEED_BALANCE);

        sat.seed(ID, FUNDER, amount);
        pool.open(ID);
        pool.setRefund(delivered);
        pool.setReported(delivered);

        (, address refundTo, uint256 paid) = sat.cancelAndVerify(
            ID, 0, bytes32(0), [uint256(0), 0], 0, 0, 0, PubInputs.FeeNote(0, 0, bytes32(0), [uint256(0), 0])
        );

        assertEq(refundTo, FUNDER, "refund misdirected");
        assertEq(paid, delivered, "payout did not follow the delivered amount");
    }

    // --- An escrow is consumed once -----------------------------------------

    /// A cancel cannot be replayed, for every recorded amount.
    ///
    /// The record is the authorization, so the second call must find nothing.
    /// Deleting before the external call also keeps the balance delta
    /// attributable: otherwise a re-entrant token could cancel again inside the
    /// first refund, and both measurements would include the combined movement.
    function check_cancel_cannotBeReplayed(uint96 amount) public {
        sat.seed(ID, FUNDER, amount);
        pool.open(ID);
        pool.setRefund(amount);
        pool.setReported(amount);

        sat.cancelAndVerify(
            ID, 0, bytes32(0), [uint256(0), 0], 0, 0, 0, PubInputs.FeeNote(0, 0, bytes32(0), [uint256(0), 0])
        );

        (address refundTo, uint96 recorded) = sat.recordOf(ID);
        assertEq(refundTo, address(0), "record survived the cancel");
        assertEq(recorded, 0, "amount survived the cancel");

        (bool ok, bytes memory ret) = _cancel(ID);
        _assertRejected(ok, ret, MaspEscrowSatellite.NoEscrowRecord.selector, "a cancel was replayed");
    }

    /// An id the satellite never escrowed is refused, for every id and every
    /// refund amount; otherwise the refund would reach the satellite with no
    /// record of its funder.
    function check_cancel_rejectsEveryUnknownId(uint256 id, uint256 delivered) public {
        pool.setRefund(delivered);

        (bool ok, bytes memory ret) = _cancel(id);

        _assertRejected(
            ok, ret, MaspEscrowSatellite.NoEscrowRecord.selector, "cancelled an escrow that was never recorded"
        );
    }

    /// A deposit already settled by a flush carries no refund, so the cancel is
    /// refused and the record is left intact.
    ///
    /// The pool zeroes `escrowed[id]` on both flush and cancel, making them
    /// mutually exclusive; the satellite reads it before clearing its record.
    function check_cancel_rejectsSettledDeposit(uint96 amount) public {
        sat.seed(ID, FUNDER, amount);
        pool.settle(ID);

        (bool ok, bytes memory ret) = _cancel(ID);

        _assertRejected(ok, ret, MaspEscrowSatellite.DepositAlreadySettled.selector, "cancelled a settled deposit");

        (address refundTo,) = sat.recordOf(ID);
        assertEq(refundTo, FUNDER, "a refused cancel cleared the record");
    }

    // --- The measured pull is bounded ---------------------------------------

    /// Every pull below the caller's floor is rejected. A deposit denominated in
    /// another asset moves none of this token and measures zero, which this
    /// bound rejects.
    function check_escrow_rejectsEveryPullBelowMin(uint96 pulled, uint96 minPull) public {
        vm.assume(pulled < minPull);
        pool.setPull(pulled);

        (bool ok, bytes memory ret) = _escrow(minPull, type(uint96).max);

        _assertRejected(ok, ret, MaspEscrowSatellite.PullBelowMin.selector, "a short pull was recorded");
    }

    /// Every pull above the caller's ceiling is rejected.
    ///
    /// `d` is unauthenticated calldata and the Permit2 allowance granted to the
    /// pool covers the satellite's whole balance, so without this bound an
    /// oversized `publicIn` would escrow funds held for other parties.
    function check_escrow_rejectsEveryPullAboveMax(uint96 pulled, uint96 maxPull) public {
        vm.assume(pulled > maxPull);
        pool.setPull(pulled);

        (bool ok, bytes memory ret) = _escrow(0, maxPull);

        _assertRejected(ok, ret, MaspEscrowSatellite.PullExceedsMax.selector, "an oversized pull was recorded");
    }

    /// Non-vacuity: every pull within both bounds is accepted and measured
    /// exactly, so the two proofs above are not satisfied by a function that
    /// rejects everything.
    function check_escrow_acceptsAndMeasuresEveryPullInRange(uint96 pulled, uint96 minPull, uint96 maxPull) public {
        vm.assume(pulled >= minPull);
        vm.assume(pulled <= maxPull);
        pool.setPull(pulled);

        (, uint256 measured) = sat.escrowMeasured(SEED_BALANCE, minPull, maxPull, _request(), _aux(), _aux());

        assertEq(measured, uint256(pulled), "the measured pull is not what the pool took");
    }

    // --- helpers ------------------------------------------------------------

    function _cancel(uint256 id) internal returns (bool ok, bytes memory ret) {
        return address(sat)
            .call(
                abi.encodeCall(
                    SatelliteHarness.cancelAndVerify,
                    (id, 0, bytes32(0), [uint256(0), 0], 0, 0, 0, PubInputs.FeeNote(0, 0, bytes32(0), [uint256(0), 0]))
                )
            );
    }

    function _escrow(uint256 minPull, uint256 maxPull) internal returns (bool ok, bytes memory ret) {
        return address(sat)
            .call(
                abi.encodeCall(
                    SatelliteHarness.escrowMeasured, (SEED_BALANCE, minPull, maxPull, _request(), _aux(), _aux())
                )
            );
    }

    /// The request is passed through to the pool and never read by the
    /// satellite, so it is concrete; no property depends on its contents.
    function _request() internal pure returns (PubInputs.DepositRequest memory d) { }

    function _aux() internal pure returns (AuxValidation.Output memory a) { }
}
