// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// Spend-path event emission. `AssetMoved` is emitted by the unshield entry
/// points themselves (not from the shared note-emit helper), so pin which
/// paths emit it and with what arguments. Both verifiers are mocked to accept.
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
    MASP masp;

    event AssetMoved(uint64 indexed assetId, IERC20 indexed token, uint256 inAmount, uint256 outAmount);
    event NotePayload(
        bytes32 indexed cm0,
        bytes32 indexed cm1,
        uint256 clueRx0,
        uint256 clueRy0,
        uint256 ephPubX0,
        uint256 ephPubY0,
        bytes ciphertext0,
        uint256 clueRx1,
        uint256 clueRy1,
        uint256 ephPubX1,
        uint256 ephPubY1,
        bytes ciphertext1,
        uint256 cvDep0X,
        uint256 cvDep0Y,
        uint256 cvDep1X,
        uint256 cvDep1Y
    );

    function setUp() public {
        token = new MockERC20("M", "M", 18);
        verifier = IVerifier(address(new MockERC20("v", "v", 18)));
        tubVerifier = IVerifier(address(new MockERC20("tub", "tub", 18)));
        address permit2 = new DeployPermit2().deployPermit2();

        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = ASSET_ID;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;

        masp = new MASP(
            verifier,
            tubVerifier,
            ISignatureTransfer(address(permit2)),
            IWrappedNative(address(0)),
            ids,
            tokens,
            scales,
            FEE_BPS,
            address(0xfee),
            address(this)
        );

        token.mint(address(masp), 100 * SCALE);
        vm.mockCall(address(verifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
        vm.mockCall(address(tubVerifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
    }

    function _aux() internal pure returns (AuxValidation.Output[2] memory aux) {
        for (uint256 j = 0; j < 2; j++) {
            aux[j].clueRx = BabyJubJub.BASE8_X;
            aux[j].clueRy = BabyJubJub.BASE8_Y;
            aux[j].ephPubX = BabyJubJub.BASE8_X;
            aux[j].ephPubY = BabyJubJub.BASE8_Y;
            aux[j].ciphertext = hex"0001";
        }
    }

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return MASP.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
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
        pi.nullifier[0] = bytes32(uint256(0x1111));
        pi.nullifier[1] = bytes32(uint256(0x2222));
        pi.outCm[0] = bytes32(uint256(0x3333));
        pi.outCm[1] = bytes32(uint256(0x4444));
        pi.merkleRoot = genesis;

        tpi.oldRoot = genesis;
        tpi.newRoot = bytes32(uint256(0xABCD));
        tpi.startIndex = 0;
        tpi.actualCount = 1;
        tpi.cms[0] = pi.outCm[0];
        tpi.cms[1] = pi.outCm[1];
    }

    /// `withdraw` reports the GROSS unshielded amount (before the pool fee)
    /// as `outAmount`, and zero on the shield side.
    function test_withdraw_emitsAssetMovedGrossOut() public {
        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _spend(7);
        uint256 gross = 7 * SCALE;

        vm.expectEmit(true, true, true, true, address(masp));
        emit AssetMoved(ASSET_ID, IERC20(address(token)), 0, gross);

        vm.prank(RELAYER);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, _aux());

        // Recipient got gross minus fee; the fee accrued to the pool.
        uint256 fee = (gross * FEE_BPS) / 10_000;
        assertEq(token.balanceOf(RECIPIENT), gross - fee, "recipient net");
        assertEq(masp.accruedFee(IERC20(address(token))), fee, "accrued fee");
    }

    /// `transfer` moves no tokens, so `AssetMoved` must NOT be emitted —
    /// only the note payload.
    function test_transfer_emitsNoAssetMoved() public {
        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _spend(0);

        vm.recordLogs();
        vm.prank(RELAYER);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _aux());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 assetMovedSig = keccak256("AssetMoved(uint64,address,uint256,uint256)");
        bytes32 notePayloadSig = keccak256(
            "NotePayload(bytes32,bytes32,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256)"
        );
        uint256 notePayloads;
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != assetMovedSig, "transfer must not emit AssetMoved");
            if (logs[i].topics[0] == notePayloadSig) notePayloads++;
        }
        assertEq(notePayloads, 1, "exactly one NotePayload");
    }

    /// `NotePayload` carries the commitments as indexed topics, so it is the
    /// sole "note exists" signal for commitment-only indexers.
    function test_spend_notePayloadIndexesCommitments() public {
        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) = _spend(0);

        vm.recordLogs();
        vm.prank(RELAYER);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _aux());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 notePayloadSig = keccak256(
            "NotePayload(bytes32,bytes32,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256)"
        );
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != notePayloadSig) continue;
            found = true;
            assertEq(logs[i].topics[1], pi.outCm[0], "cm0 topic");
            assertEq(logs[i].topics[2], pi.outCm[1], "cm1 topic");
        }
        assertTrue(found, "NotePayload emitted");
    }
}
