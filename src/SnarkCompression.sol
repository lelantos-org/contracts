// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Polynomial evaluation for SNARK public-input compression. Folds N Groth16
/// public inputs into two, `z` and `y = p(z)`.
///
/// The usual Schwartz-Zippel reading — "cheating succeeds with probability at
/// most `deg(p) / R`" — needs the coefficient vector fixed *before* `z` is
/// drawn. It is not: `z` is a circuit input the prover reads before choosing a
/// witness, because it is derived from calldata the prover authored. What makes
/// the compression binding is that the circuit pins every coefficient it
/// evaluates, so the prover has no free variable to solve `p(z) = y` with.
/// `PubInputs` is where that holds or fails; see its `compress` overloads.
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

    /// `evaluatePolyAtRaw` seeded with a running accumulator, which is what lets
    /// one polynomial be evaluated over two disjoint memory runs without copying
    /// them together. Horner folds from the top coefficient down, so evaluating
    /// the high run first and passing its accumulator here as `acc` yields
    /// exactly the evaluation over the concatenation, high run above low.
    ///
    /// Written for `PubInputs.compress(Transact, aux)`, whose coefficients were
    /// two pinned spans of the calldata block split by the four address words.
    /// `PubInputs.Transact` has since been reordered to put those four last, so
    /// the coefficients are one contiguous prefix and no caller passes a non-zero
    /// `acc` today — `evaluatePolyAtRaw` above seeds it with 0. The seam is kept
    /// because a demotion that is not a suffix would need it back.
    function evaluatePolyAtRawFrom(uint256 dataPtr, uint256 length, uint256 z, uint256 acc)
        internal
        pure
        returns (uint256 y)
    {
        y = acc;
        // MULMOD and ADDMOD cost 8 gas each, so loop control dominates: the
        // body is unrolled by two and the field check reverts in place. Every
        // length the pool passes is even — 46 for `4x6` and 52 for
        // `tree_update_batch` — so the odd-length prologue below is dead on those
        // paths. It is kept because the entry point is generic and
        // a run of odd length would otherwise read past `dataPtr`.
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
