// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Values the test suite agrees on, in one place.
///
/// These were declared independently in a couple of dozen files — `SCALE` in
/// 22, `FEE_BPS` in 20, `ASSET_ID` and `TREASURY` in 16 each — always with the
/// same value. Suites are free to keep a local constant where the value is part
/// of what they are testing; several deliberately do, and say so. What this
/// removes is the copies that were identical by accident and would have drifted
/// apart silently.
///
/// Suites reference these through their own `internal constant` aliases rather
/// than by inheriting, so every existing call site keeps working and the
/// per-file diff is one line per constant.
library TestConstants {
    /// The fixture asset id. The bundled proofs are generated against it, so it
    /// is not freely choosable.
    uint64 internal constant ASSET_ID = 1;

    /// Chosen so `publicIn * SCALE * FEE_BPS / 10_000 != 0` — at the fixture's
    /// `publicIn = 100` the fee is 2.5e9 wei, which keeps the fee-collection
    /// branch live rather than rounding away.
    uint256 internal constant SCALE = 1e10;

    /// 0.25%, comfortably under the 20% ceiling `Fees.MAX_FEE_BPS` enforces.
    uint16 internal constant FEE_BPS = 25;

    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);
    address internal constant RECIPIENT = address(0xF00D);
}
