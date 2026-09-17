// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { deployPoolUniform, realVerifierStack, singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";

/// `escrowed[id]` stores only a digest, so flush and cancel require the caller
/// to resupply the full preimage. The documented source for that preimage is
/// the deposit's `DepositEscrowed` event plus its block number.
///
/// Other escrow tests build the preimage from Solidity values they already
/// hold, and would pass even if the event dropped or reordered a field. These
/// tests decode the emitted log and use nothing else, exercising the event as
/// the off-chain integration surface.
contract MASPEscrowEventRoundtripTest is Test {
    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant TREASURY = TestConstants.TREASURY;
    address internal constant OWNER = TestConstants.OWNER;

    address internal permit2;
    MockERC20 internal token;
    MASP internal masp;

    address internal payer = TestConstants.ESCROW_PAYER;
    address internal recipient = address(0xb0b);

    /// Static head fields of `DepositEscrowed`, recovered from the log.
    struct Decoded {
        uint256 id;
        address payer;
        uint64 publicAssetId;
        uint64 publicIn;
        uint16 feeBpsAtSubmit;
        bytes32 cm;
        uint256[2] cvDep;
        uint32 submittedAt;
        uint48 feeIn;
        uint64 feeAssetId;
        bytes32 feeCm;
        uint256[2] feeCvDep;
    }

    /// The non-indexed body of `DepositEscrowed`, in declaration order.
    ///
    /// Decoded as a struct rather than a positional tuple: the body spans two
    /// `bytes` members, so the fee fields sit past the first dynamic offset
    /// and cannot be read by truncating the head.
    struct EscrowLog {
        uint64 publicAssetId;
        uint64 publicIn;
        uint16 feeBpsAtSubmit;
        bytes32 cm;
        uint256 cvDepX;
        uint256 cvDepY;
        uint256 rcv;
        uint256 clueRx;
        uint256 clueRy;
        uint256 ephPubX;
        uint256 ephPubY;
        bytes ciphertext;
        uint64 feeAssetId;
        uint64 feeIn;
        bytes32 feeCm;
        uint256 feeCvDepX;
        uint256 feeCvDepY;
        uint256 feeRcv;
        uint256 feeClueRx;
        uint256 feeClueRy;
        uint256 feeEphPubX;
        uint256 feeEphPubY;
        bytes feeCiphertext;
    }

    function setUp() public {
        (IVerifier tub, IBatchVerifier bv, ISignatureTransfer p2) = realVerifierStack();
        permit2 = address(p2);
        token = new MockERC20("M", "M", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        masp = deployPoolUniform(tub, bv, p2, ids, tokens, scales, FEE_BPS, TREASURY, OWNER);

        Stubs.installPermissiveERC1271(payer);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);
    }

    /// Submits a deposit and recovers the cancel preimage from the log alone.
    function _submitAndDecode(uint64 publicIn, uint256 nonce) internal returns (Decoded memory dec) {
        uint256 inAmt = uint256(publicIn) * SCALE;
        (uint16 depBps,) = masp.assetFees(ASSET_ID);
        token.mint(payer, inAmt + (inAmt * depBps) / 10_000);

        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = recipient;
        d.outCm = bytes32(uint256(0x111 + nonce));
        d.feeCm = bytes32(uint256(0xfee));
        d.cvDep = [uint256(0xaa1 + nonce), uint256(0xaa2 + nonce)];
        d.rcv = 0xccc + nonce;

        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: nonce, deadline: type(uint256).max, maxTotal: type(uint256).max, maxFee: 0, signature: hex"00"
        });

        vm.recordLogs();
        masp.deposit(d, sig, SpendFixture.validAuxOutput(), SpendFixture.validAuxOutput());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sigHash = keccak256(
            "DepositEscrowed(uint256,address,address,uint64,uint64,uint16,bytes32,uint256,uint256,uint256,"
            "uint256,uint256,uint256,uint256,bytes,uint64,uint64,bytes32,uint256,uint256,uint256,uint256,uint256,"
            "uint256,uint256,bytes)"
        );
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(masp) || logs[i].topics[0] != sigHash) continue;
            found = true;
            dec.id = uint256(logs[i].topics[1]);
            dec.payer = address(uint160(uint256(logs[i].topics[2])));
            // Event data is the parameter tuple encoded inline, but decoding
            // into a dynamic struct expects a leading offset to it. One is
            // prepended; decoding 23 positional values exceeds the stack limit.
            EscrowLog memory body = abi.decode(bytes.concat(abi.encode(uint256(0x20)), logs[i].data), (EscrowLog));
            dec.publicAssetId = body.publicAssetId;
            dec.publicIn = body.publicIn;
            dec.feeBpsAtSubmit = body.feeBpsAtSubmit;
            dec.cm = body.cm;
            dec.cvDep = [body.cvDepX, body.cvDepY];
            // The relayer's leaf is part of the digest, so a canceller needs it
            // from the log too.
            // forge-lint: disable-next-line(unsafe-typecast)
            dec.feeIn = uint48(body.feeIn);
            dec.feeAssetId = body.feeAssetId;
            dec.feeCm = body.feeCm;
            dec.feeCvDep = [body.feeCvDepX, body.feeCvDepY];
        }
        assertTrue(found, "DepositEscrowed not emitted");
        // The remaining preimage field is the emitting block.
        dec.submittedAt = uint32(block.number);
    }

    /// A canceller holding only the log and its block number can produce a
    /// preimage that satisfies `escrowed[id]`.
    function test_cancelDeposit_reconstructedFromEventOnly() public {
        uint64 publicIn = 100;
        Decoded memory dec = _submitAndDecode(publicIn, 0);

        // The log carries the submitted values.
        assertEq(dec.publicAssetId, ASSET_ID, "assetId from log");
        assertEq(dec.publicIn, publicIn, "publicIn from log");
        assertEq(dec.feeBpsAtSubmit, FEE_BPS, "feeBps from log");
        assertEq(dec.payer, payer, "payer from log");

        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 expected = inAmt + (inAmt * FEE_BPS) / 10_000;

        vm.roll(block.number + masp.cancelDelay());
        uint256 before = token.balanceOf(payer);

        // Uses only log-derived values. The fixture payer is an
        // etched ERC-1271 stub, so MASP treats it as a contract payer and only
        // it may cancel; the unrelated-caller case is covered for EOA payers in
        // MASP.cancelDeposit.t.sol.
        vm.prank(payer);
        masp.cancelDeposit(
            dec.id,
            uint48(dec.publicIn),
            dec.cm,
            dec.cvDep,
            dec.publicAssetId,
            dec.feeBpsAtSubmit,
            dec.payer,
            dec.submittedAt,
            PubInputs.FeeNote({
                feeIn: dec.feeIn, feeAssetId: dec.feeAssetId, feeCm: dec.feeCm, feeCvDep: dec.feeCvDep
            })
        );

        assertEq(token.balanceOf(payer) - before, expected, "refund to digest-bound payer");
        assertEq(masp.escrowed(dec.id), bytes32(0), "escrow cleared");
    }

    /// `feeBpsAtSubmit` is bound into the digest, so an owner fee change while
    /// a deposit is pending does not alter what the escrow refunds.
    function test_cancelDeposit_usesSubmitTimeFeeAfterFeeRaise() public {
        uint64 publicIn = 100;
        Decoded memory dec = _submitAndDecode(publicIn, 0);
        assertEq(dec.feeBpsAtSubmit, FEE_BPS, "captured submit-time fee");

        // The owner raises the fee to the ceiling while the deposit is pending.
        // The bound is read first: an inline call would consume the prank.
        uint16 maxFee = masp.MAX_FEE_BPS();
        vm.prank(OWNER);
        masp.setAssetFee(ASSET_ID, maxFee, maxFee);
        (uint16 raised,) = masp.assetFees(ASSET_ID);
        assertEq(raised, maxFee, "fee raised");

        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 atSubmit = inAmt + (inAmt * FEE_BPS) / 10_000;

        vm.roll(block.number + masp.cancelDelay());
        uint256 before = token.balanceOf(payer);

        vm.prank(payer); // contract payer (ERC-1271 stub) drives its own cancel
        masp.cancelDeposit(
            dec.id,
            uint48(dec.publicIn),
            dec.cm,
            dec.cvDep,
            dec.publicAssetId,
            dec.feeBpsAtSubmit,
            dec.payer,
            dec.submittedAt,
            PubInputs.FeeNote({
                feeIn: dec.feeIn, feeAssetId: dec.feeAssetId, feeCm: dec.feeCm, feeCvDep: dec.feeCvDep
            })
        );

        assertEq(token.balanceOf(payer) - before, atSubmit, "refund uses submit-time fee");
    }

    /// Supplying the current fee instead of the digest-bound submit-time fee
    /// is rejected rather than refunding a different amount.
    function test_revert_cancelDeposit_currentFeeInsteadOfSubmitTimeFee() public {
        Decoded memory dec = _submitAndDecode(100, 0);

        uint16 maxFee = masp.MAX_FEE_BPS();
        vm.prank(OWNER);
        masp.setAssetFee(ASSET_ID, maxFee, maxFee);

        vm.roll(block.number + masp.cancelDelay());
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, dec.id));
        masp.cancelDeposit(
            dec.id,
            uint48(dec.publicIn),
            dec.cm,
            dec.cvDep,
            dec.publicAssetId,
            maxFee,
            dec.payer,
            dec.submittedAt,
            PubInputs.FeeNote({
                feeIn: dec.feeIn, feeAssetId: dec.feeAssetId, feeCm: dec.feeCm, feeCvDep: dec.feeCvDep
            })
        );
    }
}
