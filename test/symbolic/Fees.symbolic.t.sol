// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Fees } from "../../src/libs/Fees.sol";

/// Symbolic proofs for `Fees.unitFee`, the rounded-up unit fee.
///
/// Three sites must agree exactly on this number or an escrow cannot be
/// settled: the quote at submit, the accrual at flush and the refund at cancel.
/// Both proofs below run over the full call-site domain — `units` up to
/// `type(uint48).max`, which is the bound `Fees` documents and the escrow record
/// enforces, and any `uint16` rate.
///
/// Deliberately narrow. `unitFee` divides `units * bps` by a constant, and any
/// property that makes the solver reason *about* that division rather than
/// carry it symbolically is intractable: asserting `fee <= units`, or
/// monotonicity in either argument, or the `fee * D` bracketing form of the
/// rounding rule, each times out at 120s on both bundled solvers, and stays
/// timed out when the arguments are narrowed to uint32, uint24 or even uint16 —
/// halmos words are 256-bit whatever the Solidity type, so the division is the
/// blocker, not the range. Those are all corollaries of the characterization
/// proved here, and `test/fuzz/FeeConfig.fuzz.t.sol` samples them directly.
contract FeesSymbolicTest is GuardAsserts {
    /// `unitFee` is exactly ceiling division of `units * bps` by the
    /// basis-point denominator, for every input in the call-site domain.
    ///
    /// This is the whole specification of the function: the bound
    /// `fee <= units` for `bps <= BPS_DENOMINATOR`, monotonicity in either
    /// argument, and the at-most-one-unit rounding cost all follow from it as
    /// arithmetic, with no further reasoning about `unitFee` itself.
    ///
    /// It is cheap for the solver precisely because it never has to evaluate
    /// the division: both sides reduce to the same symbolic quotient, so the
    /// query is a syntactic equality. What it buys is regression cover on a
    /// hand-rolled form — `(num - 1) / D + 1` guarded by a zero check — against
    /// OpenZeppelin's audited reference. A future edit to the more obvious
    /// `(num + D - 1) / D`, which overflows near `type(uint256).max`, or one
    /// that drops the zero guard and reverts on an underflow, fails here.
    function check_unitFee_isCeilDiv(uint48 units, uint16 bps) public pure {
        uint256 num = uint256(units) * uint256(bps);
        assertEq(Fees.unitFee(units, bps), Math.ceilDiv(num, Fees.BPS_DENOMINATOR));
    }

    /// The fee is zero only when the base or the rate is zero — never for a
    /// non-zero charge on a non-zero amount.
    ///
    /// This is the property rounding up exists to provide, and the one a
    /// reference comparison would not catch on its own: flooring is also a
    /// faithful implementation of a fee, it just charges nothing below
    /// `BPS_DENOMINATOR / bps` units (at 25 bps, any amount under 400), and no
    /// path imposes a minimum size. Cheap for the same reason as above — a
    /// comparison against zero needs the sign of the quotient, not its value.
    function check_unitFee_zeroOnlyOnZeroInput(uint48 units, uint16 bps) public pure {
        bool isZero = Fees.unitFee(units, bps) == 0;
        assertEq(isZero, units == 0 || bps == 0);
    }
}
