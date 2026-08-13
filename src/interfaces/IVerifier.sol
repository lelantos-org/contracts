// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// Groth16 verifier interface (snarkjs codegen). Compressed public-input mode:
/// only `(z, y)` with `y = p(z)` over the logical public inputs. Shared by the
/// `transact_3x3` and `tree_update_batch` verifiers.
interface IVerifier {
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[2] calldata input
    ) external view returns (bool);
}
