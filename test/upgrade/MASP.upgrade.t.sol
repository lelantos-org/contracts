// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { MASP } from "../../src/MASP.sol";

import { MASPUpgradeTestBase } from "../utils/MASPUpgradeTestBase.sol";
import { noAssets } from "../utils/PoolDeployer.sol";
import { MASPNext } from "../mocks/MASPNext.sol";

/// The pool behind the delayed proxy: pool state survives an upgrade, and
/// neither the withdraw-fee rule nor a pause can undermine the exit window.
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

    /// The implementation must not be initializable outside the proxy.
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

    /// An upgrade must preserve the tree, the escrow ledger and accrued fees.
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

    /// Otherwise an upgrade could be queued and the exit fee raised to 20% in
    /// the same window, charging holders who leave ahead of it.
    function test_withdrawFeeCannotBeRaisedWhileAnUpgradeIsPending() public {
        MASPNext next = new MASPNext();
        _queue(address(next));

        vm.prank(poolOwner);
        vm.expectRevert(AssetRegistry.WithdrawFeeRaisedDuringUpgradeWindow.selector);
        masp.setAssetFee(ASSET_ID, FEE_BPS, 2_000);
    }

    /// Lowering it is permitted.
    function test_withdrawFeeMayStillBeLoweredWhileAnUpgradeIsPending() public {
        MASPNext next = new MASPNext();
        _queue(address(next));

        vm.prank(poolOwner);
        masp.setAssetFee(ASSET_ID, FEE_BPS, 10);
        (, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(wit, 10);
    }

    /// The deposit leg is unrestricted: it is snapshotted into the escrow digest
    /// at submit, so it cannot reach anyone already in the masp.
    function test_depositFeeIsUnrestrictedDuringTheWindow() public {
        MASPNext next = new MASPNext();
        _queue(address(next));

        vm.prank(poolOwner);
        masp.setAssetFee(ASSET_ID, 2_000, FEE_BPS);
        (uint16 dep,) = masp.assetFees(ASSET_ID);
        assertEq(dep, 2_000);
    }

    /// With nothing queued the rate may move again.
    function test_withdrawFeeMayRiseAgainAfterTheUpgradeResolves() public {
        MASPNext next = new MASPNext();
        _queue(address(next));
        vm.prank(admin);
        proxy.cancelUpgrade();

        vm.prank(poolOwner);
        masp.setAssetFee(ASSET_ID, FEE_BPS, 500);
        (, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(wit, 500);
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
        // Absolute block numbers throughout. As with `block.timestamp`, the
        // optimizer may fold a local copy of `block.number` and re-read it at the
        // use site, which `vm.roll` invalidates.
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
            PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), uint256(0)] })
        );

        assertGt(token.balanceOf(payer), payerBefore, "refund did not arrive while paused");
        assertEq(masp.escrowed(id), bytes32(0), "escrow not cleared");
    }

    function test_pauseLiftsOnItsOwn() public {
        vm.prank(admin);
        proxy.pauseSpends(1 days);
        vm.warp(T0 + 1 days);
        // No revert: the pause has expired without anyone acting.
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
