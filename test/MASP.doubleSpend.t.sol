// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { NullifierSet } from "../src/NullifierSet.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// Cross-transaction double-spend regression.
///
/// Both Groth16 verifiers are mocked to accept any proof so we isolate the
/// nullifier-bitmap logic from circuit correctness. The first `withdraw` call
/// succeeds and marks both nullifiers spent; the second call with the same
/// nullifiers reverts with `DoubleSpend` inside `_consumeNullifier`.
contract MASPDoubleSpendTest is Test {
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 0; // zero fee simplifies balance math

    address internal constant RELAYER = address(0xCA11);
    address internal constant PAYER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xF00D);

    MockERC20 token;
    IVerifier verifier;
    IVerifier tubVerifier;
    MASP masp;

    function setUp() public {
        token = new MockERC20("M", "M", 18);

        // Fake verifier contracts (have code; verifyProof mocked below).
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

        // Mint enough tokens to the pool so the first withdraw can transfer.
        token.mint(address(masp), 100 * SCALE);

        // Force both verifiers to accept any proof.
        vm.mockCall(address(verifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
        vm.mockCall(address(tubVerifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
    }

    // --- helpers -----------------------------------------------------------

    function _aux() internal pure returns (AuxValidation.Output[2] memory aux) {
        aux[0].clueRx = BabyJubJub.BASE8_X;
        aux[0].clueRy = BabyJubJub.BASE8_Y;
        aux[0].ephPubX = BabyJubJub.BASE8_X;
        aux[0].ephPubY = BabyJubJub.BASE8_Y;
        aux[0].ciphertext = hex"0001";
        aux[1].clueRx = BabyJubJub.BASE8_X;
        aux[1].clueRy = BabyJubJub.BASE8_Y;
        aux[1].ephPubX = BabyJubJub.BASE8_X;
        aux[1].ephPubY = BabyJubJub.BASE8_Y;
        aux[1].ciphertext = hex"0001";
    }

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return MASP.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    // Build a withdraw pi / tpi pair that passes _validateRequest with the
    // supplied root state.
    function _makeWithdraw(bytes32 merkleRoot, bytes32 oldRoot, uint64 startIndex, bytes32 newRoot)
        internal
        view
        returns (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi)
    {
        pi.chainId = block.chainid;
        pi.publicAssetId = ASSET_ID;
        pi.publicIn = 0;
        pi.publicOut = 1; // 1 * SCALE tokens unshielded
        pi.recipient = RECIPIENT;
        pi.payer = PAYER;
        pi.relayer = RELAYER;
        pi.nullifier[0] = bytes32(uint256(0x1111));
        pi.nullifier[1] = bytes32(uint256(0x2222));
        pi.outCm[0] = bytes32(uint256(0x3333));
        pi.outCm[1] = bytes32(uint256(0x4444));
        pi.merkleRoot = merkleRoot;
        // outCvDep: all zero

        tpi.oldRoot = oldRoot;
        tpi.newRoot = newRoot;
        tpi.startIndex = startIndex;
        tpi.actualCount = 1;
        tpi.cms[0] = pi.outCm[0];
        tpi.cms[1] = pi.outCm[1];
        // isDeposit[0] = 0 (spend); cvDeps zero
    }

    // --- tests -------------------------------------------------------------

    function test_doubleSpend_secondWithdrawReverts() public {
        bytes32 genesis = masp.currentRoot();

        // First withdraw — succeeds.
        (PubInputs.Transact memory pi1, PubInputs.TreeUpdateBatch memory tpi1) =
            _makeWithdraw(genesis, genesis, 0, bytes32(uint256(0xABCD)));

        vm.prank(RELAYER);
        masp.withdraw(_emptyProof(), pi1, _emptyProof(), tpi1, _aux());

        // Nullifiers now in the spent bitmap; root advanced.
        assertTrue(masp.spent(pi1.nullifier[0]), "nf0 spent after first withdraw");
        assertTrue(masp.spent(pi1.nullifier[1]), "nf1 spent after first withdraw");

        // Second withdraw — same nullifiers, updated root context.
        bytes32 newRoot1 = tpi1.newRoot;
        (PubInputs.Transact memory pi2, PubInputs.TreeUpdateBatch memory tpi2) =
            _makeWithdraw(newRoot1, newRoot1, 2, bytes32(uint256(0xDEAD)));

        vm.prank(RELAYER);
        vm.expectRevert(NullifierSet.DoubleSpend.selector);
        masp.withdraw(_emptyProof(), pi2, _emptyProof(), tpi2, _aux());
    }

    /// Nullifier 0 and 1 are independent: consuming nf0 does not mark nf1.
    function test_afterFirstWithdraw_onlyConsumedNullifiersSpent() public {
        bytes32 genesis = masp.currentRoot();
        bytes32 unrelated = bytes32(uint256(0x9999));
        assertFalse(masp.spent(unrelated));

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) =
            _makeWithdraw(genesis, genesis, 0, bytes32(uint256(0xABCD)));

        vm.prank(RELAYER);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, _aux());

        assertTrue(masp.spent(pi.nullifier[0]));
        assertTrue(masp.spent(pi.nullifier[1]));
        assertFalse(masp.spent(unrelated));
    }

    /// Fuzz: any pair of distinct nullifiers survives one withdraw then fails
    /// on a second withdraw with the same pair.
    function testFuzz_doubleSpend(bytes32 nf0, bytes32 nf1) public {
        // PubInputs.compress treats nullifiers as BN254 field elements.
        // Values >= R revert with CoefficientOutOfField before the mocked
        // verifier is reached; bound both to the valid field range.
        uint256 R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        nf0 = bytes32(uint256(nf0) % R);
        nf1 = bytes32(uint256(nf1) % R);
        vm.assume(nf0 != nf1); // prevent DuplicateNullifier

        bytes32 genesis = masp.currentRoot();

        PubInputs.Transact memory pi;
        pi.chainId = block.chainid;
        pi.publicAssetId = ASSET_ID;
        pi.publicIn = 0;
        pi.publicOut = 1;
        pi.recipient = RECIPIENT;
        pi.payer = PAYER;
        pi.relayer = RELAYER;
        pi.nullifier[0] = nf0;
        pi.nullifier[1] = nf1;
        pi.outCm[0] = bytes32(uint256(0x3333));
        pi.outCm[1] = bytes32(uint256(0x4444));
        pi.merkleRoot = genesis;

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = genesis;
        tpi.newRoot = bytes32(uint256(0xABCD));
        tpi.startIndex = 0;
        tpi.actualCount = 1;
        tpi.cms[0] = pi.outCm[0];
        tpi.cms[1] = pi.outCm[1];

        vm.prank(RELAYER);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, _aux());

        // Update root context for second call.
        bytes32 newRoot1 = tpi.newRoot;
        pi.merkleRoot = newRoot1;
        tpi.oldRoot = newRoot1;
        tpi.newRoot = bytes32(uint256(0xDEAD));
        tpi.startIndex = 2;

        vm.prank(RELAYER);
        vm.expectRevert(NullifierSet.DoubleSpend.selector);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, _aux());
    }
}
