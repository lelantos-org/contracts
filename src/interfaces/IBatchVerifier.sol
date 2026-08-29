// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Batched Groth16 verifier for the `(4x6, tree_update_batch)` proof
/// pair a spend carries. Checks `E_1 * E_2^r2 = 1` in a single call to the BN254
/// pairing precompile, where `E_i` is the Groth16 residual of proof `i` and `r2`
/// is a Fiat-Shamir coefficient derived from the complete instance.
///
/// Slot 1 is `4x6`, slot 2 is `tree_update_batch`. The order is
/// significant: each slot is checked against its own `delta` and `IC`
/// constants, so transposed proofs are rejected.
///
/// INVARIANT: `pub1` and `pub2` MUST be derived from the request calldata by
/// `PubInputs.compress`, as `[y, z]` in that order. Public inputs supplied by
/// any other means break soundness, which rests on `z` being drawn after the
/// prover commits.
///
/// Every parameter is a static type, so the ABI lays the call out as a selector
/// followed by exactly twenty contiguous words. The implementation hashes that
/// region verbatim as its transcript and rejects any other calldata length:
/// over-long input by its own `calldatasize` pin, truncated input by solc's
/// dispatcher.
interface IBatchVerifier {
    /// Returns true when both proofs verify; false on a rejected proof, an
    /// out-of-field public input, a malformed point, or calldata longer than
    /// `4 + 20 * 32`.
    ///
    /// Two conditions revert instead of returning false, both fail-closed:
    ///
    ///   - Truncated calldata. Every parameter is static, so solc's dispatcher
    ///     validates the calldata size before the implementation's
    ///     `calldatasize` pin runs. Only over-long calldata reaches the pin.
    ///   - Insufficient gas for the precompiles. The implementation forwards
    ///     `gas()`, so a starved call fails the ECMUL or the pairing and the
    ///     failure bubbles up.
    ///
    /// CONTRACT: `false` means "not proven here", not "the prover misbehaved".
    /// A gas-starved call is indistinguishable from an invalid proof, so callers
    /// MUST NOT treat `false` as a slashing condition or gate a nullifier
    /// consumption, fee charge, or other state write on it. The only safe
    /// response is to revert, as `MASP._verifyProofs` does.
    function verifyBatch(
        uint256[2] calldata a1,
        uint256[2][2] calldata b1,
        uint256[2] calldata c1,
        uint256[2] calldata pub1,
        uint256[2] calldata a2,
        uint256[2][2] calldata b2,
        uint256[2] calldata c2,
        uint256[2] calldata pub2
    ) external view returns (bool);
}
