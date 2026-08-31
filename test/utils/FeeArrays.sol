// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Uniform per-leg fee arrays for a genesis asset set of `n`.
///
/// Rates are per asset and per leg on chain. Fixtures rarely need them to
/// differ, so this keeps the constructor calls readable without pretending a
/// pool-wide rate still exists — a test that cares builds the arrays itself.
function uniformBps(uint256 n, uint16 bps) pure returns (uint16[] memory a) {
    a = new uint16[](n);
    for (uint256 i; i < n; ++i) {
        a[i] = bps;
    }
}
