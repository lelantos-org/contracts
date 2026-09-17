// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { MockPoolTestBase } from "../utils/MockPoolTestBase.sol";
import { noAssets } from "../utils/PoolDeployer.sol";

/// Boundary tests for `AuxValidation.validate`. The fuzz suite covers the
/// interior; the exact endpoints (MIN, MAX, MIN-1, MAX+1, every clueBits
/// upper-bit pattern) have named tests.
contract MASPBoundariesTest is MockPoolTestBase {
    uint16 internal constant CLUE_BITS_MASK = 0x3FFF;

    address relayer = address(0xAA01);

    function setUp() public {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = noAssets();
        _deployMockPool(ids, tokens, scales, 0, address(0xfee), address(this));
    }

    function _pi() internal view returns (PubInputs.Transact memory pi) {
        pi = _transact(address(0xAA02), relayer, 1, 3);
        pi.recipient = address(0xAA03);
    }

    function _aux(bytes memory c0, bytes memory c1) internal pure returns (AuxValidation.Output[6] memory a) {
        // Slots past the two under test keep a valid minimal ciphertext, so the
        // bound being probed is the one that reverts.
        a = SpendFixture.uniformAux(hex"0000");
        a[0].ciphertext = c0;
        a[1].ciphertext = c1;
    }

    function _validCt(uint256 len) internal pure returns (bytes memory ct) {
        require(len >= 2, "len < 2 invalid");
        ct = new bytes(len);
    }

    /// With valid aux, `transfer` reaches the asset lookup and reverts
    /// `UnknownAsset(0)` (the registry is empty), showing aux validation passed.
    function _expectAuxAccepted(bytes memory c0, bytes memory c1) internal {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        AuxValidation.Output[6] memory aux = _aux(c0, c1);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(0)));
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, aux);
    }

    function _expectCtLenRevert(bytes memory c0, bytes memory c1, bytes4 expected) internal {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        AuxValidation.Output[6] memory aux = _aux(c0, c1);
        vm.prank(relayer);
        vm.expectRevert(expected);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, aux);
    }

    function _expectCtTooShort(bytes memory c0, bytes memory c1) internal {
        _expectCtLenRevert(c0, c1, AuxValidation.CiphertextTooShort.selector);
    }

    function _expectCtTooLong(bytes memory c0, bytes memory c1) internal {
        _expectCtLenRevert(c0, c1, AuxValidation.CiphertextTooLong.selector);
    }

    function _expectBadClueBits(bytes memory c0, bytes memory c1) internal {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        AuxValidation.Output[6] memory aux = _aux(c0, c1);
        vm.prank(relayer);
        vm.expectRevert(AuxValidation.BadClueBits.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, aux);
    }

    // --- length boundaries ----------------------------------------------------

    function test_ciphertextLenMinAccepted() public {
        _expectAuxAccepted(_validCt(2), _validCt(2));
    }

    function test_ciphertextLenMaxAccepted() public {
        _expectAuxAccepted(_validCt(256), _validCt(256));
    }

    function test_ciphertextLenZeroRejected() public {
        _expectCtTooShort(new bytes(0), _validCt(2));
    }

    function test_ciphertextLenOneRejected() public {
        _expectCtTooShort(new bytes(1), _validCt(2));
    }

    function test_ciphertextLenMaxPlusOneRejected() public {
        _expectCtTooLong(_validCt(257), _validCt(2));
    }

    function test_ciphertextLenSlot1OutOfRange() public {
        _expectCtTooLong(_validCt(2), _validCt(1024));
    }

    // --- clueBits prefix boundaries ------------------------------------------

    function _ctWithPrefix(uint16 prefix, uint256 bodyLen) internal pure returns (bytes memory ct) {
        ct = new bytes(2 + bodyLen);
        ct[0] = bytes1(uint8(prefix >> 8));
        ct[1] = bytes1(uint8(prefix & 0xff));
    }

    function test_clueBitsAllZeroAccepted() public {
        _expectAuxAccepted(_ctWithPrefix(0x0000, 0), _ctWithPrefix(0x0000, 0));
    }

    function test_clueBitsMaxAccepted() public {
        _expectAuxAccepted(_ctWithPrefix(0x3FFF, 10), _ctWithPrefix(0x3FFF, 10));
    }

    function test_clueBitsBit14Rejected() public {
        _expectBadClueBits(_ctWithPrefix(0x4000, 10), _ctWithPrefix(0x0000, 10));
    }

    function test_clueBitsBit15Rejected() public {
        _expectBadClueBits(_ctWithPrefix(0x8000, 10), _ctWithPrefix(0x0000, 10));
    }

    function test_clueBitsBothUpperBitsRejected() public {
        _expectBadClueBits(_ctWithPrefix(0xC000, 10), _ctWithPrefix(0x0000, 10));
    }

    function test_clueBitsAllOnesRejected() public {
        _expectBadClueBits(_ctWithPrefix(0xFFFF, 10), _ctWithPrefix(0x0000, 10));
    }

    function test_clueBitsSlot1Rejected() public {
        _expectBadClueBits(_ctWithPrefix(0x0000, 10), _ctWithPrefix(0x4000, 10));
    }

    // --- on-curve boundaries -------------------------------------------------

    function _expectOffCurve(AuxValidation.Output[6] memory aux) internal {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(relayer);
        vm.expectRevert(AuxValidation.OffCurvePoint.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, aux);
    }

    /// Clue R of (BASE8_X, 0) is off-curve and rejected.
    function test_clueRZeroZeroRejected() public {
        AuxValidation.Output[6] memory aux = _aux(_validCt(2), _validCt(2));
        aux[0].clueRy = 0;
        _expectOffCurve(aux);
    }

    /// Ephemeral key of (BASE8_X, 0) is off-curve and rejected.
    function test_ephPubZeroZeroRejected() public {
        AuxValidation.Output[6] memory aux = _aux(_validCt(2), _validCt(2));
        aux[0].ephPubY = 0;
        _expectOffCurve(aux);
    }

    /// A coordinate >= P is rejected by the `BabyJubJub.isOnCurve` range guard.
    function test_clueRCoordOverPRejected() public {
        AuxValidation.Output[6] memory aux = _aux(_validCt(2), _validCt(2));
        aux[1].clueRx = type(uint256).max;
        aux[2].clueRx = type(uint256).max;
        aux[3].clueRx = type(uint256).max;
        _expectOffCurve(aux);
    }

    /// Off-curve ephemeral keys in slots 1-3 are rejected.
    function test_ephPubSlot1OffCurveRejected() public {
        AuxValidation.Output[6] memory aux = _aux(_validCt(2), _validCt(2));
        aux[1].ephPubX = 1;
        aux[1].ephPubY = 1;
        aux[2].ephPubX = 1;
        aux[2].ephPubY = 1;
        aux[3].ephPubX = 1;
        aux[3].ephPubY = 1;
        _expectOffCurve(aux);
    }
}
