// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";

import { MASPUpgradeTestBase } from "../utils/MASPUpgradeTestBase.sol";
import { MockTreeUpdateVerifier } from "../mocks/MockTreeUpdateVerifier.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { newPoolImplementation } from "../utils/PoolDeployer.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";

/// A verifier swap against the real pool: what it changes, and when.
///
/// `VerifierUpdate.t.sol` drives the proxy's queue in isolation. This file
/// asserts the consequence the queue exists for — that the pool's answer to a
/// proof changes, and changes only once the window has run.
contract MASPVerifierSwapTest is MASPUpgradeTestBase {
    MockTreeUpdateVerifier internal rejectingTub;
    MockBatchVerifier internal newSpend;

    function setUp() public virtual override {
        super.setUp();
        // Rejects every tree-update proof, so a flush that succeeds under the
        // live verifier fails under this one.
        rejectingTub = new MockTreeUpdateVerifier(false);
        newSpend = new MockBatchVerifier();
    }

    /// `EscrowFlowBase._flush` mocks the live verifier into accepting, which is
    /// exactly what this file must not do: the point is to let the committed
    /// verifier answer. Otherwise identical, with `expectRevert` immediately
    /// before the call that must revert rather than before the helper.
    function _flushExpectingRejection(uint256 id, uint64 publicIn, bytes32 cm) internal {
        PubInputs.TreeUpdateBatch memory tpi =
            DepositFixture.batch(masp.currentRoot(), bytes32(uint256(0xfeedbeef)), masp.committedCount(), 1);
        DepositFixture.setDepositLeaves(tpi, 0, cm, ASSET_ID, publicIn);
        MASP.DepositMeta[] memory meta = DepositFixture.metas(1, payer, uint32(block.number), FEE_BPS);

        vm.expectRevert(MASP.TreeUpdateRejected.selector);
        masp.flushBatch(DepositFixture.ids(id), meta, FixtureLoader.emptyProof(), tpi);
    }

    function _queueRejectingPair() internal {
        vm.prank(admin);
        proxy.queueVerifierUpdate(address(rejectingTub), address(newSpend));
    }

    /// Queues the pair, warps to the absolute commit time the proxy reports, and
    /// commits. Absolute rather than `block.timestamp + UPGRADE_DELAY`: under
    /// `via_ir` the optimizer may cache `block.timestamp` across a `vm.warp`, so
    /// a second relative warp in one test body lands short.
    function _swapToRejectingPair() internal {
        _queueRejectingPair();
        (,, uint256 notBefore) = proxy.pendingVerifierUpdate();
        vm.warp(notBefore);
        proxy.commitVerifierUpdate();
    }

    /// The pool reads its verifiers from the namespace the proxy writes, so the
    /// two views agree at all times.
    function test_poolAndProxyReportTheSameLivePair() public view {
        (address tub, address spend) = proxy.verifiers();
        assertEq(address(masp.TREE_UPDATE_BATCH_VERIFIER()), tub, "tree-update verifier disagrees");
        assertEq(address(masp.SPEND_VERIFIER()), spend, "spend verifier disagrees");
        assertEq(tub, address(tubVerifier), "live pair is not the deployed one");
    }

    /// The whole point of the window: a queued verifier has no effect on what
    /// the pool accepts until it is committed.
    function test_queuedVerifierDoesNotVerifyBeforeItsWindowElapses() public {
        _queueRejectingPair();

        // Still the old verifier, so a flush that was valid stays valid.
        uint256 id = _deposit(1_000, bytes32(uint256(0x111)), 0);
        _flush(id, 1_000, bytes32(uint256(0x111)));

        assertEq(address(masp.TREE_UPDATE_BATCH_VERIFIER()), address(tubVerifier), "swapped before its window");
    }

    /// After the commit the pool verifies against the new pair, which is the
    /// change governance queued.
    function test_committedVerifierDecidesWhatThePoolAccepts() public {
        _swapToRejectingPair();

        assertEq(address(masp.TREE_UPDATE_BATCH_VERIFIER()), address(rejectingTub), "pool did not pick up the swap");
        assertEq(address(masp.SPEND_VERIFIER()), address(newSpend), "pool did not pick up the spend verifier");

        // The same flush that succeeded above is now rejected: the new verifier
        // answers false, and `flushBatch` reverts rather than trusting it.
        uint256 id = _deposit(1_000, bytes32(uint256(0x222)), 0);
        _flushExpectingRejection(id, 1_000, bytes32(uint256(0x222)));
    }

    /// A swap survives an implementation upgrade and vice versa: the pair lives
    /// in its own namespace, so replacing the code behind the proxy does not
    /// disturb it.
    function test_swapSurvivesAnImplementationUpgrade() public {
        _swapToRejectingPair();

        MASP next = newPoolImplementation();
        vm.prank(admin);
        proxy.queueUpgrade(address(next));
        (, uint256 activationAt) = proxy.pendingUpgrade();
        vm.warp(activationAt);
        proxy.activateUpgrade();

        assertEq(address(masp.TREE_UPDATE_BATCH_VERIFIER()), address(rejectingTub), "upgrade reset the verifiers");
        assertEq(address(masp.SPEND_VERIFIER()), address(newSpend), "upgrade reset the spend verifier");
    }

    /// The pool holds no setter of its own: the proxy is the only way in, so a
    /// compromised implementation cannot install a verifier by calling itself.
    function test_poolExposesNoVerifierSetter() public view {
        // Selectors the pool would need to change a verifier directly.
        bytes4[3] memory absent = [
            bytes4(keccak256("setVerifiers(address,address)")),
            bytes4(keccak256("setSpendVerifier(address)")),
            bytes4(keccak256("setTreeUpdateBatchVerifier(address)"))
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok,) = address(masp).staticcall(abi.encodePacked(absent[i], uint256(0), uint256(0)));
            assertFalse(ok, "the pool answers a verifier setter");
        }
    }
}
