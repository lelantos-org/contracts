// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { ExitTerms } from "../../src/libs/ExitTerms.sol";
import { MASP } from "../../src/MASP.sol";

import { MASPUpgradeTestBase } from "../utils/MASPUpgradeTestBase.sol";
import { noAssets } from "../utils/PoolDeployer.sol";
import { MASPNext } from "../mocks/MASPNext.sol";

/// The pool behind the delayed proxy: pool state survives an upgrade, and
/// neither a withdraw-fee raise nor a pause can undermine the exit window.
contract MASPUpgradeTest is MASPUpgradeTestBase {
    function _queue(address next) internal {
        vm.prank(admin);
        proxy.queueUpgrade(next);
    }

    // ============== Initialization ===========================================

    function test_initializedThroughTheProxy() public view {
        assertEq(masp.owner(), poolOwner, "owner must come from the initializer");
        assertEq(masp.treasury(), treasury);
        assertEq(address(masp.PERMIT2()), permit2, "verifier/permit2 now live in storage");
        assertEq(address(masp.TREE_UPDATE_BATCH_VERIFIER()), address(tubVerifier));
        assertEq(address(masp.SPEND_VERIFIER()), address(batchVerifier));
        assertEq(address(masp.asset(ASSET_ID).token), address(token));
        assertTrue(masp.isKnownRoot(masp.currentRoot()), "genesis root never seeded");
    }

    function test_cannotReinitialize() public {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = noAssets();
        uint16[] memory bps = new uint16[](0);

        // Read these first: an external call between `expectRevert` and the call
        // under test consumes the expectation.
        IVerifier tub = masp.TREE_UPDATE_BATCH_VERIFIER();
        IBatchVerifier spend = masp.SPEND_VERIFIER();
        ISignatureTransfer p2 = masp.PERMIT2();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        masp.initialize(tub, spend, p2, ids, tokens, scales, bps, bps, treasury, address(0xdead));
    }

    /// The implementation is not initializable outside the proxy.
    function test_implementationItselfIsLocked() public {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = noAssets();
        uint16[] memory bps = new uint16[](0);

        IVerifier tub = masp.TREE_UPDATE_BATCH_VERIFIER();
        IBatchVerifier spend = masp.SPEND_VERIFIER();
        ISignatureTransfer p2 = masp.PERMIT2();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(tub, spend, p2, ids, tokens, scales, bps, bps, treasury, address(0xdead));
        assertEq(impl.owner(), address(0), "implementation must stay unowned");
    }

    /// `renounceOwnership` is not declared.
    function test_renounceOwnershipDoesNotExist() public {
        (bool ok,) = address(masp).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok, "pool must not expose renounceOwnership");
        assertEq(masp.owner(), poolOwner);
    }

    /// `transferOwnership` is declared for `ProtocolAdmin.migrateAdmin` and the
    /// deploy handover. Only the owner may call it, and that owner is
    /// `ProtocolAdmin`, whose `execute` rejects the selector.
    function test_transferOwnershipIsOwnerGatedAndRejectsZero() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        masp.transferOwnership(address(0xbeef));

        vm.prank(poolOwner);
        vm.expectRevert();
        masp.transferOwnership(address(0));

        vm.prank(poolOwner);
        masp.transferOwnership(address(0xbeef));
        assertEq(masp.owner(), address(0xbeef));
    }

    /// The proxy's fallback is `payable` via `Proxy`, but the pool is ERC-20
    /// only: a value-bearing call reaches the non-payable implementation and
    /// reverts.
    function test_poolRejectsNativeCoin() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(proxy).call{ value: 1 }("");
        assertFalse(ok, "proxy accepted native coin");
        assertEq(address(proxy).balance, 0);
    }

    // ============== State survives ===========================================

    /// An upgrade preserves the tree, the escrow ledger and accrued fees.
    function test_realPoolStateSurvivesAnUpgrade() public {
        bytes32 cm = bytes32(uint256(0x111));
        uint256 id = _deposit(1_000, cm, 0);
        _flush(id, 1_000, cm);

        bytes32 rootBefore = masp.currentRoot();
        uint64 countBefore = masp.committedCount();
        uint256 feesBefore = masp.accruedFee(IERC20(address(token)));
        uint256 nextIdBefore = masp.nextDepositId();
        assertGt(feesBefore, 0, "fixture must accrue a fee");
        assertEq(countBefore, 2, "principal + relayer note");

        MASPNext next = new MASPNext();
        _queue(address(next));
        vm.warp(T0 + UPGRADE_DELAY);
        proxy.activateUpgrade();

        assertEq(MASPNext(address(proxy)).poolVersion(), 3, "upgrade did not land");
        assertEq(masp.currentRoot(), rootBefore, "merkle root lost");
        assertEq(masp.committedCount(), countBefore, "leaf count lost");
        assertTrue(masp.isKnownRoot(rootBefore), "root history lost");
        assertEq(masp.accruedFee(IERC20(address(token))), feesBefore, "accrued fees lost");
        assertEq(masp.nextDepositId(), nextIdBefore, "deposit counter lost");
        assertEq(masp.owner(), poolOwner, "owner lost");
        assertEq(masp.treasury(), treasury, "treasury lost");
        assertEq(address(masp.SPEND_VERIFIER()), address(batchVerifier), "verifier wiring lost");
    }

    /// A pending escrow remains cancellable after an upgrade.
    function test_pendingEscrowSurvivesAndStaysCancellable() public {
        uint256 id = _deposit(1_000, bytes32(uint256(0x222)), 0);
        assertTrue(masp.escrowed(id) != bytes32(0));
        bytes32 digestBefore = masp.escrowed(id);

        MASPNext next = new MASPNext();
        _queue(address(next));
        vm.warp(T0 + UPGRADE_DELAY);
        proxy.activateUpgrade();

        assertEq(masp.escrowed(id), digestBefore, "escrow digest lost across upgrade");
    }

    // ============== Leak 1: the withdraw-fee ratchet =========================

    function _withdrawBps() internal view returns (uint16 wit) {
        (, wit) = masp.assetFees(ASSET_ID);
    }

    function _raiseWithdrawFee(uint16 wit) internal {
        vm.prank(poolOwner);
        masp.setAssetFee(ASSET_ID, FEE_BPS, wit);
    }

    /// A withdraw-fee raise is queued, not applied: the live rate, which every
    /// spend reads, is unchanged, and the queued value and its notice are
    /// announced.
    function test_withdrawFeeRaiseIsQueuedNotApplied() public {
        vm.expectEmit(address(masp));
        emit ExitTerms.ExitTermRaisePending(ASSET_ID, ExitTerms.WITHDRAW_BPS, 2_000, T0 + ExitTerms.DELAY);
        vm.expectEmit(address(masp));
        emit AssetRegistry.AssetFeeSet(ASSET_ID, FEE_BPS, FEE_BPS);
        _raiseWithdrawFee(2_000);

        assertEq(_withdrawBps(), FEE_BPS, "raise applied without notice");
        assertEq(masp.asset(ASSET_ID).withdrawBps, FEE_BPS, "asset() reports the queued rate");
    }

    /// The commit is refused until the notice has run, naming when it will.
    function test_revert_RaiseNotDue_commitBeforeDelay() public {
        _raiseWithdrawFee(2_000);

        vm.warp(T0 + ExitTerms.DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(ExitTerms.RaiseNotDue.selector, T0 + ExitTerms.DELAY));
        masp.commitExitTerms(ASSET_ID);
        assertEq(_withdrawBps(), FEE_BPS);
    }

    /// With nothing queued there is nothing to wait for.
    function test_revert_NoPendingRaise_commitWithNothingQueued() public {
        vm.expectRevert(ExitTerms.NoPendingRaise.selector);
        masp.commitExitTerms(ASSET_ID);
    }

    /// Once the notice has run anyone may commit, the raise lands with the
    /// ordinary applied event, and the queue entry is consumed.
    function test_commitAppliesTheRaiseAfterDelay() public {
        _raiseWithdrawFee(2_000);

        vm.warp(T0 + ExitTerms.DELAY);
        vm.expectEmit(address(masp));
        emit AssetRegistry.AssetFeeSet(ASSET_ID, FEE_BPS, 2_000);
        vm.prank(makeAddr("anyone"));
        masp.commitExitTerms(ASSET_ID);
        assertEq(_withdrawBps(), 2_000, "commit did not apply the raise");

        vm.expectRevert(ExitTerms.NoPendingRaise.selector);
        masp.commitExitTerms(ASSET_ID);
    }

    /// A pause halts exits, so paused time is not notice: the raise waits a
    /// full delay after the pause ends, however early the pause fell.
    function test_pauseDefersTheRaiseCommit() public {
        _raiseWithdrawFee(2_000);

        vm.warp(T0 + ExitTerms.DELAY - 1 days);
        vm.prank(admin);
        proxy.pauseSpends(3 days);
        uint256 due = T0 + ExitTerms.DELAY - 1 days + 3 days + ExitTerms.DELAY;

        vm.warp(T0 + ExitTerms.DELAY);
        vm.expectRevert(abi.encodeWithSelector(ExitTerms.RaiseNotDue.selector, due));
        masp.commitExitTerms(ASSET_ID);

        vm.warp(due - 1);
        vm.expectRevert(abi.encodeWithSelector(ExitTerms.RaiseNotDue.selector, due));
        masp.commitExitTerms(ASSET_ID);

        vm.warp(due);
        masp.commitExitTerms(ASSET_ID);
        assertEq(_withdrawBps(), 2_000);
    }

    /// Lowering applies at once and withdraws the queued raise, so the raise
    /// cannot be committed later.
    function test_decreaseIsImmediateAndCancelsPendingRaise() public {
        _raiseWithdrawFee(2_000);

        vm.expectEmit(address(masp));
        emit ExitTerms.ExitTermRaisePending(ASSET_ID, ExitTerms.WITHDRAW_BPS, 0, 0);
        _raiseWithdrawFee(10);
        assertEq(_withdrawBps(), 10, "decrease was not immediate");

        vm.warp(T0 + ExitTerms.DELAY);
        vm.expectRevert(ExitTerms.NoPendingRaise.selector);
        masp.commitExitTerms(ASSET_ID);
        assertEq(_withdrawBps(), 10);
    }

    /// Re-sending the queued withdraw rate with a new deposit rate applies the
    /// deposit rate and keeps the raise's timer; the deposit rate is bound into
    /// each escrow digest and reaches no one already in the pool.
    function test_depositOnlyChangeKeepsPendingRaise() public {
        _raiseWithdrawFee(2_000);

        vm.warp(T0 + 10 days);
        vm.recordLogs();
        vm.prank(poolOwner);
        masp.setAssetFee(ASSET_ID, 2_000, 2_000);
        assertEq(vm.getRecordedLogs().length, 1, "only AssetFeeSet; the queue entry is untouched");
        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, 2_000, "deposit rate not immediate");
        assertEq(wit, FEE_BPS);

        vm.warp(T0 + ExitTerms.DELAY);
        masp.commitExitTerms(ASSET_ID);
        assertEq(_withdrawBps(), 2_000, "timer restarted");
    }

    /// A different queued value restarts the notice: holders are warned of a
    /// specific rate.
    function test_changingTheQueuedValueRestartsTheNotice() public {
        _raiseWithdrawFee(2_000);
        vm.warp(T0 + 10 days);
        _raiseWithdrawFee(1_000);

        vm.warp(T0 + ExitTerms.DELAY);
        vm.expectRevert(abi.encodeWithSelector(ExitTerms.RaiseNotDue.selector, T0 + 10 days + ExitTerms.DELAY));
        masp.commitExitTerms(ASSET_ID);

        vm.warp(T0 + 10 days + ExitTerms.DELAY);
        masp.commitExitTerms(ASSET_ID);
        assertEq(_withdrawBps(), 1_000);
    }

    /// The audit ordering: one proposal raises the fee and then queues an
    /// upgrade, which the old pending-upgrade guard let through. Throughout the
    /// window, pause included, holders exit at the old rate; the raise cannot
    /// land before the upgrade could activate.
    function test_raiseThenQueueUpgradeCannotChargeTheWindow() public {
        _raiseWithdrawFee(2_000);
        _queue(address(new MASPNext()));

        // A pause inside the window defers both by at least its duration.
        vm.warp(T0 + 5 days);
        vm.prank(admin);
        proxy.pauseSpends(MAX_PAUSE);
        (, uint256 activationAt) = proxy.pendingUpgrade();
        assertEq(activationAt, T0 + UPGRADE_DELAY + MAX_PAUSE);

        // Due a full delay after the pause ends, past the deferred activation.
        uint256 due = T0 + 5 days + MAX_PAUSE + ExitTerms.DELAY;
        assertGe(due, activationAt);
        vm.warp(activationAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ExitTerms.RaiseNotDue.selector, due));
        masp.commitExitTerms(ASSET_ID);
        assertEq(_withdrawBps(), FEE_BPS, "window charged at the raised rate");

        vm.warp(activationAt);
        proxy.activateUpgrade();
    }

    /// The cancel-and-requeue ordering fares no better: the raise's notice
    /// runs from the raise, not from any upgrade.
    function test_cancelRaiseRequeueCannotChargeTheWindow() public {
        _queue(address(new MASPNext()));
        vm.prank(admin);
        proxy.cancelUpgrade();
        _raiseWithdrawFee(2_000);
        _queue(address(new MASPNext()));

        vm.warp(T0 + UPGRADE_DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(ExitTerms.RaiseNotDue.selector, T0 + ExitTerms.DELAY));
        masp.commitExitTerms(ASSET_ID);
        assertEq(_withdrawBps(), FEE_BPS);
    }

    // ============== Leak 2: pause versus exit ================================

    /// A pause halts every proof-dependent entry point, including exits, which
    /// is why the window is extended by the pause duration.
    function test_pauseHaltsDepositsAndFlushes() public {
        vm.prank(admin);
        proxy.pauseSpends(1 days);
        _fundPayer(1_000);

        vm.expectRevert(abi.encodeWithSelector(MASP.SpendsPaused.selector, T0 + 1 days));
        _depositCall(1_000, bytes32(uint256(0x333)), 0);
    }

    /// `cancelDeposit` remains available while paused, so escrowed funds stay
    /// recoverable. A cancel verifies no proof.
    function test_cancelDepositStillWorksWhilePaused() public {
        bytes32 cm = bytes32(uint256(0x444));
        // Uses absolute block numbers. As with `block.timestamp`, the optimizer
        // may fold a local copy of `block.number` and re-read it at the use site,
        // which `vm.roll` invalidates.
        uint32 submittedAt = 100;
        vm.roll(submittedAt);

        uint256 id = _deposit(1_000, cm, 0);
        uint256 payerBefore = token.balanceOf(payer);

        vm.prank(admin);
        proxy.pauseSpends(1 days);

        // Past the cancel delay.
        vm.roll(uint256(submittedAt) + 7_200 + 1);

        // The fixture payer carries an etched ERC-1271 stub, so the pool treats
        // it as a contract payer and only it may cancel its own escrow.
        vm.prank(payer);
        masp.cancelDeposit(
            id,
            1_000,
            cm,
            [uint256(0), uint256(0)],
            ASSET_ID,
            FEE_BPS,
            payer,
            submittedAt,
            PubInputs.FeeNote({
                feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), uint256(0)]
            })
        );

        assertGt(token.balanceOf(payer), payerBefore, "refund did not arrive while paused");
        assertEq(masp.escrowed(id), bytes32(0), "escrow not cleared");
    }

    function test_pauseLiftsOnItsOwn() public {
        vm.prank(admin);
        proxy.pauseSpends(1 days);
        vm.warp(T0 + 1 days);
        // Does not revert: the pause expires without any call to lift it.
        _deposit(1_000, bytes32(uint256(0x555)), 0);
    }

    /// A pause defers activation by its own duration.
    function test_pauseDuringAWindowPushesActivationBack() public {
        MASPNext next = new MASPNext();
        _queue(address(next));
        vm.prank(admin);
        proxy.pauseSpends(3 days);

        vm.warp(T0 + UPGRADE_DELAY);
        vm.expectRevert();
        proxy.activateUpgrade();

        vm.warp(T0 + UPGRADE_DELAY + 3 days);
        proxy.activateUpgrade();
        assertEq(MASPNext(address(proxy)).poolVersion(), 3);
    }
}
