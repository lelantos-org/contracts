// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { MaspFlowFixture } from "../utils/MaspFlowFixture.sol";
import { deployPoolUniform, realVerifierStack, singleAsset } from "../utils/PoolDeployer.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// Spend-path chainId enforcement.
///
/// Deposit-path `BadChainId` is covered in MASP.deposit.t.sol. The spend path
/// (`transfer`, `withdraw`) routes through `_validateRequest`, which requires
/// `pi.chainId == block.chainid` before proof verification. The challenge
/// preimage hashes `chainId` into z, so a mismatch between calldata
/// `pi.chainId` and the chainId the proof was made for also fails proof
/// verification (z mismatch, `ProofRejected`). This file covers both checks.
///
/// The second needs a proof that verifies on its own chain:
/// `test_revert_CrossChainReplay` replays the transfer of
/// `test/fixtures/masp_flow_proof.json`, regenerated with
/// `script/fixtures/gen_masp_fixture.sh`.
contract MASPChainIdTest is Test {
    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;
    uint256 internal constant SCALE = TestConstants.SCALE;
    /// The pool charges no fees here; none is the subject.
    uint16 internal constant FEE_BPS = 0;
    address internal constant RELAYER = TestConstants.RELAYER;
    address permit2;
    MockERC20 token;
    MASP masp;

    function setUp() public {
        (IVerifier tub, IBatchVerifier bv, ISignatureTransfer p2) = realVerifierStack();
        permit2 = address(p2);
        token = new MockERC20("M", "M", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        masp = deployPoolUniform(tub, bv, p2, ids, tokens, scales, FEE_BPS, address(0xfee), address(this));
    }

    /// A well-formed spend request on this chain: it passes every check of
    /// `_validateRequest` and reaches proof verification.
    function _request() internal view returns (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) {
        pi.chainId = block.chainid;
        pi.recipient = TestConstants.RECIPIENT;
        pi.payer = address(0xBEEF);
        pi.relayer = RELAYER;
        SpendFixture.fillOutputs(pi, 0x1111, 0x3333);
        pi.merkleRoot = masp.currentRoot();
        tpi = SpendFixture.spendTree(bytes32(uint256(0xdead)), masp.committedCount(), uint8(masp.rootIndex()));
    }

    /// A spend whose `pi.chainId` differs from `block.chainid` reverts at the
    /// `_validateRequest` gate, before any proof check.
    ///
    /// The gate needs no verifying proof, so the request is built here rather
    /// than loaded: with the chain id right, the same request gets as far as
    /// the real verifier and is rejected there; with it wrong, on either entry
    /// point, it never does.
    function test_revert_BadChainId_spend() public {
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _request();
        MASP.Proof memory proof = FixtureLoader.emptyProof();
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();

        // Control: the request is otherwise valid, so only the proof fails.
        vm.prank(RELAYER);
        vm.expectRevert(MASP.ProofRejected.selector);
        masp.transfer(proof, pi, proof, tpi, aux);

        pi.chainId = block.chainid + 1;
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BadChainId.selector);
        masp.transfer(proof, pi, proof, tpi, aux);

        pi.publicAssetId = ASSET_ID;
        pi.publicOut = 1;
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BadChainId.selector);
        masp.withdraw(proof, pi, proof, tpi, aux);
    }

    /// `chainId` is a full word in the request, matching `block.chainid`: a
    /// value equal to this chain's in its low bits only is another chain.
    function test_revert_BadChainId_spend_highBitsSet() public {
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _request();
        pi.chainId = block.chainid | (1 << 255);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.BadChainId.selector);
        masp.transfer(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// Cross-chain replay: a transfer proven and accepted on one chain is
    /// resubmitted after a fork to a new chainid, against the same pool state.
    ///
    /// Replayed verbatim it carries the original chain id and stops at the
    /// `BadChainId` gate. Rewritten to claim the new chain it passes the gate,
    /// but the proof was made for the original chainId, so the recomputed z
    /// (which hashes the new chainId) differs from the prover's z and
    /// verification fails with `ProofRejected`.
    function test_revert_CrossChainReplay() public {
        string memory j = MaspFlowFixture.read();
        uint256 fixtureChainId = MaspFlowFixture.chainId(j);
        uint256 forkedChainId = fixtureChainId + 7;

        // The tree state the spend was proven against, reached on the home
        // chain through `deposit` and `flushBatch` with the real batch proof.
        vm.chainId(fixtureChainId);
        MaspFlowFixture.seedTree(
            masp, token, MaspFlowFixture.flush(j), TestConstants.ESCROW_PAYER, address(0xb0b), SCALE, FEE_BPS
        );
        MaspFlowFixture.Spend memory s = MaspFlowFixture.spend(j, ".transfer");
        s.tpi.anchorIndex = uint8(masp.rootIndex());
        assertEq(s.pi.chainId, fixtureChainId, "proven for the home chain");

        vm.chainId(forkedChainId);

        // Replayed as proven.
        vm.prank(s.pi.relayer);
        vm.expectRevert(MASP.BadChainId.selector);
        masp.transfer(s.txProof, s.pi, s.tubProof, s.tpi, s.aux);

        // Rewritten to claim the new chain.
        s.pi.chainId = forkedChainId;
        vm.prank(s.pi.relayer);
        vm.expectRevert(MASP.ProofRejected.selector);
        masp.transfer(s.txProof, s.pi, s.tubProof, s.tpi, s.aux);
        assertFalse(masp.spent(s.pi.nullifier[0]), "note unspent on the fork");

        // Control: back on the home chain the request as proven is accepted,
        // so the chain id alone caused both rejections above.
        vm.chainId(fixtureChainId);
        s.pi.chainId = fixtureChainId;
        vm.prank(s.pi.relayer);
        masp.transfer(s.txProof, s.pi, s.tubProof, s.tpi, s.aux);
        assertEq(masp.currentRoot(), s.tpi.newRoot, "accepted on the chain it was proven for");
    }
}
