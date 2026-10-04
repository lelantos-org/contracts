// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { deployPoolUniform, realVerifierStack, singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";
import { EscrowLogs } from "../utils/EscrowLogs.sol";

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
        bytes32 inner;
        uint32 submittedAt;
        uint48 feeIn;
        uint64 feeAssetId;
        bytes32 feeInner;
        uint256 pulled;
    }

    /// The non-indexed body of `DepositEscrowed`, in declaration order:
    /// eighteen parameters. Each note is described by its asset, amount and
    /// `inner`, from which the batch circuit, and an indexer rebuilding the
    /// tree, computes the leaf.
    ///
    /// Decoded as a struct rather than a positional tuple: the body spans two
    /// `bytes` members, so the fee fields sit past the first dynamic offset
    /// and cannot be read by truncating the head.
    struct EscrowLog {
        uint64 publicAssetId;
        uint64 publicIn;
        uint16 feeBpsAtSubmit;
        bytes32 inner;
        uint256 clueRx;
        uint256 clueRy;
        uint256 ephPubX;
        uint256 ephPubY;
        bytes ciphertext;
        uint64 feeAssetId;
        uint64 feeIn;
        bytes32 feeInner;
        uint256 feeClueRx;
        uint256 feeClueRy;
        uint256 feeEphPubX;
        uint256 feeEphPubY;
        bytes feeCiphertext;
        uint256 pulled;
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

    /// Head words of the event data: one per non-indexed parameter.
    uint256 internal constant BODY_WORDS = 18;

    /// The event's signature, written out so a change to the parameter list
    /// fails here rather than moving with `MASP.DepositEscrowed.selector`.
    function _escrowedTopic() internal pure returns (bytes32 topic) {
        topic = keccak256(
            "DepositEscrowed(uint256,address,address,uint64,uint64,uint16,bytes32,uint256,uint256,"
            "uint256,uint256,bytes,uint64,uint64,bytes32,uint256,uint256,uint256,uint256,bytes,uint256)"
        );
        assertEq(topic, MASP.DepositEscrowed.selector, "DepositEscrowed signature");
    }

    /// The deposit `_submitAndDecode` submits.
    function _request(uint64 publicIn, uint256 nonce) internal view returns (PubInputs.DepositRequest memory) {
        return DepositFixture.request(ASSET_ID, publicIn, payer, recipient, bytes32(uint256(0x111 + nonce)));
    }

    /// Decodes the event body. Event data is the parameter tuple encoded
    /// inline, but decoding into a dynamic struct expects a leading offset to
    /// it. One is prepended; decoding 18 positional values exceeds the stack
    /// limit.
    function _body(bytes memory data) internal pure returns (EscrowLog memory) {
        return abi.decode(bytes.concat(abi.encode(uint256(0x20)), data), (EscrowLog));
    }

    /// Submits a deposit and recovers the cancel preimage from the log alone.
    function _submitAndDecode(uint64 publicIn, uint256 nonce) internal returns (Decoded memory dec) {
        uint256 inAmt = uint256(publicIn) * SCALE;
        (uint16 depBps,) = masp.assetFees(ASSET_ID);
        token.mint(payer, inAmt + (inAmt * depBps) / 10_000);

        PubInputs.DepositRequest memory d = _request(publicIn, nonce);

        vm.recordLogs();
        masp.deposit(d, DepositFixture.sig(nonce), SpendFixture.validAuxOutput(), SpendFixture.validAuxOutput());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sigHash = _escrowedTopic();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(masp) || logs[i].topics[0] != sigHash) continue;
            found = true;
            dec.id = uint256(logs[i].topics[1]);
            dec.payer = address(uint160(uint256(logs[i].topics[2])));
            EscrowLog memory body = _body(logs[i].data);
            dec.publicAssetId = body.publicAssetId;
            dec.publicIn = body.publicIn;
            dec.feeBpsAtSubmit = body.feeBpsAtSubmit;
            dec.inner = body.inner;
            // The relayer's leaf is part of the digest, so a canceller needs it
            // from the log too.
            // forge-lint: disable-next-line(unsafe-typecast)
            dec.feeIn = uint48(body.feeIn);
            dec.feeAssetId = body.feeAssetId;
            dec.feeInner = body.feeInner;
            // The refund cap closes the preimage. Zero here: the asset is plain.
            dec.pulled = body.pulled;
        }
        assertTrue(found, "DepositEscrowed not emitted");
        // The remaining preimage field is the emitting block.
        dec.submittedAt = uint32(block.number);
    }

    /// The event's shape, field by field: three indexed topics, then eighteen
    /// head words carrying the request and both aux payloads verbatim, each
    /// note's clue directly after its `inner`.
    function test_depositEscrowed_shapeAndContents() public {
        uint64 publicIn = 100;
        uint256 nonce = 7;
        token.mint(payer, type(uint128).max);
        PubInputs.DepositRequest memory d = _request(publicIn, nonce);
        // Distinct payloads, so a swapped pair of fields is visible.
        AuxValidation.Output memory aux = SpendFixture.validAuxOutput();
        aux.ciphertext = hex"0001aabbcc";
        AuxValidation.Output memory feeAux = SpendFixture.validAuxOutput();
        feeAux.ciphertext = hex"0002ddeeff0011";

        vm.recordLogs();
        uint256 id = masp.deposit(d, DepositFixture.sig(nonce), aux, feeAux);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = _escrowedTopic();
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(masp) || logs[i].topics[0] != topic) continue;
            ++found;

            assertEq(logs[i].topics.length, 4, "signature plus three indexed parameters");
            assertEq(uint256(logs[i].topics[1]), id, "id topic");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), payer, "payer topic");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), recipient, "recipient topic");

            // The first `bytes` member's offset is the size of the head, which
            // is one word per non-indexed parameter.
            bytes memory data = logs[i].data;
            uint256 firstDynamicOffset;
            assembly ("memory-safe") {
                firstDynamicOffset := mload(add(data, mul(9, 0x20)))
            }
            assertEq(firstDynamicOffset, BODY_WORDS * 0x20, "eighteen non-indexed parameters");

            EscrowLog memory body = _body(data);
            assertEq(body.publicAssetId, ASSET_ID, "publicAssetId");
            assertEq(body.publicIn, publicIn, "publicIn");
            assertEq(body.feeBpsAtSubmit, FEE_BPS, "feeBpsAtSubmit");
            assertEq(body.inner, d.inner, "inner");
            assertEq(body.clueRx, aux.clueRx, "clueRx");
            assertEq(body.clueRy, aux.clueRy, "clueRy");
            assertEq(body.ephPubX, aux.ephPubX, "ephPubX");
            assertEq(body.ephPubY, aux.ephPubY, "ephPubY");
            assertEq(body.ciphertext, aux.ciphertext, "ciphertext");
            assertEq(body.feeAssetId, 0, "feeAssetId of a zero-value note");
            assertEq(body.feeIn, 0, "feeIn");
            assertEq(body.feeInner, d.feeInner, "feeInner");
            assertEq(body.feeClueRx, feeAux.clueRx, "feeClueRx");
            assertEq(body.feeClueRy, feeAux.clueRy, "feeClueRy");
            assertEq(body.feeEphPubX, feeAux.ephPubX, "feeEphPubX");
            assertEq(body.feeEphPubY, feeAux.ephPubY, "feeEphPubY");
            assertEq(body.feeCiphertext, feeAux.ciphertext, "feeCiphertext");
            assertEq(body.pulled, 0, "no refund cap on a plain asset");
            // Zero on both sides here, so this only shows the reader finds the
            // log. `YieldEscrowTest.test_cap_isThePullAndIsPublishedInTheEvent`
            // checks it against a non-zero pull.
            assertEq(EscrowLogs.pulled(logs, address(masp), id), body.pulled, "EscrowLogs reads the same word");
        }
        assertEq(found, 1, "one DepositEscrowed");
    }

    /// Cancels with the preimage recovered from the log, naming `fbps` as the
    /// submit-time fee. The only external call, so a prank or expectation set
    /// just before applies to the cancel itself.
    function _cancelFromLog(Decoded memory dec, uint16 fbps) internal {
        masp.cancelDeposit(
            dec.id,
            uint48(dec.publicIn),
            dec.inner,
            dec.publicAssetId,
            fbps,
            dec.payer,
            dec.submittedAt,
            PubInputs.FeeNote({ feeIn: dec.feeIn, feeAssetId: dec.feeAssetId, feeInner: dec.feeInner }),
            dec.pulled
        );
    }

    /// A canceller holding only the log and its block number can produce a
    /// preimage that satisfies `escrowed[id]`.
    function test_cancelDeposit_reconstructedFromEventOnly() public {
        uint64 publicIn = 100;
        Decoded memory dec = _submitAndDecode(publicIn, 0);

        assertEq(dec.publicAssetId, ASSET_ID, "assetId from log");
        assertEq(dec.publicIn, publicIn, "publicIn from log");
        assertEq(dec.feeBpsAtSubmit, FEE_BPS, "feeBps from log");
        assertEq(dec.payer, payer, "payer from log");

        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 expected = inAmt + (inAmt * FEE_BPS) / 10_000;

        vm.roll(block.number + masp.cancelDelay());
        uint256 before = token.balanceOf(payer);

        // The fixture payer is an etched ERC-1271 stub, so MASP treats it as a
        // contract payer and only it may cancel; the unrelated-caller case is
        // covered for EOA payers in MASP.cancelDeposit.t.sol.
        vm.prank(payer);
        _cancelFromLog(dec, dec.feeBpsAtSubmit);

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
        _cancelFromLog(dec, dec.feeBpsAtSubmit);

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
        _cancelFromLog(dec, maxFee);
    }
}
