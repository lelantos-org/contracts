// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { NullifierSet } from "../../src/NullifierSet.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { SpendFixture } from "../utils/SpendFixture.sol";
import { PoolFixture } from "./PoolFixture.sol";

/// Symbolic proofs for the spend-side request guards.
///
/// A spend carries two independently generated Groth16 proofs (transact and
/// tree-update), and neither circuit binds them to each other. The pool binds
/// them by construction: `PubInputs.compressSpend` builds the tree-update image
/// from the spend's own `outCm` and `outCvDep` (pinned to the full-batch image by
/// `PubInputsSpendTest`), so there is no relayer-supplied copy to compare.
/// `MASP._validateRequest` checks the anchor by ring slot, the batch position at
/// the tree frontier, and the party and nullifier guards, all plain comparisons.
///
/// Every proof here is a rejection. A request that passes validation reaches
/// `PubInputs.compress`, assembly and `mulmod` folding over ~70 words of
/// Fiat-Shamir transcript, which the solvers do not finish. Rejections never
/// reach it, so the guards are provable for every malformed input; the accepting
/// path is covered by the fixture-driven tests in `test/masp/MASP.*.t.sol`.
///
/// The pool and its mocks come from `PoolFixture`. Neither verifier is reached,
/// since every call below reverts in validation before `_finalize`, but the pool
/// requires code at those addresses to deploy.
contract MASPSpendGuardsSymbolicTest is PoolFixture {
    address internal constant PAYER = address(0xface);
    /// `CommitmentTree.ROOT_HISTORY`, which is internal.
    uint256 internal constant ROOT_HISTORY = 64;

    /// A transfer request that passes every guard: `publicIn == publicOut == 0`,
    /// the genesis root, six distinct nullifiers and commitments, and a batch
    /// aligned to an empty tree.
    function _base() internal view returns (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) {
        pi.merkleRoot = EMPTY_ROOT;
        pi.publicAssetId = ASSET_ID;
        pi.recipient = RECIPIENT;
        pi.payer = PAYER;
        pi.relayer = address(this);
        pi.chainId = block.chainid;
        SpendFixture.fillOutputs(pi, 0x100, 0x200);
        tpi = SpendFixture.spendTree(bytes32(uint256(0xbeef)), 0);
    }

    /// `transfer` rather than `withdraw`: both run the same validation, but a
    /// transfer moves no tokens, so nothing after the guards affects the result.
    function _transfer(PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi)
        internal
        returns (bool ok, bytes memory ret)
    {
        MASP.Proof memory p;
        AuxValidation.Output[6] memory aux = _aux();
        (ok, ret) = address(masp).call(abi.encodeCall(MASP.transfer, (p, pi, p, tpi, aux)));
    }

    function _rejectedWith(PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi, bytes4 expected) internal {
        (bool ok, bytes memory ret) = _transfer(pi, tpi);
        _assertRejected(ok, ret, expected);
    }

    // --- double-spend ------------------------------------------------------

    /// A nullifier repeated in any two input slots is rejected, for every
    /// nullifier vector.
    ///
    /// The pairwise check rejects an in-transaction repeat during validation,
    /// before proof verification. `NullifierSet` consumes the four nullifiers
    /// sequentially after verification and would only then revert `DoubleSpend`
    /// on the repeat.
    function check_spend_rejectsRepeatedNullifier(bytes32[4] memory nf) public {
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _base();

        bool anyRepeat = false;
        for (uint256 a = 0; a < 4; ++a) {
            pi.nullifier[a] = nf[a];
            for (uint256 b = a + 1; b < 4; ++b) {
                if (nf[a] == nf[b]) anyRepeat = true;
            }
        }
        vm.assume(anyRepeat);

        _rejectedWith(pi, tpi, NullifierSet.DuplicateNullifier.selector);
    }

    // --- tree position -----------------------------------------------------

    /// Only a root the pool has held is accepted. This pool has not advanced, so
    /// the genesis root in slot 0 is the only known root; every other slot is
    /// empty, and the last slot represents them.
    ///
    /// The slots are concrete because halmos cannot load a storage slot at a
    /// symbolic index. The root is symbolic.
    function check_spend_rejectsUnknownRoot(bytes32 root) public {
        vm.assume(root != EMPTY_ROOT);

        uint8[2] memory slots = [uint8(0), uint8(ROOT_HISTORY - 1)];
        for (uint256 i; i < slots.length; ++i) {
            (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _base();
            pi.merkleRoot = root;
            tpi.anchorIndex = slots[i];
            _rejectedWith(pi, tpi, MASP.UnknownRoot.selector);
        }
    }

    /// The genesis root named at an empty slot is rejected.
    function check_spend_rejectsKnownRootAtWrongIndex() public {
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _base();
        tpi.anchorIndex = uint8(ROOT_HISTORY - 1);
        _rejectedWith(pi, tpi, MASP.UnknownRoot.selector);
    }

    /// An index past the ring is rejected for every root, before any slot is
    /// read.
    function check_spend_rejectsOutOfRangeAnchorIndex(uint8 anchorIndex, bytes32 root) public {
        vm.assume(anchorIndex >= ROOT_HISTORY);

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _base();
        pi.merkleRoot = root;
        tpi.anchorIndex = anchorIndex;

        _rejectedWith(pi, tpi, MASP.UnknownRoot.selector);
    }

    /// The batch must start at the committed leaf count, so leaves cannot be
    /// inserted at a gap or over existing ones.
    function check_spend_rejectsMisalignedStartIndex(uint64 startIndex) public {
        vm.assume(startIndex != 0);

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _base();
        tpi.startIndex = startIndex;

        _rejectedWith(pi, tpi, MASP.BatchMisaligned.selector);
    }

    // --- caller and party binding -----------------------------------------

    /// `pi.relayer` is a public input of the transact proof; requiring it to equal
    /// `msg.sender` prevents a third party from front-running a spend and
    /// collecting the relayer note.
    function check_spend_rejectsAnyRelayerButSender(address relayer, address caller) public {
        vm.assume(relayer != caller);

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _base();
        pi.relayer = relayer;

        vm.prank(caller);
        _rejectedWith(pi, tpi, MASP.BadRelayer.selector);
    }

    /// A proof built for another chain is not replayable here.
    function check_spend_rejectsForeignChainId(uint256 chainId) public {
        vm.assume(chainId != block.chainid);

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _base();
        pi.chainId = chainId;

        _rejectedWith(pi, tpi, MASP.BadChainId.selector);
    }
}
