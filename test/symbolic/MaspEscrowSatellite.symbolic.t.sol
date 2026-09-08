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
/// `MaspEscrowSatellite` is abstract and both functions under proof are
/// internal, so a subclass has to exist regardless; this one adds nothing but
/// external wrappers and a way to seed a record. `NativeAdapter` and
/// `SwapWrapper` are the production subclasses, and each wraps these two
/// functions with its own payout — which is exactly the split the base class
/// documents, and the reason the accounting can be proved without either.
///
/// `nonReentrant` is deliberately absent from the wrappers. The base class
/// requires the subclass to supply it and both production subclasses do; adding
/// it here would only put a transient-storage guard in front of every path
/// explored, and no property below is about re-entry.
contract SatelliteHarness is MaspEscrowSatellite {
    IERC20 internal immutable TOKEN;

    constructor(IMASPPool pool, IAllowanceTransfer permit2, IERC20 token) MaspEscrowSatellite(pool, permit2) {
        TOKEN = token;
    }

    function _consumeEscrowToken(uint256) internal view override returns (IERC20) {
        return TOKEN;
    }

    /// Writes the record `depositAuthorized` would have left, so a cancel proof
    /// can quantify over the recorded amount directly instead of reaching it
    /// through a deposit that would fix it.
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
/// A satellite escrows into MASP as its own payer, so the pool refunds *it* on
/// a cancel rather than the party that funded the deposit. The record it keeps
/// of that party, and the amount it verifies arrived, are the only things
/// standing between a cancel and a misdirected or unfunded payout. Neither is
/// checked by the pool: from MASP's side a satellite is one payer with one
/// allowance, and `README.md` records that its Permit2 grant covers the
/// satellite's entire balance.
///
/// Three properties carry that weight, and all three are statements about every
/// amount the pool might move:
///
/// 1. **The refund floor holds for every delivered amount.** The satellite
///    cannot recompute what it is owed — it cannot see the pool's deposit fee,
///    and on a yield asset the refund exceeds the pull by whatever the escrow
///    earned — so it measures a balance delta and checks it against the floor.
///    An off-by-one there either strands correct cancels or accepts underfunded
///    ones.
/// 2. **An escrow is consumed once.** The record is the authorization; if it
///    survived a cancel, the second call would pay a second time against one
///    escrow.
/// 3. **The measured pull is bounded on both sides.** `d` is unauthenticated
///    calldata and the allowance covers everything the satellite holds, so
///    without a ceiling an oversized `publicIn` escrows balances parked for
///    other parties.
///
/// Worth a solver rather than a fuzzer because each is a boundary over the full
/// `uint256` delta the pool can deliver, and the interesting values — exactly
/// at the floor, one below it, exactly at `type(uint96).max`, one above — are
/// four points a sampler has no reason to draw. Everything reachable is
/// comparison and subtraction; there is no division anywhere in either
/// function, which is what keeps this tractable where the yield accounting that
/// produces the refund is not.
contract MaspEscrowSatelliteSymbolicTest is GuardAsserts {
    SatelliteHarness internal sat;
    MockEscrowPool internal pool;
    MockEscrowToken internal token;

    address internal constant FUNDER = address(0xF00D);
    uint256 internal constant ID = 1;

    /// Headroom on the satellite's balance, so a proof that quantifies over a
    /// refund is not silently bounded by the token running out.
    uint256 internal constant SEED_BALANCE = type(uint128).max;

    function setUp() public {
        token = new MockEscrowToken();
        pool = new MockEscrowPool(token);
        sat =
            new SatelliteHarness(IMASPPool(address(pool)), IAllowanceTransfer(address(0xBEEF)), IERC20(address(token)));
        token.credit(address(sat), SEED_BALANCE);
    }

    // --- The refund floor ---------------------------------------------------

    /// Every refund that falls short of the recorded amount is rejected.
    ///
    /// This is the guard's reason for existing: a partially delivered or
    /// entirely absent refund must not clear a record, because clearing it
    /// destroys the only evidence of what the funder is owed. Quantified over
    /// both the recorded amount and the delivered one, so the boundary is
    /// proved rather than sampled at it.
    function check_cancel_rejectsEveryUnderfundedRefund(uint96 amount, uint256 delivered) public {
        vm.assume(delivered < amount);

        sat.seed(ID, FUNDER, amount);
        pool.open(ID);
        pool.setRefund(delivered);

        (bool ok, bytes memory ret) = _cancel(ID);

        _assertRejected(
            ok, ret, MaspEscrowSatellite.RefundNotFunded.selector, "an underfunded refund cleared the record"
        );
    }

    /// Every refund at or above the recorded amount is accepted, and the amount
    /// reported back is what actually arrived — not what was recorded.
    ///
    /// The other direction of the same boundary, and the one that keeps a
    /// correct cancel from reverting. Forwarding the measured delta rather than
    /// the recorded amount is what lets the payout follow a yield index that
    /// moved while the funds sat in escrow; returning the recorded figure
    /// instead would strand the difference in the satellite.
    function check_cancel_acceptsEveryFundedRefund(uint96 amount, uint96 delivered) public {
        vm.assume(delivered >= amount);

        sat.seed(ID, FUNDER, amount);
        pool.open(ID);
        pool.setRefund(delivered);

        (, address refundTo, uint256 paid) = sat.cancelAndVerify(
            ID, 0, bytes32(0), [uint256(0), 0], 0, 0, 0, PubInputs.FeeNote(0, bytes32(0), [uint256(0), 0])
        );

        assertEq(refundTo, FUNDER, "refund misdirected");
        assertEq(paid, uint256(delivered), "payout did not follow the delivered amount");
    }

    /// A refund too wide for the record's `uint96` is rejected rather than
    /// truncated. Truncation here would silently pay out a fraction of what
    /// arrived and leave the remainder stranded in the satellite.
    function check_cancel_rejectsEveryOversizedRefund(uint96 amount, uint256 delivered) public {
        vm.assume(delivered > type(uint96).max);
        // Above the floor, so the only guard left to fire is the width one.
        vm.assume(delivered >= amount);
        // The stand-in token credits the refund into a balance that already
        // holds `SEED_BALANCE`, and Solidity's checked addition reverts before
        // the satellite is reached if that sum wraps. Excluding only the sums
        // that overflow keeps every value the token could actually deliver,
        // which is still the whole range above `type(uint96).max` less a
        // uint128-sized tail.
        vm.assume(delivered <= type(uint256).max - SEED_BALANCE);

        sat.seed(ID, FUNDER, amount);
        pool.open(ID);
        pool.setRefund(delivered);

        (bool ok, bytes memory ret) = _cancel(ID);

        _assertRejected(
            ok, ret, MaspEscrowSatellite.EscrowAmountTooLarge.selector, "an out-of-range refund was recorded"
        );
    }

    // --- An escrow is consumed once -----------------------------------------

    /// A cancel cannot be replayed, for every recorded amount.
    ///
    /// The record is the authorization, so the second call must find nothing.
    /// `delete` before the external call is also what makes the balance delta
    /// attributable: a re-entrant token could otherwise cancel again inside the
    /// first refund and both measurements would see the combined movement.
    function check_cancel_cannotBeReplayed(uint96 amount) public {
        sat.seed(ID, FUNDER, amount);
        pool.open(ID);
        pool.setRefund(amount);

        sat.cancelAndVerify(
            ID, 0, bytes32(0), [uint256(0), 0], 0, 0, 0, PubInputs.FeeNote(0, bytes32(0), [uint256(0), 0])
        );

        (address refundTo, uint96 recorded) = sat.recordOf(ID);
        assertEq(refundTo, address(0), "record survived the cancel");
        assertEq(recorded, 0, "amount survived the cancel");

        (bool ok, bytes memory ret) = _cancel(ID);
        _assertRejected(ok, ret, MaspEscrowSatellite.NoEscrowRecord.selector, "a cancel was replayed");
    }

    /// An id the satellite never escrowed is refused, for every id and every
    /// refund the pool would pay. Without this, the pool's refund would land in
    /// the satellite with no record saying whose it is.
    function check_cancel_rejectsEveryUnknownId(uint256 id, uint256 delivered) public {
        pool.setRefund(delivered);

        (bool ok, bytes memory ret) = _cancel(id);

        _assertRejected(
            ok, ret, MaspEscrowSatellite.NoEscrowRecord.selector, "cancelled an escrow that was never recorded"
        );
    }

    /// A deposit already settled by a flush carries no refund, and the cancel
    /// is refused before the record is cleared.
    ///
    /// The pool zeroes `escrowed[id]` on both a flush and a cancel, which is
    /// what makes the two mutually exclusive. A satellite that skipped this
    /// check would clear its own record and pay out against a refund that never
    /// arrives — caught by the floor, but only after the evidence was gone.
    function check_cancel_rejectsSettledDeposit(uint96 amount) public {
        sat.seed(ID, FUNDER, amount);
        pool.settle(ID);

        (bool ok, bytes memory ret) = _cancel(ID);

        _assertRejected(ok, ret, MaspEscrowSatellite.DepositAlreadySettled.selector, "cancelled a settled deposit");

        (address refundTo,) = sat.recordOf(ID);
        assertEq(refundTo, FUNDER, "a refused cancel cleared the record");
    }

    // --- The measured pull is bounded ---------------------------------------

    /// Every pull below the caller's floor is rejected. A deposit denominated
    /// in another asset moves none of this token and lands at zero, which is
    /// the case this bound is written for.
    function check_escrow_rejectsEveryPullBelowMin(uint96 pulled, uint96 minPull) public {
        vm.assume(pulled < minPull);
        pool.setPull(pulled);

        (bool ok, bytes memory ret) = _escrow(minPull, type(uint96).max);

        _assertRejected(ok, ret, MaspEscrowSatellite.PullBelowMin.selector, "a short pull was recorded");
    }

    /// Every pull above the caller's ceiling is rejected.
    ///
    /// This is the bound that matters most: `d` is unauthenticated calldata and
    /// the Permit2 allowance granted to the pool covers the satellite's whole
    /// balance, so an oversized `publicIn` would otherwise escrow funds parked
    /// there for other parties.
    function check_escrow_rejectsEveryPullAboveMax(uint96 pulled, uint96 maxPull) public {
        vm.assume(pulled > maxPull);
        pool.setPull(pulled);

        (bool ok, bytes memory ret) = _escrow(0, maxPull);

        _assertRejected(ok, ret, MaspEscrowSatellite.PullExceedsMax.selector, "an oversized pull was recorded");
    }

    /// Non-vacuity, and the accepting direction: every pull inside both bounds
    /// is accepted and measured exactly. Without this the two proofs above hold
    /// of a function that rejects everything.
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
                    (id, 0, bytes32(0), [uint256(0), 0], 0, 0, 0, PubInputs.FeeNote(0, bytes32(0), [uint256(0), 0]))
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

    /// The request is passed straight through to the pool and never read by the
    /// satellite, so it is held concrete: nothing below depends on its contents.
    function _request() internal pure returns (PubInputs.DepositRequest memory d) { }

    function _aux() internal pure returns (AuxValidation.Output memory a) { }
}
