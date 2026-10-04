// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Groth16 verifier interface (snarkjs codegen). Compressed public-input mode:
/// `input` is `[y, digest, z]`, with `y = p(z)` over the circuit's coefficients
/// and `digest` the circuit's Poseidon commitment to those coefficients. Shared
/// by the `4x6` and `tree_update_batch` verifiers.
interface IVerifier {
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[3] calldata input
    ) external view returns (bool);
}
