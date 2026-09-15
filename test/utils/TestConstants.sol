// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Shared test constants.
///
/// Suites keep a local constant where the value is part of what they test;
/// otherwise they use these, so identical values cannot drift apart.
///
/// Suites reference these through their own `internal constant` aliases rather
/// than by inheritance.
library TestConstants {
    /// The fixture asset id. The bundled proofs are generated against it, so it
    /// cannot be changed independently.
    uint64 internal constant ASSET_ID = 1;

    /// Chosen so `publicIn * SCALE * FEE_BPS / 10_000 != 0`: at the fixture's
    /// `publicIn = 100` the fee is 2.5e9 wei, so fee collection does not round
    /// to zero.
    uint256 internal constant SCALE = 1e10;

    /// 0.25%, under the 20% ceiling `Fees.MAX_FEE_BPS` enforces.
    uint16 internal constant FEE_BPS = 25;

    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);
    address internal constant RECIPIENT = address(0xF00D);
    /// A swap's intent-bound `refundTo`, distinct from every driver.
    address internal constant SWAP_REFUND_TO = address(0x4EF0);
}
