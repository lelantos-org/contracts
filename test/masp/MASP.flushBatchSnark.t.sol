// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { CommitmentTree } from "../../src/CommitmentTree.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { SNARK_Q } from "../../src/verifiers/VerifyingKeys.sol";
import { FeeMath } from "../utils/FeeMath.sol";
import { MaspFlowFixture } from "../utils/MaspFlowFixture.sol";
import { deployPoolUniform, realVerifierStack, singleAsset } from "../utils/PoolDeployer.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// End-to-end flush with a real `tree_update_batch` Groth16 proof and verifier
/// contract: one deposit, escrowed through `deposit` and flushed with the
/// fixture proof, with the verifier accepting and the tree advancing.
///
/// The fixture is `.flush` of `test/fixtures/masp_flow_proof.json`: the batch
/// the pool flushes for one deposit into the empty tree, two deposit leaves
/// built by the circuit from `(ASSET_ID, 100, inner)` and `(0, 0, feeInner)`.
/// Regenerate it with `script/fixtures/gen_masp_fixture.sh`.
contract MASPFlushBatchSnarkTest is Test {
    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant TREASURY = TestConstants.TREASURY;
    address internal constant OWNER = TestConstants.OWNER;
    MockERC20 token;
    MASP masp;

    address payer = TestConstants.ESCROW_PAYER;
    address recipient = address(0xb0b);

    function setUp() public {
        (IVerifier tub, IBatchVerifier bv, ISignatureTransfer p2) = realVerifierStack();
        token = new MockERC20("M", "M", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        masp = deployPoolUniform(tub, bv, p2, ids, tokens, scales, FEE_BPS, TREASURY, OWNER);
    }

    /// Escrows the fixture's deposit and returns it with the batch that
    /// flushes it.
    function _escrow() internal returns (uint256 id, MaspFlowFixture.Flush memory f) {
        f = MaspFlowFixture.flush(MaspFlowFixture.read());
        id = MaspFlowFixture.escrow(masp, token, f, payer, recipient, SCALE, FEE_BPS);
    }

    /// Asserts the flush is refused at the verifier and leaves the escrow and
    /// the tree as they were.
    function _expectRejected(uint256 id, MaspFlowFixture.Flush memory f) internal {
        bytes32 pending = masp.escrowed(id);
        vm.expectRevert(MASP.TreeUpdateRejected.selector);
        MaspFlowFixture.flushEscrow(masp, f, id, payer, FEE_BPS);
        assertEq(masp.escrowed(id), pending, "escrow still pending");
        assertEq(masp.committedCount(), 0, "tree untouched");
    }

    function test_realSnark_n1_flushBatchSucceeds() public {
        (uint256 id, MaspFlowFixture.Flush memory f) = _escrow();
        assertEq(f.tpi.oldRoot, masp.currentRoot(), "the batch extends the empty tree");
        assertEq(f.tpi.leafAsset[0], ASSET_ID, "fixture asset");

        vm.expectEmit(address(masp));
        emit MASP.DepositFlushed(id, f.tpi.cms[0]);
        vm.expectEmit(address(masp));
        emit CommitmentTree.RootAdvanced(0, 2, f.tpi.oldRoot, f.tpi.newRoot);
        MaspFlowFixture.flushEscrow(masp, f, id, payer, FEE_BPS);

        assertEq(masp.currentRoot(), f.tpi.newRoot, "root advanced to the proven root");
        assertEq(masp.committedCount(), 2, "principal and fee leaves inserted");
        assertEq(masp.escrowed(id), bytes32(0), "escrow drained");
        assertEq(
            masp.accruedFee(IERC20(address(token))),
            FeeMath.fee(uint256(f.tpi.leafPublicIn[0]) * SCALE, FEE_BPS),
            "treasury fee accrued"
        );
    }

    /// `newRoot` is a coefficient of the batch polynomial and outside the
    /// escrow digest, so nothing but the proof stands between a flusher and a
    /// root of its choosing.
    function test_revert_TreeUpdateRejected_newRootTampered() public {
        (uint256 id, MaspFlowFixture.Flush memory f) = _escrow();
        f.tpi.newRoot = bytes32(uint256(f.tpi.newRoot) ^ 1);
        _expectRejected(id, f);
    }

    /// The digest word is the circuit's second public signal: the verifier
    /// compares the calldata copy against the one the proof was made for.
    function test_revert_TreeUpdateRejected_digestTampered() public {
        (uint256 id, MaspFlowFixture.Flush memory f) = _escrow();
        f.tpi.digest ^= 1;
        _expectRejected(id, f);
    }

    /// One changed proof coefficient: `C` negated. Still a curve point, so the
    /// pairing check runs and fails; a coordinate off the curve would instead
    /// fail inside the precompile and burn the gas forwarded to it.
    function test_revert_TreeUpdateRejected_proofTampered() public {
        (uint256 id, MaspFlowFixture.Flush memory f) = _escrow();
        f.proof.c[1] = SNARK_Q - f.proof.c[1];
        _expectRejected(id, f);
    }

    /// A proof that verifies, but for another batch: the transfer's tree-update
    /// proof, made with the same key over other public inputs.
    function test_revert_TreeUpdateRejected_proofOfAnotherBatch() public {
        (uint256 id, MaspFlowFixture.Flush memory f) = _escrow();
        f.proof = MaspFlowFixture.spend(MaspFlowFixture.read(), ".transfer").tubProof;
        _expectRejected(id, f);
    }
}
