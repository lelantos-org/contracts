// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Polynomial evaluation for SNARK public-input compression. Folds N Groth16
/// public inputs into two, `z` and `y = p(z)`.
///
/// The Schwartz-Zippel bound ("cheating succeeds with probability at most
/// `deg(p) / R`") requires the coefficient vector fixed before `z` is drawn.
/// That does not hold here: `z` is derived from calldata the prover authored,
/// so the prover reads it before choosing a witness. The compression is binding
/// because the circuit pins every coefficient it evaluates, leaving the prover
/// no free variable to solve `p(z) = y` with. `PubInputs` establishes that; see
/// its `compress` overloads.
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
    function evaluatePolyAtRaw(uint256 dataPtr, uint256 length, uint256 z) internal pure returns (uint256) {
        return evaluatePolyAtRawFrom(dataPtr, length, z, 0);
    }

    /// `evaluatePolyAtRaw` seeded with a running accumulator, which lets one
    /// polynomial be evaluated over two disjoint memory runs without copying
    /// them together. Horner folds from the top coefficient down, so evaluating
    /// the high run first and passing its accumulator here as `acc` yields the
    /// evaluation over the concatenation, high run above low.
    ///
    /// No caller passes a non-zero `acc`: the `PubInputs.Transact` coefficients
    /// form one contiguous prefix, and `evaluatePolyAtRaw` seeds it with 0. The
    /// seeded form supports a coefficient layout split into non-adjacent runs.
    function evaluatePolyAtRawFrom(uint256 dataPtr, uint256 length, uint256 z, uint256 acc)
        internal
        pure
        returns (uint256 y)
    {
        y = acc;
        // MULMOD and ADDMOD cost 8 gas each, so loop control dominates: the
        // body is unrolled by two and the field check reverts in place. Every
        // length the pool passes is even (46 for `4x6`, 52 for
        // `tree_update_batch`), so the odd-length prologue below is unused on
        // those paths. The entry point is generic, and without the prologue an
        // odd-length run would read the word before `dataPtr`.
        uint256 errSel = uint256(uint32(CoefficientOutOfField.selector)) << 224;
        assembly ("memory-safe") {
            let r := R
            let p := add(dataPtr, shl(5, length))
            // Odd length: fold the top coefficient alone so the remaining span
            // is a whole number of pairs.
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
                // out-of-field coefficient cannot reach the result.
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
