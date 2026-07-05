// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// Groth16 verifier interface (snarkjs codegen). Compressed PI mode: only
/// `(z, y)` with `y = p(z)` over the logical PIs. Shared by the transact_2x2
/// and tree_update verifiers.
interface IVerifier {
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[2] calldata input
    ) external view returns (bool);
}
