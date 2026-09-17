// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Governance-token and fee-burner values shared by `GovTestBase` and
/// `FeeBurnerTestBase`, so the two stacks cannot drift apart.
///
/// Suites reference these through their own `internal constant` aliases rather
/// than by inheritance, as with `TestConstants`. Suites that pin different
/// values on purpose (the Quint replay) keep their own.
library GovConstants {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    /// Auction decay curve the burner is deployed with.
    uint32 internal constant HALF_LIFE = 1 hours;
    uint8 internal constant MAX_HALVINGS = 12;
    uint16 internal constant RESTART_MULT_BPS = 20_000;

    /// All GOV paid into auctions is burned; none goes to a secondary treasury.
    uint16 internal constant BURN_BPS = 10_000;
}
