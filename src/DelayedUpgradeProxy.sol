// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import { UpgradeStorage } from "./UpgradeStorage.sol";

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
/// 2. A pause extends the window by its own duration, so paused time does not
///    consume it.
/// 3. `activateUpgrade` is permissionless, so activation requires no keeper.
///    While it goes uncalled the current implementation continues to serve.
/// 4. `cancelUpgrade` only withdraws a queued upgrade.
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
    /// Ceiling on a single guardian pause.
    uint256 public immutable MAX_PAUSE;

    event UpgradeQueued(address indexed newImplementation, uint256 activationAt);
    event UpgradeCancelled(address indexed cancelledImplementation);
    event UpgradeActivated(address indexed newImplementation);
    event SpendsPaused(uint256 pausedUntil, uint256 newActivationAt);
    event GuardianPauseReset();
    event ProxyAdminChanged(address indexed previousAdmin, address indexed newAdmin);

    error NotProxyAdmin();
    error NoPendingUpgrade();
    error UpgradePending();
    error NotYetActivatable(uint256 activationAt);
    error ImplementationHasNoCode();
    error PauseTooLong();
    error GuardianPauseAlreadyUsed();
    error ZeroDelay();
    error ZeroAdmin();

    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }

    /// Held outside the modifier: the check guards five entry points, and
    /// inlining it at each costs bytecode.
    function _requireAdmin() private view {
        if (msg.sender != ERC1967Utils.getAdmin()) revert NotProxyAdmin();
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
    function queueUpgrade(address newImplementation) external onlyAdmin {
        if (newImplementation.code.length == 0) revert ImplementationHasNoCode();
        UpgradeStorage.Layout storage l = UpgradeStorage.$();
        if (l.pendingImplementation != address(0)) revert UpgradePending();

        uint256 activationAt = block.timestamp + UPGRADE_DELAY;
        l.pendingImplementation = newImplementation;
        // uint40 spans timestamps to the year 36,812; see `UpgradeStorage.Layout`.
        // forge-lint: disable-next-line(unsafe-typecast)
        // aderyn-fp-next-line(unsafe-casting)
        l.activationAt = uint40(activationAt);
        emit UpgradeQueued(newImplementation, activationAt);
    }

    /// Withdraws a queued upgrade. Reduces pending authority, so it takes no
    /// delay.
    function cancelUpgrade() external onlyAdmin {
        UpgradeStorage.Layout storage l = UpgradeStorage.$();
        address pending = l.pendingImplementation;
        if (pending == address(0)) revert NoPendingUpgrade();
        l.pendingImplementation = address(0);
        l.activationAt = 0;
        emit UpgradeCancelled(pending);
    }

    /// Promotes the queued implementation once the window has elapsed.
    ///
    /// Permissionless: after the delay the payload is fixed, public and has been
    /// cancellable throughout, so activation carries liveness only. The current
    /// implementation continues to serve until this is called.
    function activateUpgrade() external {
        UpgradeStorage.Layout storage l = UpgradeStorage.$();
        address pending = l.pendingImplementation;
        if (pending == address(0)) revert NoPendingUpgrade();
        uint256 activationAt = l.activationAt;
        if (block.timestamp < activationAt) revert NotYetActivatable(activationAt);

        l.pendingImplementation = address(0);
        l.activationAt = 0;
        ERC1967Utils.upgradeToAndCall(pending, "");
        emit UpgradeActivated(pending);
    }

    // ============== Pause ====================================================

    /// Halts spends for `duration` and defers any pending upgrade by the same
    /// amount, so the window continues to measure unpaused time.
    ///
    /// `guardianPauseUsed` blocks a second pause until governance clears it,
    /// bounding the guardian to a single pause.
    function pauseSpends(uint256 duration) external onlyAdmin {
        if (duration == 0 || duration > MAX_PAUSE) revert PauseTooLong();
        UpgradeStorage.Layout storage l = UpgradeStorage.$();
        if (l.guardianPauseUsed) revert GuardianPauseAlreadyUsed();

        l.guardianPauseUsed = true;
        uint256 until = block.timestamp + duration;
        // uint40 spans timestamps to the year 36,812; see `UpgradeStorage.Layout`.
        // forge-lint: disable-next-line(unsafe-typecast)
        // aderyn-fp-next-line(unsafe-casting)
        l.pausedUntil = uint40(until);

        uint256 newActivationAt = l.activationAt;
        if (l.pendingImplementation != address(0)) {
            newActivationAt += duration;
            // forge-lint: disable-next-line(unsafe-typecast)
            // aderyn-fp-next-line(unsafe-casting)
            l.activationAt = uint40(newActivationAt);
        }
        emit SpendsPaused(until, newActivationAt);
    }

    /// Clears `guardianPauseUsed`, re-arming the guardian's pause. The admin
    /// gates this behind its own governance role.
    function resetGuardianPause() external onlyAdmin {
        UpgradeStorage.$().guardianPauseUsed = false;
        emit GuardianPauseReset();
    }

    /// Transfers proxy administration to `newAdmin`.
    ///
    /// Required by deploy ordering: `ProtocolAdmin` holds the pool address as an
    /// immutable and so cannot precede the proxy, while the proxy requires an
    /// admin at construction. The deployer therefore administers the proxy until
    /// this hands it to governance.
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

    function pendingUpgrade() external view returns (address pending, uint256 activationAt) {
        UpgradeStorage.Layout storage l = UpgradeStorage.$();
        return (l.pendingImplementation, l.activationAt);
    }

    function spendsPausedUntil() external view returns (uint256) {
        return UpgradeStorage.$().pausedUntil;
    }

    function guardianPauseUsed() external view returns (bool) {
        return UpgradeStorage.$().guardianPauseUsed;
    }
}
