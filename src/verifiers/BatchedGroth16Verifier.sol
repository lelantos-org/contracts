// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IBatchVerifier } from "../interfaces/IBatchVerifier.sol";
import {
    SNARK_R,
    SNARK_Q,
    VK_ALPHA_X,
    VK_ALPHA_Y,
    VK_BETA_X1,
    VK_BETA_X2,
    VK_BETA_Y1,
    VK_BETA_Y2,
    VK_GAMMA_X1,
    VK_GAMMA_X2,
    VK_GAMMA_Y1,
    VK_GAMMA_Y2,
    VK1_DELTA_X1,
    VK1_DELTA_X2,
    VK1_DELTA_Y1,
    VK1_DELTA_Y2,
    VK1_IC0X,
    VK1_IC0Y,
    VK1_IC1X,
    VK1_IC1Y,
    VK1_IC2X,
    VK1_IC2Y,
    VK2_DELTA_X1,
    VK2_DELTA_X2,
    VK2_DELTA_Y1,
    VK2_DELTA_Y2,
    VK2_IC0X,
    VK2_IC0Y,
    VK2_IC1X,
    VK2_IC1Y,
    VK2_IC2X,
    VK2_IC2Y,
    BATCH_DOMAIN
} from "./VerifyingKeys.sol";

/// Verifies a `transact_4x4` proof and a `tree_update_batch` proof together in
/// one call to the BN254 pairing precompile.
///
/// # What it checks
///
/// Write the Groth16 residual of proof `i` against verifying key
/// `(alpha, beta, gamma, delta_i, IC_i)` as
///
///     E_i := e(-A_i, B_i) * e(alpha, beta) * e(PI_i, gamma) * e(C_i, delta_i)
///
/// so that proof `i` is valid exactly when `E_i = 1`. Since the two circuits
/// share `beta` and `gamma` as group elements (see `VerifyingKeys.sol`),
/// bilinearity in the first argument regroups the product `E_1 * E_2^r2` into
/// six pairings:
///
///     e(-A_1, B_1) * e(-r2*A_2, B_2)
///   * e((1 + r2)*alpha, beta)
///   * e(PI_1 + r2*PI_2, gamma)
///   * e(C_1, delta_1) * e(r2*C_2, delta_2)   ==  1
///
/// This is an unconditional algebraic identity, not an approximation: the two
/// `C` terms stay separate because `delta_1 != delta_2`, so `E_1` and `E_2`
/// remain independently well defined. Writing `E_i = g^{e_i}` in the order-`r`
/// subgroup of `G_T` — which is where the precompile's final exponentiation
/// lands — the check above is exactly `e_1 + r2*e_2 == 0 (mod SNARK_R)`.
///
/// With `r2` drawn from `[1, SNARK_R - 1]` after `(e_1, e_2)` are fixed: if
/// `e_2 != 0` exactly one value of `r2` is bad, and if `e_2 == 0` the check
/// collapses to `e_1 == 0`. Soundness error is therefore at most
/// `1 / (SNARK_R - 1)`, about `2^-254`. This is the Bellare-Garay-Rabin
/// small-exponents test; `r1` is fixed to 1 because the requirement is only that
/// the linear form be unpredictable with no zero coefficient.
///
/// # Transcript
///
/// `e_i` is determined by `(A_i, B_i, C_i, PI_i)`, and `PI_i` by `(y_i, z_i)`.
/// The transcript is therefore `BATCH_DOMAIN` followed by all twenty calldata
/// words, and `calldatasize` is pinned so no trailing bytes can be appended:
/// without that, a relayer could resample `r2` for a fixed instance. Omitting
/// any of the twenty words would leave a grinding target.
///
/// # Failure modes
///
/// Nearly every implementation error here is fail-closed — a wrong `IC` pairing,
/// a swapped `y`/`z`, a wrong constant block, an off-by-one memory offset, or a
/// drifted `alpha`/`beta`/`gamma` all reject valid proofs. The fail-*open* set is
/// small and fully enumerable:
///
///   1. an unchecked `staticcall` success flag, which would let a stale output
///      buffer stand in for a rejected point — every flag below is checked;
///   2. a transcript not covering all twenty words;
///   3. `r2 == 0`, which would leave proof 2 entirely unchecked — excluded by
///      construction, see `_deriveR2`'s `+ 1`;
///   4. a wrong length passed to the pairing precompile.
///
/// Point validation is delegated to the precompiles, exactly as the snarkjs
/// codegen does. `ECMUL`/`ECADD` reject G1 points that are off-curve or have a
/// coordinate `>= SNARK_Q`, and BN254 G1 has cofactor 1 so on-curve implies
/// correct subgroup. The pairing precompile additionally checks each G2 point for
/// order-`r` subgroup membership, which is mandatory because G2 has a large
/// cofactor. Batching routes `A_2` and `C_2` through `ECMUL` before pairing, so
/// they get strictly more validation than in the unbatched path.
contract BatchedGroth16Verifier is IBatchVerifier {
    // Calldata offsets, from the start of `msg.data`. Every parameter is static,
    // so the twenty words sit contiguously after the 4-byte selector:
    //
    //   0x004  a1   (2)      0x144  a2   (2)
    //   0x044  b1   (4)      0x184  b2   (4)
    //   0x0c4  c1   (2)      0x204  c2   (2)
    //   0x104  pub1 (2)      0x244  pub2 (2)
    //
    // `pub[0]` is `y` (the Horner evaluation) and `pub[1]` is `z` (the
    // challenge), matching `PubInputs._finalizeRaw` and hence the codegen's
    // `IC1 * pubSignals[0] + IC2 * pubSignals[1]`.
    uint256 private constant CD_LEN = 644;
    uint256 private constant CD_BODY = 640;

    /// @inheritdoc IBatchVerifier
    function verifyBatch(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[2] calldata,
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[2] calldata
    ) external view returns (bool) {
        assembly ("memory-safe") {
            // Scratch layout, allocated once from the free pointer:
            //
            //   PAIR  1152 B  the 6 x 192-byte pairing precompile input
            //   SCR    128 B  ECMUL/ECADD staging (96 B in, 64 B out, 128 B for
            //                 the ECADD that follows an ECMUL in place)
            //   ACC1    64 B  PI_1, then PI_1 + r2*PI_2
            //   ACC2    64 B  PI_2
            //   HASH   672 B  BATCH_DOMAIN || the twenty calldata words
            let base := mload(0x40)
            mstore(0x40, add(base, 0x820))
            let pair := base
            let scr := add(base, 0x480)
            let acc1 := add(base, 0x500)
            let acc2 := add(base, 0x540)
            let hash := add(base, 0x580)

            // Return false and stop, matching the codegen's fail-closed
            // behaviour. The caller is responsible for turning this into a
            // revert with whatever error it wants to surface.
            function reject() {
                mstore(0x00, 0)
                return(0x00, 0x20)
            }

            // dst := s * (x, y). `dst` must not alias `s`crAtch.
            function g1Mul(x, y, s, dst, scratch) {
                mstore(scratch, x)
                mstore(add(scratch, 0x20), y)
                mstore(add(scratch, 0x40), s)
                if iszero(staticcall(gas(), 7, scratch, 0x60, dst, 0x40)) { reject() }
            }

            // acc := acc + s * (x, y). Structurally identical to the codegen's
            // `g1_mulAccC` so the two can be diffed line for line.
            function g1MulAcc(x, y, s, acc, scratch) {
                mstore(scratch, x)
                mstore(add(scratch, 0x20), y)
                mstore(add(scratch, 0x40), s)
                if iszero(staticcall(gas(), 7, scratch, 0x60, scratch, 0x40)) { reject() }
                mstore(add(scratch, 0x40), mload(acc))
                mstore(add(scratch, 0x60), mload(add(acc, 0x20)))
                if iszero(staticcall(gas(), 6, scratch, 0x80, acc, 0x40)) { reject() }
            }

            // ---------------------------------------------------------------
            // 1. Pin the calldata length.
            //
            // The transcript is the calldata body verbatim. Without this check a
            // caller could append arbitrary trailing bytes and resample `r2` for
            // an otherwise fixed instance. Each resample still costs a ~2^254
            // search, so this is not closing an attack — it removes the sampling
            // oracle outright, and it costs 3 gas.
            // ---------------------------------------------------------------
            if iszero(eq(calldatasize(), CD_LEN)) { reject() }

            // ---------------------------------------------------------------
            // 2. Range checks.
            // ---------------------------------------------------------------
            let y1 := calldataload(0x104)
            let z1 := calldataload(0x124)
            let y2 := calldataload(0x244)
            let z2 := calldataload(0x264)

            // Public inputs must be in the scalar field, as `checkField` in the
            // codegen requires.
            if iszero(and(lt(y1, SNARK_R), lt(z1, SNARK_R))) { reject() }
            if iszero(and(lt(y2, SNARK_R), lt(z2, SNARK_R))) { reject() }

            // `a1.y` is the one word that reaches no precompile unreduced: it is
            // negated below, and `mod(sub(q, v), q)` maps both `v` and `v + q` to
            // the same point, so two encodings of one instance would hash to two
            // different transcripts. Harmless at this scale — a couple of free
            // resamples against a 2^254 search — but pinning it makes the
            // transcript a strict function of the instance. Every other
            // coordinate is rejected unreduced by ECMUL or by the pairing
            // precompile.
            let a1y := calldataload(0x24)
            if iszero(lt(a1y, SNARK_Q)) { reject() }

            // ---------------------------------------------------------------
            // 3. Derive the batching coefficient.
            //
            // `mod(h, SNARK_R - 1) + 1` lands in [1, SNARK_R - 1], excluding 0
            // by arithmetic rather than by a branch. `r2 == 0` would degenerate
            // the check to `e_1 == 0` and leave proof 2 unverified, so it is the
            // one value that must not occur.
            //
            // The reduction is very slightly non-uniform (`2^256 mod
            // (SNARK_R - 1)`), which shifts the soundness bound by about 2^-252.
            //
            // `r2` is deliberately full width. BN254 ECMUL costs a flat 6000 gas
            // regardless of scalar size, so a short exponent would save nothing
            // and give up ~126 bits of margin.
            // ---------------------------------------------------------------
            mstore(hash, BATCH_DOMAIN)
            calldatacopy(add(hash, 0x20), 0x04, CD_BODY)
            let r2 := add(mod(keccak256(hash, 0x2a0), sub(SNARK_R, 1)), 1)

            // ---------------------------------------------------------------
            // 4. Public-input commitments.
            //
            //   PI_i = IC0_i + y_i * IC1_i + z_i * IC2_i
            //
            // These two blocks are the only place the per-circuit IC constants
            // appear. They are kept textually parallel on purpose.
            // ---------------------------------------------------------------

            // transact_4x4
            mstore(acc1, VK1_IC0X)
            mstore(add(acc1, 0x20), VK1_IC0Y)
            g1MulAcc(VK1_IC1X, VK1_IC1Y, y1, acc1, scr)
            g1MulAcc(VK1_IC2X, VK1_IC2Y, z1, acc1, scr)

            // tree_update_batch
            mstore(acc2, VK2_IC0X)
            mstore(add(acc2, 0x20), VK2_IC0Y)
            g1MulAcc(VK2_IC1X, VK2_IC1Y, y2, acc2, scr)
            g1MulAcc(VK2_IC2X, VK2_IC2Y, z2, acc2, scr)

            // acc1 := PI_1 + r2 * PI_2
            g1MulAcc(mload(acc2), mload(add(acc2, 0x20)), r2, acc1, scr)

            // ---------------------------------------------------------------
            // 5. Assemble the six pairs.
            // ---------------------------------------------------------------

            // Pair 0 — (-A_1, B_1). r1 is 1, so A_1 and C_1 are used verbatim.
            // The negation must stay `mod(sub(q, v), q)`: plain `q - v` would
            // send `(x, 0)` to `(x, q)`, which the precompile rejects.
            mstore(pair, calldataload(0x04))
            mstore(add(pair, 0x20), mod(sub(SNARK_Q, a1y), SNARK_Q))
            calldatacopy(add(pair, 0x40), 0x44, 0x80)

            // Pair 1 — (-(r2 * A_2), B_2). Multiply first, then negate: the
            // ECMUL is what validates the submitted `A_2`, and it leaves a
            // canonical `y`, so negating its output is exact. If `A_2` is the
            // point at infinity the product is `(0, 0)` and `mod(sub(q, 0), q)`
            // preserves it.
            //
            // This order is load-bearing, and it is the reason `a2.y` needs no
            // counterpart to the `a1.y` range check above: the raw `a2.y` never
            // reaches an arithmetic op, so an unreduced encoding is rejected by
            // ECMUL rather than folded to a canonical point. Swapping the two
            // lines — negating the calldata `y` and then multiplying — would
            // make two encodings of one instance hash to two transcripts and
            // hand a prover free `r2` resamples. Add the `lt(a2y, SNARK_Q)`
            // check before ever reordering this.
            g1Mul(calldataload(0x144), calldataload(0x164), r2, add(pair, 0xc0), scr)
            mstore(add(pair, 0xe0), mod(sub(SNARK_Q, mload(add(pair, 0xe0))), SNARK_Q))
            calldatacopy(add(pair, 0x100), 0x184, 0x80)

            // Pair 2 — ((1 + r2) * alpha, beta), the two shared alpha/beta terms
            // folded into one. When `r2 == SNARK_R - 1` the scalar is 0 and this
            // becomes the point at infinity; that is correct, not degenerate,
            // because the regrouping identity holds unconditionally.
            g1Mul(VK_ALPHA_X, VK_ALPHA_Y, addmod(1, r2, SNARK_R), add(pair, 0x180), scr)
            mstore(add(pair, 0x1c0), VK_BETA_X1)
            mstore(add(pair, 0x1e0), VK_BETA_X2)
            mstore(add(pair, 0x200), VK_BETA_Y1)
            mstore(add(pair, 0x220), VK_BETA_Y2)

            // Pair 3 — (PI_1 + r2 * PI_2, gamma), the two shared gamma terms
            // folded into one.
            mstore(add(pair, 0x240), mload(acc1))
            mstore(add(pair, 0x260), mload(add(acc1, 0x20)))
            mstore(add(pair, 0x280), VK_GAMMA_X1)
            mstore(add(pair, 0x2a0), VK_GAMMA_X2)
            mstore(add(pair, 0x2c0), VK_GAMMA_Y1)
            mstore(add(pair, 0x2e0), VK_GAMMA_Y2)

            // Pair 4 — (C_1, delta_1).
            calldatacopy(add(pair, 0x300), 0xc4, 0x40)
            mstore(add(pair, 0x340), VK1_DELTA_X1)
            mstore(add(pair, 0x360), VK1_DELTA_X2)
            mstore(add(pair, 0x380), VK1_DELTA_Y1)
            mstore(add(pair, 0x3a0), VK1_DELTA_Y2)

            // Pair 5 — (r2 * C_2, delta_2). Distinct deltas are exactly why the
            // C terms cannot fold and the batch is six pairs rather than five.
            g1Mul(calldataload(0x204), calldataload(0x224), r2, add(pair, 0x3c0), scr)
            mstore(add(pair, 0x400), VK2_DELTA_X1)
            mstore(add(pair, 0x420), VK2_DELTA_X2)
            mstore(add(pair, 0x440), VK2_DELTA_Y1)
            mstore(add(pair, 0x460), VK2_DELTA_Y2)

            // ---------------------------------------------------------------
            // 6. One pairing check over all six pairs.
            // ---------------------------------------------------------------
            let ok := staticcall(gas(), 8, pair, 0x480, pair, 0x20)
            mstore(0x00, and(ok, mload(pair)))
            return(0x00, 0x20)
        }
    }
}
