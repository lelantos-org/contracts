// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { AssetRegistry } from "../src/AssetRegistry.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// Explicit boundary unit tests for `_validateAux` — the fuzz suite covers
/// the interior, but exact endpoints (MIN, MAX, MIN-1, MAX+1, every clueBits
/// upper-bit pattern) deserve named regression tests.
contract MASPBoundariesTest is Test {
    uint16 internal constant CLUE_BITS_MASK = 0x3FFF;

    MASP masp;
    address relayer = address(0xAA01);

    function setUp() public {
        IVerifier v = IVerifier(address(new MockERC20("v", "v", 18)));
        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        address permit2 = new DeployPermit2().deployPermit2();
        masp = new MASP(
            v,
            tub,
            ISignatureTransfer(address(permit2)),
            new uint64[](0),
            new IERC20[](0),
            new uint256[](0),
            0,
            address(0xfee),
            address(this)
        );
    }

    function _pi() internal view returns (PubInputs.Transact memory pi) {
        pi.merkleRoot = masp.currentRoot();
        pi.nullifier[0] = bytes32(uint256(1));
        pi.nullifier[1] = bytes32(uint256(2));
        pi.nullifier[2] = bytes32(uint256(3));
        pi.outCm[0] = bytes32(uint256(3));
        pi.outCm[1] = bytes32(uint256(4));
        pi.outCm[2] = bytes32(uint256(5));
        pi.recipient = address(0xAA03);
        pi.chainId = block.chainid;
        pi.payer = address(0xAA02);
        pi.relayer = relayer;
    }

    function _tpi(PubInputs.Transact memory pi) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = 3;
        tpi.cms[0] = pi.outCm[0];
        tpi.cms[1] = pi.outCm[1];
        tpi.cms[2] = pi.outCm[2];
    }

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return MASP.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    function _aux(bytes memory c0, bytes memory c1) internal pure returns (AuxValidation.Output[3] memory a) {
        a[0].clueRx = BabyJubJub.BASE8_X;
        a[0].clueRy = BabyJubJub.BASE8_Y;
        a[0].ephPubX = BabyJubJub.BASE8_X;
        a[0].ephPubY = BabyJubJub.BASE8_Y;
        a[1].clueRx = BabyJubJub.BASE8_X;
        a[1].clueRy = BabyJubJub.BASE8_Y;
        a[1].ephPubX = BabyJubJub.BASE8_X;
        a[1].ephPubY = BabyJubJub.BASE8_Y;
        a[2].clueRx = BabyJubJub.BASE8_X;
        a[2].clueRy = BabyJubJub.BASE8_Y;
        a[2].ephPubX = BabyJubJub.BASE8_X;
        a[2].ephPubY = BabyJubJub.BASE8_Y;
        a[0].ciphertext = c0;
        a[1].ciphertext = c1;
        // Third output is not under test here; keep it valid so the bound
        // being probed is the one that reverts.
        a[2].ciphertext = hex"0000";
    }

    function _validCt(uint256 len) internal pure returns (bytes memory ct) {
        require(len >= 2, "len < 2 invalid");
        ct = new bytes(len);
    }

    /// Calling transact with valid aux must reach asset lookup → reverts
    /// UnknownAsset(0) (registry empty), proving `_validateAux` accepted input.
    function _expectAuxAccepted(bytes memory c0, bytes memory c1) internal {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        AuxValidation.Output[3] memory aux = _aux(c0, c1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(0)));
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, aux);
    }

    function _expectCtLenRevert(bytes memory c0, bytes memory c1, bytes4 expected) internal {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        AuxValidation.Output[3] memory aux = _aux(c0, c1);
        vm.prank(relayer);
        vm.expectRevert(expected);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, aux);
    }

    function _expectCtTooShort(bytes memory c0, bytes memory c1) internal {
        _expectCtLenRevert(c0, c1, AuxValidation.CiphertextTooShort.selector);
    }

    function _expectCtTooLong(bytes memory c0, bytes memory c1) internal {
        _expectCtLenRevert(c0, c1, AuxValidation.CiphertextTooLong.selector);
    }

    function _expectBadClueBits(bytes memory c0, bytes memory c1) internal {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        AuxValidation.Output[3] memory aux = _aux(c0, c1);
        vm.prank(relayer);
        vm.expectRevert(AuxValidation.BadClueBits.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, aux);
    }

    // --- length boundaries ----------------------------------------------------

    function testCiphertextLenMinAccepted() public {
        _expectAuxAccepted(_validCt(2), _validCt(2));
    }

    function testCiphertextLenMaxAccepted() public {
        _expectAuxAccepted(_validCt(256), _validCt(256));
    }

    function testCiphertextLenZeroRejected() public {
        _expectCtTooShort(new bytes(0), _validCt(2));
    }

    function testCiphertextLenOneRejected() public {
        _expectCtTooShort(new bytes(1), _validCt(2));
    }

    function testCiphertextLenMaxPlusOneRejected() public {
        _expectCtTooLong(_validCt(257), _validCt(2));
    }

    function testCiphertextLenSlot1OutOfRange() public {
        _expectCtTooLong(_validCt(2), _validCt(1024));
    }

    // --- clueBits prefix boundaries ------------------------------------------

    function _ctWithPrefix(uint16 prefix, uint256 bodyLen) internal pure returns (bytes memory ct) {
        ct = new bytes(2 + bodyLen);
        ct[0] = bytes1(uint8(prefix >> 8));
        ct[1] = bytes1(uint8(prefix & 0xff));
    }

    function testClueBitsAllZeroAccepted() public {
        _expectAuxAccepted(_ctWithPrefix(0x0000, 0), _ctWithPrefix(0x0000, 0));
    }

    function testClueBitsMaxAccepted() public {
        _expectAuxAccepted(_ctWithPrefix(0x3FFF, 10), _ctWithPrefix(0x3FFF, 10));
    }

    function testClueBitsBit14Rejected() public {
        _expectBadClueBits(_ctWithPrefix(0x4000, 10), _ctWithPrefix(0x0000, 10));
    }

    function testClueBitsBit15Rejected() public {
        _expectBadClueBits(_ctWithPrefix(0x8000, 10), _ctWithPrefix(0x0000, 10));
    }

    function testClueBitsBothUpperBitsRejected() public {
        _expectBadClueBits(_ctWithPrefix(0xC000, 10), _ctWithPrefix(0x0000, 10));
    }

    function testClueBitsAllOnesRejected() public {
        _expectBadClueBits(_ctWithPrefix(0xFFFF, 10), _ctWithPrefix(0x0000, 10));
    }

    function testClueBitsSlot1Rejected() public {
        _expectBadClueBits(_ctWithPrefix(0x0000, 10), _ctWithPrefix(0x4000, 10));
    }

    // --- on-curve boundaries -------------------------------------------------

    function _expectOffCurve(AuxValidation.Output[3] memory aux) internal {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.prank(relayer);
        vm.expectRevert(AuxValidation.OffCurvePoint.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, aux);
    }

    /// (0, 0) is off-curve (a*0 + 0 != 1) — clue R rejected.
    function testClueRZeroZeroRejected() public {
        AuxValidation.Output[3] memory aux = _aux(_validCt(2), _validCt(2));
        aux[0].clueRy = 0;
        _expectOffCurve(aux);
    }

    /// Eph pub off-curve — rejected.
    function testEphPubZeroZeroRejected() public {
        AuxValidation.Output[3] memory aux = _aux(_validCt(2), _validCt(2));
        aux[0].ephPubY = 0;
        _expectOffCurve(aux);
    }

    /// Coordinate >= P — rejected via BabyJubJub.isOnCurve guard.
    function testClueRCoordOverPRejected() public {
        AuxValidation.Output[3] memory aux = _aux(_validCt(2), _validCt(2));
        aux[1].clueRx = type(uint256).max;
        aux[2].clueRx = type(uint256).max;
        _expectOffCurve(aux);
    }

    /// Slot 1 eph pub off-curve — rejected.
    function testEphPubSlot1OffCurveRejected() public {
        AuxValidation.Output[3] memory aux = _aux(_validCt(2), _validCt(2));
        aux[1].ephPubX = 1;
        aux[1].ephPubY = 1;
        aux[2].ephPubX = 1;
        aux[2].ephPubY = 1;
        _expectOffCurve(aux);
    }
}
