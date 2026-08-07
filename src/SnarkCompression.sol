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
        uint256 dataPtr;
        assembly ("memory-safe") {
            dataPtr := add(coefficients, 0x20)
        }
        return evaluatePolyAtRaw(dataPtr, coefficients.length, z);
    }

    /// Horner eval over `length` words of ascending-order coefficients laid
    /// out contiguously from `dataPtr`. Identical semantics to
    /// `evaluatePolyAt`, without the per-element bounds check — callers pass
    /// a region they own. Reverts `CoefficientOutOfField` if any word >= R.
    function evaluatePolyAtRaw(uint256 dataPtr, uint256 length, uint256 z) internal pure returns (uint256 y) {
        // Reverting in-place beats a flag + post-loop branch, and unrolling by
        // two halves the loop-control overhead — which dominates, since
        // MULMOD/ADDMOD are only 8 gas each. Both live coefficient vectors
        // (30 and 76) are even, so the scalar step below never runs on-chain.
        uint256 errSel = uint256(uint32(CoefficientOutOfField.selector)) << 224;
        assembly ("memory-safe") {
            let r := R
            let p := add(dataPtr, shl(5, length))
            // Odd length: fold the top coefficient on its own, then the
            // remaining span is a whole number of pairs.
            //
            // Skipping leading (highest-degree) zero coefficients would also
            // be exact — Horner starts at y = 0 and 0*z + 0 = 0 — but it
            // measured only ~220 gas on a real spend while costing gas on
            // dense batches, so the scan is not worth the extra branch.
            if and(length, 1) {
                p := sub(p, 0x20)
                let c := mload(p)
                if iszero(lt(c, r)) {
                    mstore(0x00, errSel)
                    revert(0x00, 0x04)
                }
                y := addmod(mulmod(y, z, r), c, r)
            }
            for { } gt(p, dataPtr) { } {
                p := sub(p, 0x40)
                let hi := mload(add(p, 0x20))
                let lo := mload(p)
                // Range-check both before either is folded in, so a bad
                // coefficient can never influence the result.
                if iszero(and(lt(hi, r), lt(lo, r))) {
                    mstore(0x00, errSel)
                    revert(0x00, 0x04)
                }
                y := addmod(mulmod(y, z, r), hi, r)
                y := addmod(mulmod(y, z, r), lo, r)
            }
        }
    }
}
