// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { MASPSpendHarness, deploySpendHarness } from "../utils/MASPSpendHarness.sol";
import { mockVerifierStack, singleAsset } from "../utils/PoolDeployer.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// The commitment tree's hard capacity (audit finding #3).
///
/// The tree holds `MAX_LEAVES = 4^11` leaves and never rolls over. Every
/// `transfer` and `withdraw` appends `TRANSACT_OUT = 6` leaves, whatever their
/// values, and a flush appends `LEAVES_PER_DEPOSIT = 2` per deposit, so a
/// tree-advancing call is refused `TreeFull` once its leaves no longer fit.
/// `transfer` charges no fee and the circuit accepts a real input of value 0,
/// so the tree can be filled with zero-value notes; this suite pins what the
/// pool does at that boundary. The protocol response is operational (see
/// `src/README.md`, "Capacity and zero-value leaves").
///
/// The harness seeds `committedCount` directly, so no proof is needed to reach
/// the boundary. The spend verifier is a `MockBatchVerifier`, which rejects
/// until told otherwise, so a spend that clears the capacity check fails next on
/// `ProofRejected`.
contract MASPTreeCapacityTest is Test {
    uint256 internal constant MAX_LEAVES = 4_194_304; // CommitmentTree.MAX_LEAVES
    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint64 internal constant PUBLIC_IN = 100;

    address internal constant RELAYER = address(0xCA11);
    address internal constant SPEND_PAYER = address(0xBEEF);
    address internal constant RECIPIENT = TestConstants.RECIPIENT;
    /// Codeless, so its escrow may be cancelled by anyone.
    address internal constant PAYER = address(0xEA0A);
    address internal constant BYSTANDER = address(0xdead);
    bytes32 internal constant FEE_CM = bytes32(uint256(0xfee));

    MASPSpendHarness masp;
    MockBatchVerifier batchVerifier;
    MockERC20 token;
    address permit2;

    function setUp() public {
        IVerifier tub;
        ISignatureTransfer p2;
        (tub, batchVerifier, p2) = mockVerifierStack();
        permit2 = address(p2);
        token = new MockERC20("M", "M", 18);
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        masp = deploySpendHarness(tub, batchVerifier, p2, ids, tokens, scales, address(0xfee), address(this));
    }

    // --- helpers -----------------------------------------------------------

    /// Seeds the tree so exactly `remaining` leaves fit.
    function _fillLeaving(uint256 remaining) internal {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 inserted = uint64(MAX_LEAVES - remaining - masp.committedCount());
        // A small integer rather than a hash: the root enters the spend's
        // compressed inputs, which reject anything at or above the field modulus.
        masp.seedRoot(bytes32(uint256(0xf111ed) + remaining), inserted);
        assertEq(MAX_LEAVES - masp.committedCount(), remaining, "seeded capacity");
    }

    /// A spend at the tree frontier, anchored at the current root, with
    /// nullifiers from `seed`.
    function _spend(uint64 publicOut, uint256 seed)
        internal
        view
        returns (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi)
    {
        pi.chainId = block.chainid;
        pi.publicAssetId = ASSET_ID;
        pi.publicOut = publicOut;
        pi.recipient = RECIPIENT;
        pi.payer = SPEND_PAYER;
        pi.relayer = RELAYER;
        SpendFixture.fillOutputs(pi, seed, seed + 0x100);
        pi.merkleRoot = masp.currentRoot();
        tpi = SpendFixture.spendTree(bytes32(seed + 0x200), masp.committedCount(), uint8(masp.rootIndex()));
    }

    function _transfer(uint256 seed) internal {
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _spend(0, seed);
        vm.prank(RELAYER);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return FixtureLoader.emptyProof();
    }

    function _validAux() internal pure returns (AuxValidation.Output[6] memory) {
        return SpendFixture.validAux();
    }

    /// Escrows one zero-fee deposit from the codeless `PAYER` through the
    /// standing-allowance path, which needs no signature.
    function _deposit() internal returns (uint256 id, uint32 submittedAt) {
        token.mint(PAYER, uint256(PUBLIC_IN) * SCALE);
        vm.startPrank(PAYER);
        token.approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(address(token), address(masp), type(uint160).max, type(uint48).max);

        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = PUBLIC_IN;
        d.payer = PAYER;
        d.recipient = RECIPIENT;
        d.outCm = bytes32(uint256(0x111));
        d.feeCm = FEE_CM;
        id = masp.depositAuthorized(d, _validAux()[0], _validAux()[1]);
        vm.stopPrank();
        // forge-lint: disable-next-line(unsafe-typecast)
        submittedAt = uint32(block.number);
    }

    /// A one-deposit flush header at the frontier. The per-leaf fields are left
    /// zero: the capacity check runs in the header, before any of them is read.
    /// Built before the call so `vm.expectRevert` sees `flushBatch` next.
    function _flushOneArgs(uint256 id)
        internal
        view
        returns (uint256[] memory ids, MASP.DepositMeta[] memory meta, PubInputs.TreeUpdateBatch memory tpi)
    {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xfeedbeef));
        tpi.startIndex = masp.committedCount();
        // forge-lint: disable-next-line(unsafe-typecast)
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        ids = new uint256[](1);
        ids[0] = id;
        meta = new MASP.DepositMeta[](1);
    }

    // --- spends ------------------------------------------------------------

    /// Five free leaves cannot take a spend's six, whatever the notes' values.
    function test_revert_TreeFull_transferWhenFewerThanSixLeavesRemain() public {
        _fillLeaving(5);
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _spend(0, 1);

        vm.prank(RELAYER);
        vm.expectRevert(MASP.TreeFull.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    /// Exactly six free leaves pass the capacity check: the rejecting verifier
    /// is what stops the spend. Accepted, it fills the tree to `MAX_LEAVES`,
    /// and the next spend is `TreeFull`.
    function test_transfer_passesCapacityWithExactlySixLeavesLeft() public {
        _fillLeaving(6);
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _spend(0, 1);

        vm.prank(RELAYER);
        vm.expectRevert(MASP.ProofRejected.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());

        batchVerifier.setResult(true);
        _transfer(1);
        assertEq(masp.committedCount(), MAX_LEAVES, "tree exactly full");

        (pi, tpi) = _spend(0, 0x1000);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.TreeFull.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    /// An unshield also appends six leaves, so a nearly full tree blocks exits
    /// as well as transfers.
    function test_revert_TreeFull_withdrawWhenFewerThanSixLeavesRemain() public {
        _fillLeaving(5);
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _spend(1, 1);

        vm.prank(RELAYER);
        vm.expectRevert(MASP.TreeFull.selector);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    // --- escrow --------------------------------------------------------------

    /// A deposit's two leaves do not fit in one: the flush is `TreeFull`, and
    /// the escrow stays pending.
    function test_revert_TreeFull_flushWhenBatchDoesNotFit() public {
        (uint256 id,) = _deposit();
        _fillLeaving(1);
        (uint256[] memory ids, MASP.DepositMeta[] memory meta, PubInputs.TreeUpdateBatch memory tpi) = _flushOneArgs(id);

        vm.expectRevert(MASP.TreeFull.selector);
        masp.flushBatch(ids, meta, _emptyProof(), tpi);

        assertTrue(masp.escrowed(id) != bytes32(0), "escrow still pending");
    }

    /// Two free leaves are enough for one deposit's flush: the header's capacity
    /// check passes and the batch fails on the first per-leaf check instead.
    function test_flush_passesCapacityWithExactlyTwoLeavesLeft() public {
        (uint256 id,) = _deposit();
        _fillLeaving(2);
        (uint256[] memory ids, MASP.DepositMeta[] memory meta, PubInputs.TreeUpdateBatch memory tpi) = _flushOneArgs(id);

        vm.expectRevert(MASP.BadDepositMode.selector);
        masp.flushBatch(ids, meta, _emptyProof(), tpi);
    }

    /// A full tree strands no escrow: `cancelDeposit` appends no leaf, so it
    /// still refunds the payer once `cancelDelay` has passed.
    function test_cancelDeposit_stillOpenWhenTreeIsFull() public {
        (uint256 id, uint32 submittedAt) = _deposit();
        _fillLeaving(0);
        vm.roll(block.number + masp.cancelDelay());

        vm.prank(BYSTANDER);
        (uint256 refunded,) = masp.cancelDeposit(
            id,
            uint48(PUBLIC_IN),
            bytes32(uint256(0x111)),
            [uint256(0), 0],
            ASSET_ID,
            0,
            PAYER,
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: FEE_CM, feeCvDep: [uint256(0), 0] })
        );

        assertEq(refunded, uint256(PUBLIC_IN) * SCALE, "whole pull refunded");
        assertEq(token.balanceOf(PAYER), refunded, "to the digest-bound payer");
        assertEq(masp.escrowed(id), bytes32(0), "escrow cleared");
    }
}
