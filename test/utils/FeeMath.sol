// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Expected amounts for the pool's percentage fees, as tests restate them.
///
/// Deliberately a restatement rather than a call into `Fees`: a test that
/// derived its expectation from the code under test could not catch a change to
/// it. Rounds down, as the pool does.
library FeeMath {
    uint256 internal constant BPS = 10_000;

    /// The fee on `amount` at `bps`.
    function fee(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / BPS;
    }

    /// What a payer is charged to deposit `units` at `scale`: the principal
    /// plus the treasury's deposit fee on it.
    function gross(uint256 units, uint256 scale, uint256 bps) internal pure returns (uint256) {
        uint256 amount = units * scale;
        return amount + fee(amount, bps);
    }
}
