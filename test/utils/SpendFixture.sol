// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BabyJubJub } from "../../src/BabyJubJub.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

// Width of the aux array the transact path takes.
//
// Mirrors `PubInputs.TRANSACT_OUT`, which cannot be used as an array length
// from another file: Solidity rejects a library's `internal constant` there.
// `SpendFixtureWidthTest` pins the two together, and pins both against the
// `Output[6]` in `AuxValidation.validate`, so a shape change that misses one
// of them fails as an assertion rather than as a silently short aux array.
uint256 constant SPEND_OUTPUTS = 6;

/// Scaffolding every MASP spend test needs before it can assert on anything.
///
/// The three pieces below are not free parameters. `MASP._spend` requires
/// `tpi.actualCount == TRANSACT_OUT`, `tpi.cms[k] == pi.outCm[k]` for every
/// `k`, and an aux payload in every slot that passes `AuxValidation`. Restating
/// those rules in each test file meant a change to the transact shape had to be
/// re-applied by hand in all of them, and a slot missed in one showed up as a
/// `BatchMisaligned` or `CiphertextTooShort` several layers from the edit that
/// caused it.
///
/// Everything here is sized from `PubInputs.TRANSACT_OUT` / `.length` rather
/// than a literal, so the shape is stated once and a future arity change is a
/// single edit in `PubInputs.sol`.
///
/// What is *not* here: `merkleRoot`, the public amounts, and the party
/// addresses. Those differ per test because they are usually the thing under
/// test, so callers still set them explicitly.
library SpendFixture {
    /// Fill `nullifier` and `outCm` with consecutive values from each seed.
    ///
    /// Nullifiers must be pairwise distinct or `MASP` rejects the spend with
    /// `DuplicateNullifier`; consecutive values from one seed guarantee that
    /// for any width. The seeds stay caller-supplied so a test that wants
    /// recognisable values in a trace can still choose them — only the *count*
    /// is derived.
    function fillOutputs(PubInputs.Transact memory pi, uint256 nullifierSeed, uint256 outCmSeed) internal pure {
        fillNullifiers(pi, nullifierSeed);
        fillCommitments(pi, outCmSeed);
    }

    /// `fillOutputs`, one array at a time. A test whose subject *is* the
    /// nullifiers (the double-spend fuzz, say) sets those itself and uses
    /// `fillCommitments` for the half it does not care about.
    function fillNullifiers(PubInputs.Transact memory pi, uint256 seed) internal pure {
        for (uint256 k; k < pi.nullifier.length; ++k) {
            pi.nullifier[k] = bytes32(seed + k);
        }
    }

    function fillCommitments(PubInputs.Transact memory pi, uint256 seed) internal pure {
        for (uint256 k; k < pi.outCm.length; ++k) {
            pi.outCm[k] = bytes32(seed + k);
        }
    }

    /// The tree-update batch a spend's `pi` must be paired with.
    ///
    /// `actualCount` and `cms` are deliberately not parameters: MASP pins both
    /// to the spend's outputs, so anything else is a test bug rather than a
    /// case worth expressing. The remaining batch fields stay zero — a spend's
    /// `outCvDep` defaults to zero too, and `isDeposit == 0` marks a spend leaf.
    function batchFor(PubInputs.Transact memory pi, bytes32 oldRoot, bytes32 newRoot, uint64 startIndex)
        internal
        pure
        returns (PubInputs.TreeUpdateBatch memory tpi)
    {
        tpi.oldRoot = oldRoot;
        tpi.newRoot = newRoot;
        tpi.startIndex = startIndex;
        tpi.actualCount = uint64(pi.outCm.length);
        for (uint256 k; k < pi.outCm.length; ++k) {
            tpi.cms[k] = pi.outCm[k];
        }
    }

    /// One aux payload per output, each carrying `ciphertext` and a clue and
    /// ephemeral point that are on-curve and in the prime-order subgroup — the
    /// checks `AuxValidation.validate` runs. Use it for any test whose subject
    /// is not the aux payload itself.
    function uniformAux(bytes memory ciphertext)
        internal
        pure
        returns (AuxValidation.Output[SPEND_OUTPUTS] memory aux)
    {
        for (uint256 k; k < aux.length; ++k) {
            aux[k].clueRx = BabyJubJub.BASE8_X;
            aux[k].clueRy = BabyJubJub.BASE8_Y;
            aux[k].ephPubX = BabyJubJub.BASE8_X;
            aux[k].ephPubY = BabyJubJub.BASE8_Y;
            aux[k].ciphertext = ciphertext;
        }
    }

    /// The minimal well-formed payload: a 2-byte clue-bits prefix and no body.
    /// `0x0001` sits inside `CLUE_BITS_MASK`, so it passes the prefix check,
    /// and the length is exactly `MIN_CIPHERTEXT_LEN`.
    function validAux() internal pure returns (AuxValidation.Output[SPEND_OUTPUTS] memory) {
        return uniformAux(hex"0001");
    }
}
