// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// Polynomial evaluation for SNARK public-input compression. Folds N Groth16
/// PIs into 2 (`z`, `y = p(z)`). Soundness by Schwartz-Zippel: with `z` drawn
/// (Fiat-Shamir) after the prover commits, cheating succeeds with prob
/// ≤ `deg(p) / R`.
library SnarkCompression {
    /// BN254 scalar field order (matches `Groth16Verifier.r`).
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// Coefficient `>= R`.
    error CoefficientOutOfField();

    /// Horner eval of `coefficients` at `z` mod R. Ascending order.
    function evaluatePolyAt(uint256[] memory coefficients, uint256 z) internal pure returns (uint256) {
        uint256 length = coefficients.length;
        uint256 y = 0;
        for (uint256 i = length; i > 0;) {
            uint256 c = coefficients[i - 1];
            // Range check before modular arithmetic.
            if (c >= R) revert CoefficientOutOfField();
            y = addmod(mulmod(y, z, R), c, R);
            unchecked {
                --i;
            }
        }
        return y;
    }
}
