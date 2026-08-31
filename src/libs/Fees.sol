// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Fee constants shared by the two mixins that need them.
///
/// `FeeConfig` owns the accrual and the treasury; `AssetRegistry` owns the
/// rates themselves, packed into `AssetEntry`. Both must validate against the
/// same ceiling, and neither inherits the other — `MASP` composes them side by
/// side — so the bound lives here rather than being declared twice.
///
/// A library holds no storage, so referencing it from either mixin cannot move
/// a slot.
library Fees {
    /// Basis-points denominator. `fee = amount * bps / BPS_DENOMINATOR`.
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// Ceiling on any single rate (20%). Applies to every rate an asset can
    /// carry, on either leg; there is no path that sets one above it.
    uint16 internal constant MAX_FEE_BPS = 2_000;
}
