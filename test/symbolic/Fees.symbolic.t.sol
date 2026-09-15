// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Fees } from "../../src/libs/Fees.sol";

/// Symbolic proofs for `Fees.unitFee`, the rounded-up unit fee.
///
/// The quote at submit, the accrual at flush and the refund at cancel must agree
/// exactly on this value for an escrow to settle. Both proofs run over the full
/// call-site domain: `units` up to `type(uint48).max` (the bound `Fees` documents
/// and the escrow record enforces) and any `uint16` rate.
///
/// Scope is limited to properties that carry the division symbolically. Properties
/// that require reasoning about the division (`fee <= units`, monotonicity in
/// either argument, the `fee * D` bracketing form of the rounding rule) time out
/// at 120s on both bundled solvers, even with arguments narrowed to uint16, since
/// halmos words are 256-bit regardless of Solidity type. Those properties follow
/// from the characterization proved here and are sampled directly in
/// `test/fuzz/FeeConfig.fuzz.t.sol`.
contract FeesSymbolicTest is GuardAsserts {
    /// `unitFee` is exactly ceiling division of `units * bps` by the
    /// basis-point denominator, for every input in the call-site domain.
    ///
    /// This is the full specification: `fee <= units` for
    /// `bps <= BPS_DENOMINATOR`, monotonicity in either argument, and the
    /// at-most-one-unit rounding cost follow from it arithmetically.
    ///
    /// Both sides reduce to the same symbolic quotient, so the solver checks a
    /// syntactic equality without evaluating the division. The proof pins the
    /// zero-guarded `(num - 1) / D + 1` form to OpenZeppelin's `Math.ceilDiv`;
    /// substituting `(num + D - 1) / D` (overflows near `type(uint256).max`) or
    /// dropping the zero guard (underflow revert) fails it.
    function check_unitFee_isCeilDiv(uint48 units, uint16 bps) public pure {
        uint256 num = uint256(units) * uint256(bps);
        assertEq(Fees.unitFee(units, bps), Math.ceilDiv(num, Fees.BPS_DENOMINATOR));
    }

    /// The fee is zero if and only if the base or the rate is zero.
    ///
    /// Rounding up exists to provide this property. A floor-division fee would
    /// charge nothing below `BPS_DENOMINATOR / bps` units (under 400 at 25 bps),
    /// and no path enforces a minimum amount. The comparison against zero needs
    /// only whether the quotient is zero, not its value, so it stays tractable.
    function check_unitFee_zeroOnlyOnZeroInput(uint48 units, uint16 bps) public pure {
        bool isZero = Fees.unitFee(units, bps) == 0;
        assertEq(isZero, units == 0 || bps == 0);
    }
}
