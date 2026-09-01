// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Fee constants shared by `FeeConfig`, which owns the accrual and the
/// treasury, and `AssetRegistry`, which owns the rates. Both validate against
/// the same ceiling and neither inherits the other, so the bound is declared
/// here. A library holds no storage, so referencing it moves no slot.
library Fees {
    /// Basis-points denominator. `fee = amount * bps / BPS_DENOMINATOR`.
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// Ceiling on any single rate (20%), on either leg. No path sets a rate
    /// above it.
    uint16 internal constant MAX_FEE_BPS = 2_000;

    /// Fee on a count of normalized units, rounded up.
    ///
    /// The plain path multiplies `scale` in before dividing, so it floors at
    /// base-unit granularity. A yield asset charges its fee in units, so that
    /// the escrow digest stays index-free, and one unit is worth `scale` base
    /// units; flooring there would discard up to a whole `scale` per operation
    /// and charge nothing below `BPS_DENOMINATOR / bps` units (at 25 bps, any
    /// amount under 400 units), with no minimum size on any path. Rounding up
    /// costs the payer at most one unit and closes that window at every `scale`.
    ///
    /// Shared because three sites must agree exactly or an escrow cannot be
    /// settled: the quote at submit, the accrual at flush, and the refund at
    /// cancel each recompute this from the same `(units, bps)`.
    ///
    /// `units` is bounded by `type(uint48).max` and `bps` by `MAX_FEE_BPS` at
    /// every call site, so the product cannot overflow.
    function unitFee(uint256 units, uint256 bps) internal pure returns (uint256) {
        uint256 num = units * bps;
        if (num == 0) return 0;
        return (num - 1) / BPS_DENOMINATOR + 1;
    }
}
