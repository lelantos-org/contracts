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
// of them fails as an assertion rather than as a short aux array.
uint256 constant SPEND_OUTPUTS = 6;

/// Common scaffolding for MASP spend tests.
///
/// These values are constrained: `MASP` requires pairwise-distinct nullifiers,
/// a tree position at `committedCount` with the anchor's ring slot, and an aux
/// payload in every slot that passes `AuxValidation`. Centralising them means a
/// change to the transact shape is applied once, instead of surfacing as
/// `BatchMisaligned` or `CiphertextTooShort` in every test file that restates
/// the rules.
///
/// Everything here is sized from `PubInputs.TRANSACT_OUT` / `.length` rather
/// than a literal, so an arity change is a single edit in `PubInputs.sol`.
///
/// Not covered: `merkleRoot`, the public amounts, and the party addresses.
/// These are usually the subject of a test, so callers set them explicitly.
library SpendFixture {
    /// Fills `nullifier` and `outCm` with consecutive values from each seed.
    ///
    /// Nullifiers must be pairwise distinct or `MASP` rejects the spend with
    /// `DuplicateNullifier`; consecutive values from one seed guarantee that
    /// for any width. The seeds are caller-supplied so values are recognisable
    /// in a trace; only the count is derived.
    function fillOutputs(PubInputs.Transact memory pi, uint256 nullifierSeed, uint256 outCmSeed) internal pure {
        fillNullifiers(pi, nullifierSeed);
        fillCommitments(pi, outCmSeed);
    }

    /// `fillOutputs`, one array at a time. A test whose subject is the
    /// nullifiers (for example the double-spend fuzz) sets those itself and uses
    /// `fillCommitments` for the other array.
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

    /// The tree-update argument a spend is paired with, anchored at ring slot 0:
    /// the genesis root, which every pool suite's spends prove against until
    /// `ROOT_HISTORY` roots evict it.
    ///
    /// Only `newRoot`, `startIndex` and the anchor slot are left to the caller.
    /// MASP builds the rest of the batch image from `pi` itself
    /// (`PubInputs.compressSpend`).
    function spendTree(bytes32 newRoot, uint64 startIndex) internal pure returns (PubInputs.SpendTree memory) {
        return spendTree(newRoot, startIndex, 0);
    }

    /// `spendTree` with the anchor at `anchorIndex`, the slot
    /// `CommitmentTree.rootIndexOf` reports for `pi.merkleRoot`.
    function spendTree(bytes32 newRoot, uint64 startIndex, uint8 anchorIndex)
        internal
        pure
        returns (PubInputs.SpendTree memory tpi)
    {
        tpi.newRoot = newRoot;
        tpi.startIndex = startIndex;
        tpi.anchorIndex = anchorIndex;
    }

    /// One aux payload per output, each carrying `ciphertext` and a clue and
    /// ephemeral point that are on-curve and in the prime-order subgroup, as
    /// `AuxValidation.validate` checks. For tests whose subject is not the aux
    /// payload.
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
