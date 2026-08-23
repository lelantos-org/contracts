// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Batched Groth16 verifier for the `(transact_3x3, tree_update_batch)` proof
/// pair a spend carries. Checks `E_1 * E_2^r2 = 1` in a single call to the BN254
/// pairing precompile, where `E_i` is the Groth16 residual of proof `i` and `r2`
/// is a Fiat-Shamir coefficient derived from the complete instance.
///
/// Slot 1 is `transact_3x3`, slot 2 is `tree_update_batch`. **The order is
/// load-bearing**: each slot is checked against its own `delta` and `IC`
/// constants, so passing the proofs the other way round rejects.
///
/// INVARIANT: `pub1` and `pub2` MUST be computed by the caller via
/// `PubInputs.compress`, as `[y, z]` in that order. Accepting caller-supplied
/// public inputs that were not derived from the request calldata breaks
/// soundness completely — the whole Fiat-Shamir compression rests on `z` being
/// drawn after the prover commits.
///
/// Every parameter is a static type, so the ABI lays the call out as a selector
/// followed by exactly twenty contiguous words. The implementation hashes that
/// region verbatim as its transcript and rejects any other calldata length —
/// over-long by its own `calldatasize` pin, truncated by solc's dispatcher.
interface IBatchVerifier {
    /// Returns true iff both proofs verify. Returns false on a rejected proof,
    /// an out-of-field public input, a malformed point, or calldata *longer*
    /// than `4 + 20 * 32`.
    ///
    /// Two ways a call can revert instead of returning false, both fail-closed:
    ///
    ///   - Truncated calldata. Every parameter is static, so solc's dispatcher
    ///     validates the calldata size and reverts before the implementation's
    ///     `calldatasize` pin ever runs. Only over-long calldata reaches the pin
    ///     and returns false.
    ///   - Not enough gas for the precompiles. The implementation forwards
    ///     `gas()`, so a starved call fails the ECMUL or the pairing and the
    ///     rejection propagates as a bubbled failure rather than a bool.
    ///
    /// CONTRACT: `false` means "not proven here", NOT "the prover misbehaved".
    /// A gas-starved call is indistinguishable from an invalid proof, so callers
    /// MUST NOT make a `false` return a slashing condition, a nullifier
    /// consumption, or any other fee-charging or state-writing branch. The only
    /// safe response is to revert, as `MASP._verifyProofs` does.
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
