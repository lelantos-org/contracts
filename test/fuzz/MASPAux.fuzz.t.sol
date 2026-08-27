// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../../src/BabyJubJub.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { uniformBps } from "../utils/FeeArrays.sol";

/// Fuzz `_validateAux`: bounds-check on every output ciphertext + clue-bits
/// prefix mask. Aux validation runs before the SNARK call — a downstream
/// revert (UnknownAsset / UnknownRoot) confirms aux validation passed, and an
/// aux-specific revert confirms it caught the bad input.
contract MASPAuxFuzzTest is Test {
    uint16 internal constant CLUE_BITS_MASK = 0x3FFF;
    uint256 internal constant MIN_LEN = 2;
    uint256 internal constant MAX_LEN = 256;

    MASP masp;
    address relayer = address(0xAA01);
    address payer = address(0xAA02);
    address recipient = address(0xAA03);

    function setUp() public {
        IVerifier v = IVerifier(address(new MockERC20("v", "v", 18)));
        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        MockBatchVerifier bv = new MockBatchVerifier();
        address permit2 = new DeployPermit2().deployPermit2();
        masp = new MASP(
            tub,
            bv,
            ISignatureTransfer(address(permit2)),
            new uint64[](0),
            new IERC20[](0),
            new uint256[](0),
            uniformBps(0, 0),
            uniformBps(0, 0),
            address(0xfee),
            address(this)
        );
    }

    function _basePi() internal view returns (PubInputs.Transact memory pi) {
        pi.merkleRoot = masp.currentRoot();
        SpendFixture.fillOutputs(pi, 1, 3);
        pi.recipient = recipient;
        pi.chainId = block.chainid;
        pi.payer = payer;
        pi.relayer = relayer;
    }

    function _baseTpi(PubInputs.Transact memory pi) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        return SpendFixture.batchFor(pi, masp.currentRoot(), bytes32(uint256(0xdeadbeef)), masp.committedCount());
    }

    function _aux(bytes memory c0, bytes memory c1) internal pure returns (AuxValidation.Output[4] memory aux) {
        // Slot 0 carries the fuzzed payload under test; the rest carry `c1` so
        // only one slot varies per run.
        aux = SpendFixture.uniformAux(c1);
        aux[0].ciphertext = c0;
    }

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return FixtureLoader.emptyProof();
    }

    /// Valid aux: length within [MIN_LEN, MAX_LEN] and clueBits prefix's top
    /// two bits zero. `_validateAux` must pass; transaction reverts later on
    /// `UnknownAsset` (registry empty).
    function testFuzz_ValidAuxReachesAssetLookup(bytes memory body0, bytes memory body1, uint16 prefix0, uint16 prefix1)
        public
    {
        prefix0 = prefix0 & CLUE_BITS_MASK;
        prefix1 = prefix1 & CLUE_BITS_MASK;

        bytes memory b0 = _truncate(body0, MAX_LEN - 2);
        bytes memory b1 = _truncate(body1, MAX_LEN - 2);

        bytes memory ct0 = abi.encodePacked(prefix0, b0);
        bytes memory ct1 = abi.encodePacked(prefix1, b1);

        PubInputs.Transact memory pi = _basePi();
        PubInputs.TreeUpdateBatch memory tpi = _baseTpi(pi);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(0)));
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _aux(ct0, ct1));
    }

    /// Length below MIN_LEN → CiphertextTooShort; above MAX_LEN → CiphertextTooLong.
    function testFuzz_LengthOutOfBoundsReverts(uint256 badLen, uint256 goodLen, bool badIsFirst, bytes32 fill) public {
        // `badLen` ∈ {0..MIN_LEN-1} ∪ {MAX_LEN+1..1024} — definitively OOB.
        // Half the seeds land below MIN_LEN, half above MAX_LEN.
        if (badLen % 2 == 0) {
            badLen = bound(badLen, 0, MIN_LEN - 1);
        } else {
            badLen = bound(badLen, MAX_LEN + 1, 1024);
        }
        goodLen = bound(goodLen, MIN_LEN, MAX_LEN);

        (uint256 len0, uint256 len1) = badIsFirst ? (badLen, goodLen) : (goodLen, badLen);
        bytes memory ct0 = _fill(len0, fill);
        bytes memory ct1 = _fill(len1, fill);

        PubInputs.Transact memory pi = _basePi();
        PubInputs.TreeUpdateBatch memory tpi = _baseTpi(pi);

        vm.prank(relayer);
        vm.expectRevert(
            badLen < MIN_LEN ? AuxValidation.CiphertextTooShort.selector : AuxValidation.CiphertextTooLong.selector
        );
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _aux(ct0, ct1));
    }

    /// Top two bits of the clueBits prefix non-zero → BadClueBits.
    function testFuzz_BadClueBitsReverts(uint16 dirty, bytes memory body, bool badIsFirst) public {
        uint16 bad = uint16(dirty) | 0x4000;
        bytes memory tail = _truncate(body, MAX_LEN - 2);
        bytes memory good = abi.encodePacked(uint16(0), tail);
        bytes memory badCt = abi.encodePacked(bad, tail);
        (bytes memory ct0, bytes memory ct1) = badIsFirst ? (badCt, good) : (good, badCt);

        PubInputs.Transact memory pi = _basePi();
        PubInputs.TreeUpdateBatch memory tpi = _baseTpi(pi);

        vm.prank(relayer);
        vm.expectRevert(AuxValidation.BadClueBits.selector);
        masp.transfer(_emptyProof(), pi, _emptyProof(), tpi, _aux(ct0, ct1));
    }

    function _truncate(bytes memory b, uint256 maxLen) internal pure returns (bytes memory) {
        if (b.length <= maxLen) return b;
        bytes memory out = new bytes(maxLen);
        for (uint256 i; i < maxLen; ++i) {
            out[i] = b[i];
        }
        return out;
    }

    function _fill(uint256 len, bytes32 seed) internal pure returns (bytes memory out) {
        out = new bytes(len);
        // Reserve first 2 bytes as zero clueBits prefix so length-bound tests
        // are not confounded by prefix-mask reverts.
        for (uint256 i = 2; i < len; ++i) {
            out[i] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i)))));
        }
    }
}
