// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { SNARK_Q } from "../../src/verifiers/VerifyingKeys.sol";
import { FeeMath } from "../utils/FeeMath.sol";
import { MaspFlowFixture } from "../utils/MaspFlowFixture.sol";
import { deployPoolUniform, realVerifierStack, singleAsset } from "../utils/PoolDeployer.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// End-to-end spends with real Groth16 proofs. The pool reaches the tree state
/// the spends were proven against through its own entry points (`deposit`,
/// then `flushBatch` under the fixture's batch proof), and `transfer` or
/// `withdraw` is then invoked with the spend-side fixture: a `4x6` proof and
/// the `tree_update_batch` proof of the six leaves it inserts.
///
/// The fixture is `test/fixtures/masp_flow_proof.json`. `.transfer` and
/// `.withdraw` both spend the note `.flush` deposits, so each test replays one
/// of them. Regenerate it with `script/fixtures/gen_masp_fixture.sh`.
contract MASPTransferSnarkTest is Test {
    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant TREASURY = TestConstants.TREASURY;

    MockERC20 token;
    MASP masp;
    /// Leaf count after the flush: the deposit's principal and fee note.
    uint64 seeded;

    function setUp() public {
        (IVerifier tub, IBatchVerifier bv, ISignatureTransfer p2) = realVerifierStack();
        token = new MockERC20("M", "M", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        masp = deployPoolUniform(tub, bv, p2, ids, tokens, scales, FEE_BPS, TREASURY, TestConstants.OWNER);

        // The deposit and its flush, real proof included.
        string memory j = MaspFlowFixture.read();
        vm.chainId(MaspFlowFixture.chainId(j));
        MaspFlowFixture.Flush memory f = MaspFlowFixture.flush(j);
        MaspFlowFixture.seedTree(masp, token, f, TestConstants.ESCROW_PAYER, address(0xb0b), SCALE, FEE_BPS);
        seeded = masp.committedCount();
        assertEq(masp.currentRoot(), f.tpi.newRoot, "seeded root");
    }

    /// The spend at `key`, anchored at the flushed root's ring slot.
    function _spend(string memory key) internal view returns (MaspFlowFixture.Spend memory s) {
        s = MaspFlowFixture.spend(MaspFlowFixture.read(), key);
        assertEq(s.pi.merkleRoot, masp.currentRoot(), "spend anchors at the flushed root");
        s.tpi.anchorIndex = uint8(masp.rootIndex());
    }

    /// Asserts the spend is refused at the verifier pair and changes nothing.
    function _expectRejected(MaspFlowFixture.Spend memory s, bool isWithdraw) internal {
        bytes32 root = masp.currentRoot();
        vm.prank(s.pi.relayer);
        vm.expectRevert(MASP.ProofRejected.selector);
        if (isWithdraw) masp.withdraw(s.txProof, s.pi, s.tubProof, s.tpi, s.aux);
        else masp.transfer(s.txProof, s.pi, s.tubProof, s.tpi, s.aux);
        assertEq(masp.currentRoot(), root, "root unchanged");
        assertEq(masp.committedCount(), seeded, "no leaves inserted");
        assertFalse(masp.spent(s.pi.nullifier[0]), "note unspent");
    }

    function _assertSpent(MaspFlowFixture.Spend memory s) internal view {
        assertEq(masp.currentRoot(), s.tpi.newRoot, "root advanced to the proven root");
        assertEq(masp.committedCount(), seeded + PubInputs.TRANSACT_OUT, "six leaves inserted");
        for (uint256 k; k < PubInputs.TRANSACT_IN; ++k) {
            assertTrue(masp.spent(s.pi.nullifier[k]), "nullifier consumed");
        }
    }

    function test_transferRealSnark_succeeds() public {
        MaspFlowFixture.Spend memory s = _spend(".transfer");
        assertEq(s.pi.publicAssetId, 0, "a transfer names no asset");
        assertEq(s.pi.publicOut, 0, "a transfer withdraws nothing");
        uint256 custody = token.balanceOf(address(masp));

        // Both proofs are checked by the real verifiers.
        vm.prank(s.pi.relayer);
        masp.transfer(s.txProof, s.pi, s.tubProof, s.tpi, s.aux);

        _assertSpent(s);
        assertEq(token.balanceOf(address(masp)), custody, "a transfer moves no tokens");
    }

    function test_withdrawRealSnark_succeeds() public {
        MaspFlowFixture.Spend memory s = _spend(".withdraw");
        assertEq(s.pi.publicAssetId, ASSET_ID, "fixture asset");
        uint256 outAmt = uint256(s.pi.publicOut) * SCALE;
        uint256 fee = FeeMath.fee(outAmt, FEE_BPS);
        assertGt(outAmt, 0, "a withdraw has a public output");
        uint256 custody = token.balanceOf(address(masp));
        uint256 accrued = masp.accruedFee(IERC20(address(token)));

        vm.expectEmit(address(masp));
        emit MASP.AssetMoved(ASSET_ID, IERC20(address(token)), 0, outAmt, 0, s.pi.publicOut);
        vm.prank(s.pi.relayer);
        masp.withdraw(s.txProof, s.pi, s.tubProof, s.tpi, s.aux);

        _assertSpent(s);
        assertEq(token.balanceOf(s.pi.recipient), outAmt - fee, "recipient paid net of the withdraw fee");
        assertEq(token.balanceOf(address(masp)), custody - (outAmt - fee), "custody reduced by the payout");
        assertEq(masp.accruedFee(IERC20(address(token))), accrued + fee, "withdraw fee accrued");
    }

    // ----- the proofs are what gate the spend --------------------------------
    //
    // Each case changes one word of an otherwise accepted request. Every
    // request check still passes, so the rejection is the verifier pair's.

    /// The encrypted payload is bound through `PubInputs.auxDigest`, the last
    /// word of the transact challenge: one ciphertext byte past the clue
    /// prefix changes `z`.
    function test_revert_ProofRejected_transferCiphertextTampered() public {
        MaspFlowFixture.Spend memory s = _spend(".transfer");
        s.aux[0].ciphertext[2] ^= 0x01;
        _expectRejected(s, false);
    }

    /// `outCm` is a coefficient of the transact polynomial and a leaf of the
    /// batch `PubInputs.compressSpend` rebuilds, so it is bound by both proofs.
    function test_revert_ProofRejected_transferOutCmTampered() public {
        MaspFlowFixture.Spend memory s = _spend(".transfer");
        s.pi.outCm[5] = bytes32(uint256(s.pi.outCm[5]) ^ 1);
        _expectRejected(s, false);
    }

    /// `newRoot` enters the tree-update image only: the transact proof still
    /// verifies, and the pair is rejected on the batch proof.
    function test_revert_ProofRejected_transferNewRootTampered() public {
        MaspFlowFixture.Spend memory s = _spend(".transfer");
        s.tpi.newRoot = bytes32(uint256(s.tpi.newRoot) ^ 1);
        _expectRejected(s, false);
    }

    /// One changed coefficient of the transact proof: `A` negated. Still a
    /// curve point, so the pairing check runs and fails; a coordinate off the
    /// curve would instead fail inside the precompile and burn the gas
    /// forwarded to it.
    function test_revert_ProofRejected_transferProofTampered() public {
        MaspFlowFixture.Spend memory s = _spend(".transfer");
        s.txProof.a[1] = SNARK_Q - s.txProof.a[1];
        _expectRejected(s, false);
    }

    /// The withdraw's proofs presented for the transfer's request: both pairs
    /// verify, each for its own public inputs only.
    function test_revert_ProofRejected_transferWithWithdrawProofs() public {
        MaspFlowFixture.Spend memory s = _spend(".transfer");
        MaspFlowFixture.Spend memory w = _spend(".withdraw");
        s.txProof = w.txProof;
        s.tubProof = w.tubProof;
        _expectRejected(s, false);
    }

    /// The recipient is no circuit signal; it binds through the challenge
    /// alone, which is what stops a relayer redirecting the payout.
    function test_revert_ProofRejected_withdrawRecipientTampered() public {
        MaspFlowFixture.Spend memory s = _spend(".withdraw");
        s.pi.recipient = address(0xBAD);
        _expectRejected(s, true);
        assertEq(token.balanceOf(address(0xBAD)), 0, "nothing paid out");
    }

    /// The public output is a coefficient the circuit balances against the
    /// spent note: one more unit than was proven is refused.
    function test_revert_ProofRejected_withdrawPublicOutTampered() public {
        MaspFlowFixture.Spend memory s = _spend(".withdraw");
        s.pi.publicOut += 1;
        _expectRejected(s, true);
    }
}
