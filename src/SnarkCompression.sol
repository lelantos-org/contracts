// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// Polynomial evaluation for SNARK public-input compression. Folds N Groth16
/// public inputs into two, `z` and `y = p(z)`. Soundness follows from
/// Schwartz-Zippel: with `z` drawn by Fiat-Shamir after the prover commits,
/// cheating succeeds with probability at most `deg(p) / R`.
library SnarkCompression {
    /// BN254 scalar field order (matches `Groth16Verifier.r`).
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// A coefficient is `>= R`.
    error CoefficientOutOfField();

    /// Horner evaluation of `coefficients` at `z` mod R, ascending order.
    function evaluatePolyAt(uint256[] memory coefficients, uint256 z) internal pure returns (uint256) {
        uint256 dataPtr;
        assembly ("memory-safe") {
            dataPtr := add(coefficients, 0x20)
        }
        return evaluatePolyAtRaw(dataPtr, coefficients.length, z);
    }

    /// Horner evaluation over `length` words of ascending-order coefficients
    /// laid out contiguously from `dataPtr`. Semantics match `evaluatePolyAt`
    /// without the per-element bounds check; the caller owns the region.
    /// Reverts `CoefficientOutOfField` if any word is `>= R`.
    function evaluatePolyAtRaw(uint256 dataPtr, uint256 length, uint256 z) internal pure returns (uint256 y) {
        // Loop control dominates, since MULMOD and ADDMOD are 8 gas each, so the
        // body is unrolled by two and the field check reverts in place rather
        // than setting a flag for a post-loop branch. Both on-chain coefficient
        // vectors (42 and 52) are even.
        uint256 errSel = uint256(uint32(CoefficientOutOfField.selector)) << 224;
        assembly ("memory-safe") {
            let r := R
            let p := add(dataPtr, shl(5, length))
            // Odd length: fold the top coefficient on its own so the remaining
            // span is a whole number of pairs.
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
                // Both are range-checked before either is folded in, so an
                // out-of-field coefficient cannot influence the result.
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
