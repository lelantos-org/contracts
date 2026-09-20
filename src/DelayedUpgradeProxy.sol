// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import { ExitTerms } from "./libs/ExitTerms.sol";
import { UpgradeStorage } from "./UpgradeStorage.sol";
import { VerifierStorage } from "./VerifierStorage.sol";

/// ERC-1967 proxy whose upgrades do not take effect immediately.
///
/// A queued implementation activates only after `UPGRADE_DELAY`; until then the
/// current implementation serves every call. The window gives holders the
/// opportunity to withdraw under the rules in force when they entered.
///
/// Properties the guarantee rests on:
///
/// 1. `UPGRADE_DELAY` is `immutable` and has no setter, so the window cannot be
///    shortened.
/// 2. Paused time does not consume the window, whichever comes first: a pause
///    extends a pending window by its own duration, and an upgrade queued while
///    spends are paused starts its window when the pause ends. `MAX_PAUSE` is
///    shorter than `UPGRADE_DELAY`.
/// 3. `activateUpgrade` is permissionless, so activation requires no keeper.
///    While it goes uncalled the current implementation continues to serve.
/// 4. `cancelUpgrade` only withdraws a queued upgrade.
///
/// The verifiers get the same treatment, and from here rather than from the
/// pool. Replacing them is the same power as replacing the implementation —
/// either can make the pool honour notes that were never legitimately created —
/// so `queueVerifierUpdate` takes the same window, is deferred by the same
/// pauses and is committed by the same permissionless call shape.
/// `VerifierStorage` holds both the live pair and the queued one, and carries
/// the reasoning.
///
/// Dispatch: the selectors declared here are reserved and do not reach the
/// implementation; everything else is forwarded by `delegatecall`, including
/// calls from the admin, which also owns the pool and must be able to
/// administer it. `DelayedUpgradeProxy.t.sol` asserts the reserved set does not
/// collide with the implementation's ABI.
// A proxy holds no ether of its own: `ERC1967Proxy`'s fallback forwards value
// along with the call, so a balance is the implementation's to spend and its
// withdrawal path is part of the implementation ABI, not the proxy's.
// aderyn-fp-next-line(contract-locks-ether)
contract DelayedUpgradeProxy is ERC1967Proxy {
    /// The exit window. See property (1) above.
    uint256 public immutable UPGRADE_DELAY;
    /// Ceiling on a single pause.
    uint256 public immutable MAX_PAUSE;

    event UpgradeQueued(address indexed newImplementation, uint256 activationAt);
    event UpgradeCancelled(address indexed cancelledImplementation);
    event UpgradeActivated(address indexed newImplementation);
    event SpendsPaused(uint256 pausedUntil, uint256 newActivationAt);
    /// A verifier pair is queued to replace the live one. `notBefore` is the
    /// earliest commit time as of queueing; a later pause defers it, which
    /// `SpendsPaused` reports and `pendingVerifierUpdate` reads back.
    event VerifierUpdateQueued(
        address indexed treeUpdateBatchVerifier, address indexed spendVerifier, uint256 notBefore
    );
    /// The queued pair was withdrawn before it landed.
    event VerifierUpdateCancelled(address indexed treeUpdateBatchVerifier, address indexed spendVerifier);
    /// The queued pair is now live. Both move together; see `VerifierStorage`.
    event VerifiersUpdated(
        address indexed treeUpdateBatchVerifier,
        address indexed spendVerifier,
        address oldTreeUpdateBatchVerifier,
        address oldSpendVerifier
    );
    event ProxyAdminChanged(address indexed previousAdmin, address indexed newAdmin);

    error NotProxyAdmin();
    error NoPendingUpgrade();
    error UpgradePending();
    error NotYetActivatable(uint256 activationAt);
    error ImplementationHasNoCode();
    error PauseTooLong();
    error ZeroDelay();
    error ZeroAdmin();
    error PauseNotShorterThanDelay();
    error DelayExceedsExitTermsNotice();
    error NoPendingVerifierUpdate();
    error VerifierUpdatePending();
    error VerifierUpdateNotDue(uint256 notBefore);

    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }

    /// Factored out of the modifier so its body is not inlined into each of the
    /// guarded entry points.
    function _requireAdmin() private view {
        if (msg.sender != ERC1967Utils.getAdmin()) revert NotProxyAdmin();
    }

    /// The end of a window opened now: `UPGRADE_DELAY` measured from the moment
    /// spends reopen, `max(now, pausedUntil)`.
    ///
    /// Shared by `queueUpgrade` and `queueVerifierUpdate`, because paused time
    /// is not notice in either case. `pauseSpends` extends only a window that
    /// already exists, so without this a pause issued before the queue, or
    /// running across a cancel and re-queue, would spend its paused time inside
    /// the new window and shorten the holders' exit. An expired pause defers
    /// nothing.
    function _windowEnd() private view returns (uint256) {
        uint256 pausedUntil = UpgradeStorage.$().pausedUntil;
        uint256 start = pausedUntil > block.timestamp ? pausedUntil : block.timestamp;
        return start + UPGRADE_DELAY;
    }

    /// Both namespaces store their deadlines as `uint40`, which spans timestamps
    /// to the year 36,812; see `UpgradeStorage.Layout`. Every such cast goes
    /// through here, so the two linters are answered once rather than at each
    /// write.
    function _toUint40(uint256 timestamp) private pure returns (uint40) {
        // forge-lint: disable-next-line(unsafe-typecast)
        // aderyn-fp-next-line(unsafe-casting)
        return uint40(timestamp);
    }

    constructor(
        address implementation_,
        bytes memory initData,
        address admin_,
        uint256 upgradeDelay_,
        uint256 maxPause_
    ) ERC1967Proxy(implementation_, initData) {
        if (upgradeDelay_ == 0) revert ZeroDelay();
        if (admin_ == address(0)) revert ZeroAdmin();
        // The pool delays exit-term raises by `ExitTerms.DELAY`. A longer window
        // would let one proposal raise a term and queue an upgrade, and the raise
        // would land while holders are still leaving ahead of the upgrade.
        if (upgradeDelay_ > ExitTerms.DELAY) revert DelayExceedsExitTermsNotice();
        // A pause at least as long as the window could hold spends shut for all
        // of it; property (2) keeps paused time out of the window, but a bound
        // this loose would still let a single pause stall exits for as long as
        // the window itself.
        if (maxPause_ >= upgradeDelay_) revert PauseNotShorterThanDelay();
        UPGRADE_DELAY = upgradeDelay_;
        MAX_PAUSE = maxPause_;
        ERC1967Utils.changeAdmin(admin_);
    }

    // ============== Upgrade lifecycle ========================================

    /// Queues `newImplementation`. It runs only once `activateUpgrade` is called,
    /// which is possible only after the window elapses.
    ///
    /// One upgrade may be pending at a time, so the queued payload cannot be
    /// replaced without restarting the window. Cancel first.
    ///
    /// The window starts when spends reopen; see `_windowEnd`.
    function queueUpgrade(address newImplementation) external onlyAdmin {
        if (newImplementation.code.length == 0) revert ImplementationHasNoCode();
        UpgradeStorage.Layout storage l = UpgradeStorage.$();
        if (l.pendingImplementation != address(0)) revert UpgradePending();

        uint256 activationAt = _windowEnd();
        l.pendingImplementation = newImplementation;
        l.activationAt = _toUint40(activationAt);
        emit UpgradeQueued(newImplementation, activationAt);
    }

    /// Withdraws a queued upgrade. Reduces pending authority, so it takes no
    /// delay.
    function cancelUpgrade() external onlyAdmin {
        UpgradeStorage.Layout storage l = UpgradeStorage.$();
        address pending = l.pendingImplementation;
        if (pending == address(0)) revert NoPendingUpgrade();
        _clearPendingUpgrade(l);
        emit UpgradeCancelled(pending);
    }

    /// Promotes the queued implementation once the window has elapsed.
    ///
    /// Permissionless: after the delay the payload is fixed, public and has been
    /// cancellable throughout, so activation carries liveness only. The current
    /// implementation continues to serve until this is called.
    ///
    /// Activation passes empty init data, so nothing runs atomically with it.
    /// An implementation queued here must therefore not expose an unguarded
    /// `reinitializer` or other one-shot setup: the activator, or anyone in the
    /// same block, could call it before the intended caller. Migrations must be
    /// owner-gated, or idempotent and safe for any caller.
    function activateUpgrade() external {
        UpgradeStorage.Layout storage l = UpgradeStorage.$();
        address pending = l.pendingImplementation;
        if (pending == address(0)) revert NoPendingUpgrade();
        uint256 activationAt = l.activationAt;
        if (block.timestamp < activationAt) revert NotYetActivatable(activationAt);

        _clearPendingUpgrade(l);
        ERC1967Utils.upgradeToAndCall(pending, "");
        emit UpgradeActivated(pending);
    }

    function _clearPendingUpgrade(UpgradeStorage.Layout storage l) private {
        l.pendingImplementation = address(0);
        l.activationAt = 0;
    }

    // ============== Verifiers ================================================
    //
    // Same shape as the upgrade lifecycle above, for the same reason: a verifier
    // decides what the pool accepts as a valid proof, so swapping one is the
    // same power as swapping the implementation. `VerifierStorage` holds the
    // live pair and the queued one.

    /// Queues a replacement for both verifiers.
    ///
    /// One queued pair at a time, matching `queueUpgrade`: replacing a pending
    /// pair requires cancel-then-queue, which restarts the window. Holders are
    /// given notice of a specific pair, so a different one must not inherit the
    /// elapsed part of another's notice.
    ///
    /// The window is `queueUpgrade`'s, computed by the same `_windowEnd`: paused
    /// time is not notice, because a holder who cannot exit has not been given
    /// the chance to.
    ///
    /// The pair is validated here rather than at commit. The addresses are fixed
    /// for the whole window, so a malformed one fails the proposal that queued
    /// it instead of the permissionless call that lands it. Code cannot
    /// disappear from them in between: since Cancun `SELFDESTRUCT` clears code
    /// only for a contract created in the same transaction, and these already
    /// held code when `validatePair` checked.
    function queueVerifierUpdate(address treeUpdateBatchVerifier, address spendVerifier) external onlyAdmin {
        VerifierStorage.Layout storage v = VerifierStorage.$();
        if (v.notBefore != 0) revert VerifierUpdatePending();
        VerifierStorage.validatePair(treeUpdateBatchVerifier, spendVerifier);

        uint256 notBefore = _windowEnd();
        v.pendingTreeUpdateBatchVerifier = treeUpdateBatchVerifier;
        v.pendingSpendVerifier = spendVerifier;
        v.notBefore = _toUint40(notBefore);
        emit VerifierUpdateQueued(treeUpdateBatchVerifier, spendVerifier, notBefore);
    }

    /// Withdraws the queued pair. Reduces pending authority, so it takes no
    /// delay.
    function cancelVerifierUpdate() external onlyAdmin {
        VerifierStorage.Layout storage v = VerifierStorage.$();
        if (v.notBefore == 0) revert NoPendingVerifierUpdate();
        emit VerifierUpdateCancelled(v.pendingTreeUpdateBatchVerifier, v.pendingSpendVerifier);
        _clearPendingVerifiers(v);
    }

    /// Promotes the queued pair once its window has elapsed.
    ///
    /// Permissionless, like `activateUpgrade`: after the window the pair is
    /// fixed, public and has been cancellable throughout, so this call carries
    /// liveness only. While it goes uncalled the current pair keeps verifying.
    function commitVerifierUpdate() external {
        VerifierStorage.Layout storage v = VerifierStorage.$();
        uint256 notBefore = v.notBefore;
        if (notBefore == 0) revert NoPendingVerifierUpdate();
        if (block.timestamp < notBefore) revert VerifierUpdateNotDue(notBefore);

        address treeUpdate = v.pendingTreeUpdateBatchVerifier;
        address spend = v.pendingSpendVerifier;
        emit VerifiersUpdated(treeUpdate, spend, v.treeUpdateBatchVerifier, v.spendVerifier);
        v.treeUpdateBatchVerifier = treeUpdate;
        v.spendVerifier = spend;
        _clearPendingVerifiers(v);
    }

    function _clearPendingVerifiers(VerifierStorage.Layout storage v) private {
        v.pendingTreeUpdateBatchVerifier = address(0);
        v.pendingSpendVerifier = address(0);
        v.notBefore = 0;
    }

    // ============== Pause ====================================================

    /// Halts spends for `duration` and defers any pending upgrade by the same
    /// amount, so the window continues to measure unpaused time.
    ///
    /// Repeatable: a single pause is capped at `MAX_PAUSE`, and the admin is the
    /// Timelock, so each pause costs a full proposal cycle. The latch this used
    /// to carry existed to bound a guardian that could pause without one.
    function pauseSpends(uint256 duration) external onlyAdmin {
        if (duration == 0 || duration > MAX_PAUSE) revert PauseTooLong();
        UpgradeStorage.Layout storage l = UpgradeStorage.$();

        uint256 until = block.timestamp + duration;
        l.pausedUntil = _toUint40(until);

        uint256 newActivationAt = l.activationAt;
        if (l.pendingImplementation != address(0)) {
            newActivationAt += duration;
            l.activationAt = _toUint40(newActivationAt);
        }

        // A queued verifier pair is deferred by the same amount and for the same
        // reason: its notice must measure unpaused time.
        VerifierStorage.Layout storage v = VerifierStorage.$();
        if (v.notBefore != 0) {
            v.notBefore = _toUint40(uint256(v.notBefore) + duration);
        }
        emit SpendsPaused(until, newActivationAt);
    }

    /// Transfers proxy administration to `newAdmin`.
    ///
    /// Required by deployment order: the proxy requires an admin at
    /// construction, before governance exists. The deployer administers it until
    /// this call hands the seat to the Timelock.
    ///
    /// Confers no authority the caller lacks, since an admin can already queue an
    /// arbitrary implementation.
    function changeProxyAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAdmin();
        emit ProxyAdminChanged(ERC1967Utils.getAdmin(), newAdmin);
        ERC1967Utils.changeAdmin(newAdmin);
    }

    // ============== Views ====================================================

    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    function proxyAdmin() external view returns (address) {
        return ERC1967Utils.getAdmin();
    }

    function spendsPausedUntil() external view returns (uint256) {
        return UpgradeStorage.$().pausedUntil;
    }

    function pendingUpgrade() external view returns (address pending, uint256 activationAt) {
        UpgradeStorage.Layout storage l = UpgradeStorage.$();
        return (l.pendingImplementation, l.activationAt);
    }

    /// The live verifier pair. The pool exposes the same two addresses as
    /// `TREE_UPDATE_BATCH_VERIFIER` and `SPEND_VERIFIER`; both read this slot.
    function verifiers() external view returns (address treeUpdateBatchVerifier, address spendVerifier) {
        VerifierStorage.Layout storage v = VerifierStorage.$();
        return (v.treeUpdateBatchVerifier, v.spendVerifier);
    }

    /// The queued pair and the earliest time `commitVerifierUpdate` will take
    /// it. All three are zero when nothing is queued. `notBefore` already
    /// accounts for every pause since queueing, so it can exceed the figure the
    /// queueing event reported.
    function pendingVerifierUpdate()
        external
        view
        returns (address treeUpdateBatchVerifier, address spendVerifier, uint256 notBefore)
    {
        VerifierStorage.Layout storage v = VerifierStorage.$();
        return (v.pendingTreeUpdateBatchVerifier, v.pendingSpendVerifier, v.notBefore);
    }
}
