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
/// A spend carries two independently generated Groth16 proofs — the transact
/// proof and the tree-update proof — and *nothing in either circuit binds them
/// to each other*. `MASP._validateRequest` is what does: it equates the spend's
/// `outCm` and `outCvDep` with the tree-update's `cms` and `cvDeps`, pins
/// `isDeposit` to zero so a spend output cannot masquerade as a deposit leaf,
/// and places the batch at the tree frontier. Those checks are the seam between
/// two proofs, which is the classic place for a soundness bug, and they are
/// plain comparisons — exactly what a solver is good at.
///
/// Every proof here is a rejection. That is a deliberate cost decision, not a
/// gap: a request that passes validation goes on to `PubInputs.compress`,
/// assembly and `mulmod` folding over ~60 words of Fiat-Shamir transcript, which
/// no solver here finishes. A rejected one never reaches it, so the guards are
/// provable for every malformed input while the accepting path stays with the
/// fixture-driven tests in `test/MASP.*.t.sol`.
///
/// The pool and its mocks come from `PoolFixture`. Neither verifier is reached —
/// every call below reverts in validation, before `_finalize` — but the pool
/// will not deploy without code at those addresses.
contract MASPSpendGuardsSymbolicTest is PoolFixture {
    address internal constant PAYER = address(0xface);

    /// A transfer request that passes every guard: `publicIn == publicOut == 0`,
    /// the genesis root, six distinct nullifiers and commitments, and a batch
    /// aligned to an empty tree.
    function _base() internal view returns (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) {
        pi.merkleRoot = EMPTY_ROOT;
        pi.publicAssetId = ASSET_ID;
        pi.recipient = RECIPIENT;
        pi.payer = PAYER;
        pi.relayer = address(this);
        pi.chainId = block.chainid;
        SpendFixture.fillOutputs(pi, 0x100, 0x200);
        tpi = SpendFixture.batchFor(pi, EMPTY_ROOT, bytes32(uint256(0xbeef)), 0);
    }

    /// `transfer` rather than `withdraw`: both run the same validation, but a
    /// transfer moves no tokens, so nothing downstream of the guards can
    /// influence the result.
    function _transfer(PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi)
        internal
        returns (bool ok, bytes memory ret)
    {
        MASP.Proof memory p;
        AuxValidation.Output[6] memory aux = _aux();
        (ok, ret) = address(masp).call(abi.encodeCall(MASP.transfer, (p, pi, p, tpi, aux)));
    }

    function _rejectedWith(PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi, bytes4 expected)
        internal
    {
        (bool ok, bytes memory ret) = _transfer(pi, tpi);
        _assertRejected(ok, ret, expected);
    }

    // --- proof cross-binding ----------------------------------------------

    /// The tree-update proof's commitments must equal the spend's, for every
    /// possible commitment vector.
    ///
    /// This is the binding that keeps the two proofs describing the same
    /// outputs. Without it a relayer could pair a valid spend with a valid
    /// tree-update over different leaves, consuming the spender's inputs while
    /// inserting commitments nobody can open.
    function check_spend_rejectsUnboundCommitments(bytes32[8] memory cms) public {
        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _base();

        bool allMatch = true;
        for (uint256 k = 0; k < 6; ++k) {
            if (cms[k] != pi.outCm[k]) allMatch = false;
            tpi.cms[k] = cms[k];
        }
        vm.assume(!allMatch);

        _rejectedWith(pi, tpi, MASP.CmMismatch.selector);
    }

    /// `cv_dep` is part of the leaf preimage and the recipient must be able to
    /// reproduce it. An unbound one inserts a leaf under a value commitment the
    /// recipient cannot open, leaving the output permanently unspendable.
    function check_spend_rejectsUnboundValueCommitments(uint256 x, uint256 y) public {
        vm.assume(x != 0 || y != 0);

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _base();
        // The spend's own `outCvDep` is all-zero in this fixture, so any
        // non-zero pair on the batch side is a mismatch.
        tpi.cvDeps[0] = [x, y];

        _rejectedWith(pi, tpi, MASP.CvDepMismatch.selector);
    }

    /// A spend output cannot be flagged as a deposit leaf.
    ///
    /// The batch circuit cannot tell the two apart and does not force
    /// `is_deposit = 0`; deposit binding is per-leaf, so a spend output could
    /// otherwise satisfy it by declaring its own value and publishing the
    /// note's opening. Pinned in the contract, and proved here for every flag
    /// value in every slot.
    function check_spend_rejectsDepositFlaggedOutput(uint8[8] memory flags) public {
        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _base();

        bool anySet = false;
        for (uint256 k = 0; k < 6; ++k) {
            if (flags[k] != 0) anySet = true;
            tpi.isDeposit[k] = flags[k];
        }
        vm.assume(anySet);

        _rejectedWith(pi, tpi, MASP.BadDepositMode.selector);
    }

    /// The batch must commit exactly the spend's output count.
    function check_spend_rejectsWrongLeafCount(uint64 actualCount) public {
        vm.assume(actualCount != 6);

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _base();
        tpi.actualCount = actualCount;

        _rejectedWith(pi, tpi, MASP.BatchMisaligned.selector);
    }

    // --- double-spend ------------------------------------------------------

    /// A nullifier repeated in any two input slots is rejected, for every
    /// nullifier vector.
    ///
    /// The pairwise check inside a single transaction is what the bitmap in
    /// `NullifierSet` cannot do: all four are consumed in one call, so without
    /// it one note could be spent four times before any bit is set.
    function check_spend_rejectsRepeatedNullifier(bytes32[4] memory nf) public {
        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _base();

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

    /// Only a root the pool has actually held is accepted. The pool here has
    /// never advanced, so the genesis root is the only one.
    function check_spend_rejectsUnknownRoot(bytes32 root) public {
        vm.assume(root != EMPTY_ROOT);

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _base();
        pi.merkleRoot = root;

        _rejectedWith(pi, tpi, MASP.UnknownRoot.selector);
    }

    /// The batch must extend the live root, not a historical one. `merkleRoot`
    /// may lag — a proof stays valid while its root is in the ring — but the
    /// tree update itself has to start from the frontier.
    function check_spend_rejectsStaleOldRoot(bytes32 oldRoot) public {
        vm.assume(oldRoot != EMPTY_ROOT);

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _base();
        tpi.oldRoot = oldRoot;

        _rejectedWith(pi, tpi, MASP.StaleOldRoot.selector);
    }

    /// The batch must start exactly where the tree is committed to, so leaves
    /// cannot be inserted at a gap or over existing ones.
    function check_spend_rejectsMisalignedStartIndex(uint64 startIndex) public {
        vm.assume(startIndex != 0);

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _base();
        tpi.startIndex = startIndex;

        _rejectedWith(pi, tpi, MASP.BatchMisaligned.selector);
    }

    // --- caller and party binding -----------------------------------------

    /// `pi.relayer` is a public input of the transact proof, so pinning it to
    /// `msg.sender` is what stops a third party from front-running someone
    /// else's spend and collecting the relayer note.
    function check_spend_rejectsAnyRelayerButSender(address relayer, address caller) public {
        vm.assume(relayer != caller);

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _base();
        pi.relayer = relayer;

        vm.prank(caller);
        _rejectedWith(pi, tpi, MASP.BadRelayer.selector);
    }

    /// A proof built for another chain is not replayable here.
    function check_spend_rejectsForeignChainId(uint256 chainId) public {
        vm.assume(chainId != block.chainid);

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _base();
        pi.chainId = chainId;

        _rejectedWith(pi, tpi, MASP.BadChainId.selector);
    }
}
