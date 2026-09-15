// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IPoolAdmin, IProtocolAdmin, IUpgradeProxyAdmin, IWrapperAdmin } from "../interfaces/IProtocolAdmin.sol";

/// Owner of `MASP` and `SwapWrapper`, interposed between them and the governance
/// Timelock. It serves two purposes a Timelock owning the pool directly cannot:
///
/// 1. Emergency response inside the timelock delay. Pool admin functions are all
///    `onlyOwner`, so the role is split here: the guardian receives only the
///    five one-way actions below, whose direction is fixed in bytecode.
/// 2. A point at which to reject `renounceOwnership` and `transferOwnership`.
///    Either would move ownership out of this contract and disable every admin
///    function, so `execute` refuses both and `migrateAdmin` is the only exit.
///
/// The guardian can disable assets, which then require a proposal to re-enable,
/// but cannot transfer value, change rates, repoint a treasury or allowlist an
/// adapter. Governance holds `DEFAULT_ADMIN_ROLE` and may revoke or rotate the
/// guardian role at any time.
contract ProtocolAdmin is AccessControl {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// Immutable: a settable target would allow a single proposal to re-point
    /// this contract while retaining its role table. Replacing them requires a
    /// new `ProtocolAdmin` and a call to `migrateAdmin`.
    address public immutable POOL;
    address public immutable WRAPPER;

    event AdminMigrated(address indexed newAdmin);
    event GuardianAction(bytes4 indexed selector, uint64 indexed assetId, address indexed target);

    error ZeroAddress();
    error SelfCallForbidden();
    /// `execute` may not carry either `Ownable` ownership selector; see
    /// `migrateAdmin`.
    error OwnershipCallForbidden();
    /// `execute` may not move the pool's proxy admin; see `migrateAdmin`.
    error ProxyAdminCallForbidden();
    /// `migrateAdmin` requires this contract to hold the pool's proxy admin, so
    /// ownership and upgrade authority always leave together.
    error ProxyAdminNotHeld();
    error NotAContract();
    error PoolMismatch();
    error WrapperMismatch();
    error AdminNotGoverned();

    constructor(address pool_, address wrapper_, address admin_, address guardian_) {
        if (pool_ == address(0) || wrapper_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        POOL = pool_;
        WRAPPER = wrapper_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        // Optional: a zero guardian deploys without one, and governance can grant
        // the role later.
        if (guardian_ != address(0)) _grantRole(GUARDIAN_ROLE, guardian_);
    }

    // ============== Governance ===============================================

    /// Arbitrary call as the owner of `POOL` or `WRAPPER`, covering every
    /// non-emergency action: `addAsset`, `addYieldAsset`, `setAssetFee`,
    /// `setCancelDelay`, `setTreasury`, `setYieldParams`, and re-enabling.
    ///
    /// `Ownable.renounceOwnership` and `Ownable.transferOwnership` are both
    /// refused: either moves ownership out of this contract and disables every
    /// admin function. `transferOwnership` rejects only `address(0)`, so a burn
    /// address would otherwise achieve the same result.
    ///
    /// `changeProxyAdmin` is refused for the same reason. This contract is also
    /// the pool's proxy admin, which queues, cancels and pauses upgrades; moving
    /// that seat alone would split upgrade authority from ownership and skip
    /// every check `migrateAdmin` applies.
    ///
    /// Self-calls are refused, so this cannot reach the role-management surface
    /// with `msg.sender == address(this)`.
    function execute(address target, bytes calldata data) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bytes memory) {
        if (target == address(this)) revert SelfCallForbidden();
        if (data.length >= 4) {
            bytes4 sel = bytes4(data[:4]);
            if (sel == Ownable.renounceOwnership.selector || sel == Ownable.transferOwnership.selector) {
                revert OwnershipCallForbidden();
            }
            if (sel == IUpgradeProxyAdmin.changeProxyAdmin.selector) revert ProxyAdminCallForbidden();
        }
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            // Bubbles the target's revert data so a failed proposal reports its
            // cause.
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /// The only path by which ownership of `POOL` and `WRAPPER`, and the pool's
    /// proxy admin, may leave this contract. All three move in one call, so
    /// upgrade authority cannot stay behind with a retired governance while the
    /// successor owns the pool.
    ///
    /// The checks reject misconfiguration: ownership cannot land on an EOA, on a
    /// contract wired to a different pool or wrapper, or on one this Timelock
    /// does not administer. They do not constrain a malicious proposal, since a
    /// hostile successor controls its own getters; the timelock delay and the
    /// guardian's `CANCELLER_ROLE` bound that case.
    ///
    /// Migrating to a new Timelock therefore requires the current one to hold
    /// `DEFAULT_ADMIN_ROLE` on the successor at the time of the call: grant,
    /// migrate, revoke.
    function migrateAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin.code.length == 0) revert NotAContract();
        if (IProtocolAdmin(newAdmin).POOL() != POOL) revert PoolMismatch();
        if (IProtocolAdmin(newAdmin).WRAPPER() != WRAPPER) revert WrapperMismatch();
        // `msg.sender` is the Timelock — it is what holds `DEFAULT_ADMIN_ROLE` here.
        if (!IAccessControl(newAdmin).hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert AdminNotGoverned();
        // Strict rather than skipped: `execute` cannot move the proxy admin, so
        // holding it here is what makes this the single exit for both seats.
        if (IUpgradeProxyAdmin(POOL).proxyAdmin() != address(this)) revert ProxyAdminNotHeld();

        emit AdminMigrated(newAdmin);
        Ownable(POOL).transferOwnership(newAdmin);
        Ownable(WRAPPER).transferOwnership(newAdmin);
        IUpgradeProxyAdmin(POOL).changeProxyAdmin(newAdmin);
    }

    // ============== Guardian =================================================
    //
    // Each function below fixes its direction in bytecode. Re-enabling,
    // un-halting and allowlisting are available only through `execute`.

    /// Blocks new deposits into `id`. Existing notes remain spendable.
    function disableAsset(uint64 id) external onlyRole(GUARDIAN_ROLE) {
        IPoolAdmin(POOL).setAssetDisabled(id, true);
        emit GuardianAction(IPoolAdmin.setAssetDisabled.selector, id, POOL);
    }

    /// Stops further supply to the asset's bound vault, leaving the binding intact.
    function haltYield(uint64 id) external onlyRole(GUARDIAN_ROLE) {
        IPoolAdmin(POOL).setHalted(id, true);
        emit GuardianAction(IPoolAdmin.setHalted.selector, id, POOL);
    }

    /// Withdraws the venue position back to idle. Leaves the asset fully backed at
    /// an unchanged index.
    function emergencyUnwind(uint64 id) external onlyRole(GUARDIAN_ROLE) returns (uint256) {
        emit GuardianAction(IPoolAdmin.emergencyUnwind.selector, id, POOL);
        return IPoolAdmin(POOL).emergencyUnwind(id);
    }

    /// Halts spends and flushes for up to the proxy's `MAX_PAUSE`, deferring any
    /// pending upgrade by the same amount. The proxy latches it to one use until
    /// governance re-arms it with `resetGuardianPause` through `execute`, so the
    /// guardian cannot chain pauses into an indefinite freeze. Escrow cancels
    /// stay open while paused.
    function pauseSpends(uint256 duration) external onlyRole(GUARDIAN_ROLE) {
        IUpgradeProxyAdmin(POOL).pauseSpends(duration);
        emit GuardianAction(IUpgradeProxyAdmin.pauseSpends.selector, 0, POOL);
    }

    /// Revokes a swap adapter. An allowlisted adapter is called with escrowed
    /// funds.
    function disallowAdapter(address adapter) external onlyRole(GUARDIAN_ROLE) {
        IWrapperAdmin(WRAPPER).setAdapterAllowed(adapter, false);
        emit GuardianAction(IWrapperAdmin.setAdapterAllowed.selector, 0, adapter);
    }
}
