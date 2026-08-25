// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockBatchVerifier } from "./mocks/MockBatchVerifier.sol";
import { SpendFixture } from "./utils/SpendFixture.sol";
import { FixtureLoader } from "./utils/FixtureLoader.sol";

/// Spend-path event emission. `AssetMoved` is emitted by the unshield entry
/// points rather than the shared note-emit helper, so these tests fix which
/// paths emit it and with which arguments. Both verifiers are mocked to
/// accept.
contract MASPSpendEventsTest is Test {
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;

    address internal constant RELAYER = address(0xCA11);
    address internal constant PAYER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xF00D);

    MockERC20 token;
    IVerifier verifier;
    IVerifier tubVerifier;
    MockBatchVerifier batchVerifier;
    MASP masp;

    event AssetMoved(uint64 indexed assetId, IERC20 indexed token, uint256 inAmount, uint256 outAmount);
    event NotePayload(
        bytes32 indexed cm,
        uint256 clueRx,
        uint256 clueRy,
        uint256 ephPubX,
        uint256 ephPubY,
        bytes ciphertext,
        uint256 cvDepX,
        uint256 cvDepY
    );

    function setUp() public {
        token = new MockERC20("M", "M", 18);
        verifier = IVerifier(address(new MockERC20("v", "v", 18)));
        tubVerifier = IVerifier(address(new MockERC20("tub", "tub", 18)));
        batchVerifier = new MockBatchVerifier();
        address permit2 = new DeployPermit2().deployPermit2();

        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = ASSET_ID;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;

        masp = new MASP(
            tubVerifier,
            batchVerifier,
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            FEE_BPS,
            address(0xfee),
            address(this)
        );

        token.mint(address(masp), 100 * SCALE);
        // The spend path verifies both proofs in one batched call, so this is
        // the only mock that matters for it.
        batchVerifier.setResult(true);
        vm.mockCall(address(tubVerifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
    }

    function _aux() internal pure returns (AuxValidation.Output[4] memory aux) {
        for (uint256 j = 0; j < aux.length; j++) {
            aux[j].clueRx = BabyJubJub.BASE8_X;
            aux[j].clueRy = BabyJubJub.BASE8_Y;
            aux[j].ephPubX = BabyJubJub.BASE8_X;
            aux[j].ephPubY = BabyJubJub.BASE8_Y;
            aux[j].ciphertext = hex"0001";
        }
    }

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return FixtureLoader.emptyProof();
    }

    function _spend(uint64 publicOut)
        internal
        view
        returns (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi)
    {
        bytes32 genesis = masp.currentRoot();
        pi.chainId = block.chainid;
        pi.publicAssetId = ASSET_ID;
        pi.publicOut = publicOut;
        pi.recipient = RECIPIENT;
        pi.payer = PAYER;
        pi.relayer = RELAYER;
        SpendFixture.fillOutputs(pi, 0x1111, 0x3333);
        pi.merkleRoot = genesis;

        tpi = SpendFixture.batchFor(pi, genesis, bytes32(uint256(0xABCD)), 0);
    }

    /// `withdraw` reports the gross unshielded amount, before the pool fee, as
    /// `outAmount`, and zero on the shield side.
    function test_withdraw_emitsAssetMovedGrossOut() public {
        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _spend(7);
        uint256 gross = 7 * SCALE;

        vm.expectEmit(true, true, true, true, address(masp));
        emit AssetMoved(ASSET_ID, IERC20(address(token)), 0, gross);

        vm.prank(RELAYER);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, _aux());

        // The recipient receives gross minus fee; the fee accrues to the pool.
        uint256 fee = (gross * FEE_BPS) / 10_000;
        assertEq(token.balanceOf(RECIPIENT), gross - fee, "recipient net");
        assertEq(masp.accruedFee(IERC20(address(token))), fee, "accrued fee");
    }

    /// `transfer` moves no tokens, so only the note payloads are emitted —
    /// one per output leaf.
    function test_transfer_emitsNoAssetMoved() public {
        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _spend(0);

        vm.recordLogs();
        vm.prank(RELAYER);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _aux());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 assetMovedSig = keccak256("AssetMoved(uint64,address,uint256,uint256)");
        bytes32 notePayloadSig = keccak256("NotePayload(bytes32,uint256,uint256,uint256,uint256,bytes,uint256,uint256)");
        uint256 notePayloads;
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != assetMovedSig, "transfer must not emit AssetMoved");
            if (logs[i].topics[0] == notePayloadSig) notePayloads++;
        }
        assertEq(notePayloads, PubInputs.TRANSACT_OUT, "one NotePayload per output leaf");
    }

    /// Each `NotePayload` carries its own commitment as the indexed topic, so
    /// the set of emitted topics is exactly the set of output commitments.
    function test_spend_notePayloadIndexesCommitments() public {
        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _spend(0);

        vm.recordLogs();
        vm.prank(RELAYER);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _aux());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 notePayloadSig = keccak256("NotePayload(bytes32,uint256,uint256,uint256,uint256,bytes,uint256,uint256)");
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != notePayloadSig) continue;
            assertEq(logs[i].topics[1], pi.outCm[seen], string.concat("cm topic ", vm.toString(seen)));
            seen++;
        }
        assertEq(seen, PubInputs.TRANSACT_OUT, "one NotePayload per output leaf");
    }

    // --- leaf-index reconstruction ------------------------------------------

    /// A wallet learns its note's Merkle leaf index by pairing `RootAdvanced`
    /// with the per-leaf `NotePayload` events: leaf `k` sits at
    /// `startIndex + k`. Nothing in the events states the index directly, so
    /// the mapping rests entirely on emission order and count. A wrong index
    /// yields a bad Merkle path and an unspendable note, and at the 4x4 shape
    /// a mis-mapping misplaces three leaves rather than two.
    ///
    /// This pins the whole indexer contract for a spend: how many events of
    /// each kind, in what order, and that the counts track
    /// `PubInputs.TRANSACT_IN` / `TRANSACT_OUT` rather than a literal 2 or 3.
    function test_spend_eventsAllowLeafIndexReconstruction() public {
        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _spend(0);
        uint64 startBefore = masp.committedCount();

        vm.recordLogs();
        vm.prank(RELAYER);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _aux());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 nfSig = keccak256("NullifierConsumed(bytes32)");
        bytes32 rootSig = keccak256("RootAdvanced(uint64,uint64,bytes32,bytes32)");
        bytes32 noteSig = keccak256("NotePayload(bytes32,uint256,uint256,uint256,uint256,bytes,uint256,uint256)");

        uint256 nfCount;
        uint256 noteCount;
        uint256 rootCount;
        uint256 rootAt;
        uint256 firstNoteAt;
        bool sawNote;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(masp)) continue;
            bytes32 sig = logs[i].topics[0];
            if (sig == nfSig) {
                // Nullifiers are emitted in input order.
                assertEq(logs[i].topics[1], pi.nullifier[nfCount], "nullifier order");
                nfCount++;
            } else if (sig == rootSig) {
                (uint64 inserted,,) = abi.decode(logs[i].data, (uint64, bytes32, bytes32));
                assertEq(uint256(logs[i].topics[1]), startBefore, "RootAdvanced.startIndex");
                assertEq(inserted, PubInputs.TRANSACT_OUT, "leaves inserted per spend");
                rootAt = i;
                rootCount++;
            } else if (sig == noteSig) {
                // Leaf k of this spend lands at startIndex + k.
                assertEq(logs[i].topics[1], pi.outCm[noteCount], "NotePayload order == leaf order");
                if (!sawNote) {
                    firstNoteAt = i;
                    sawNote = true;
                }
                noteCount++;
            }
        }

        assertEq(nfCount, PubInputs.TRANSACT_IN, "one NullifierConsumed per input");
        assertEq(noteCount, PubInputs.TRANSACT_OUT, "one NotePayload per output leaf");
        assertEq(rootCount, 1, "exactly one RootAdvanced");
        // On the spend path the root advance precedes the note payloads. The
        // flush path emits DepositFlushed BEFORE its RootAdvanced, so an indexer
        // cannot assume a single global ordering across the two paths.
        assertLt(rootAt, firstNoteAt, "spend path: RootAdvanced precedes NotePayload");

        assertEq(masp.committedCount(), startBefore + PubInputs.TRANSACT_OUT, "committedCount advance");
    }
}
