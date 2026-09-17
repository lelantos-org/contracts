// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { NullifierSet } from "../../src/NullifierSet.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { MockPoolTestBase } from "../utils/MockPoolTestBase.sol";
import { singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";

/// Cross-transaction double-spend.
///
/// Both Groth16 verifiers are mocked to accept any proof, isolating the
/// nullifier-bitmap logic from circuit correctness. The first `withdraw` call
/// succeeds and marks its nullifiers spent; a second call with the same
/// nullifiers reverts with `DoubleSpend` inside `_consumeNullifier`.
contract MASPDoubleSpendTest is MockPoolTestBase {
    uint16 internal constant FEE_BPS = 0; // zero fee simplifies balance math

    address internal constant PAYER = address(0xBEEF);

    function setUp() public {
        token = new MockERC20("M", "M", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        _deployMockPool(ids, tokens, scales, FEE_BPS, address(0xfee), address(this));

        // Funds the pool so the first withdraw can transfer.
        token.mint(address(masp), 100 * SCALE);

        Stubs.acceptAllProofs(tub, bv);
    }

    // --- helpers -----------------------------------------------------------

    // Builds a withdraw pi / tpi pair that passes _validateRequest with the
    // supplied root state.
    function _makeWithdraw(bytes32 merkleRoot, uint8 anchorIndex, uint64 startIndex, bytes32 newRoot)
        internal
        view
        returns (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi)
    {
        pi = _transact(PAYER, RELAYER, 0x1111, 0x3333);
        pi.publicAssetId = ASSET_ID;
        pi.publicOut = 1; // 1 * SCALE tokens unshielded
        pi.merkleRoot = merkleRoot;
        tpi = SpendFixture.spendTree(newRoot, startIndex, anchorIndex);
    }

    // --- tests -------------------------------------------------------------

    function test_doubleSpend_secondWithdrawReverts() public {
        bytes32 genesis = masp.currentRoot();

        // First withdraw succeeds.
        (PubInputs.Transact memory pi1, PubInputs.SpendTree memory tpi1) =
            _makeWithdraw(genesis, 0, 0, bytes32(uint256(0xABCD)));

        vm.prank(RELAYER);
        masp.withdraw(FixtureLoader.emptyProof(), pi1, FixtureLoader.emptyProof(), tpi1, SpendFixture.validAux());

        // Nullifiers are in the spent bitmap; the root has advanced.
        assertTrue(masp.spent(pi1.nullifier[0]), "nf0 spent after first withdraw");
        assertTrue(masp.spent(pi1.nullifier[1]), "nf1 spent after first withdraw");

        // Second withdraw: same nullifiers, updated root context.
        bytes32 newRoot1 = tpi1.newRoot;
        (PubInputs.Transact memory pi2, PubInputs.SpendTree memory tpi2) =
            _makeWithdraw(newRoot1, 1, uint64(PubInputs.TRANSACT_OUT), bytes32(uint256(0xDEAD)));

        vm.prank(RELAYER);
        vm.expectRevert(NullifierSet.DoubleSpend.selector);
        masp.withdraw(FixtureLoader.emptyProof(), pi2, FixtureLoader.emptyProof(), tpi2, SpendFixture.validAux());
    }

    /// A withdraw marks only its own nullifiers spent; an unrelated nullifier
    /// stays unspent.
    function test_afterFirstWithdraw_onlyConsumedNullifiersSpent() public {
        bytes32 genesis = masp.currentRoot();
        bytes32 unrelated = bytes32(uint256(0x9999));
        assertFalse(masp.spent(unrelated));

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) =
            _makeWithdraw(genesis, 0, 0, bytes32(uint256(0xABCD)));

        vm.prank(RELAYER);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());

        assertTrue(masp.spent(pi.nullifier[0]));
        assertTrue(masp.spent(pi.nullifier[1]));
        assertFalse(masp.spent(unrelated));
    }

    /// Fuzz: any pair of distinct nullifiers survives one withdraw then fails
    /// on a second withdraw with the same pair.
    function testFuzz_doubleSpend(bytes32 nf0, bytes32 nf1) public {
        // PubInputs.compress treats nullifiers as BN254 field elements.
        // Values >= R revert with CoefficientOutOfField before the mocked
        // verifier is reached, so both are reduced into the field.
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
        // Remaining slots are padding: distinct from both fuzzed values so the
        // pairwise check targets the nf0/nf1 relationship under test, and
        // reduced into the field for the same reason nf0/nf1 are.
        uint256 pad = uint256(keccak256(abi.encode(nf0, nf1))) % R;
        for (uint256 k = 2; k < pi.nullifier.length; ++k) {
            pi.nullifier[k] = bytes32((pad + k - 2) % R);
        }
        SpendFixture.fillCommitments(pi, 0x3333);
        pi.merkleRoot = genesis;

        PubInputs.SpendTree memory tpi = SpendFixture.spendTree(bytes32(uint256(0xABCD)), 0);

        vm.prank(RELAYER);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());

        // Updates the root context for the second call.
        bytes32 newRoot1 = tpi.newRoot;
        pi.merkleRoot = newRoot1;
        tpi.anchorIndex = 1;
        tpi.newRoot = bytes32(uint256(0xDEAD));
        tpi.startIndex = uint64(PubInputs.TRANSACT_OUT);

        vm.prank(RELAYER);
        vm.expectRevert(NullifierSet.DoubleSpend.selector);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }
}
