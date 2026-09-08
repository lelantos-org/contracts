// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IPoolAdmin, IProtocolAdmin, IWrapperAdmin } from "../interfaces/IProtocolAdmin.sol";

/// Owner of `MASP` and `SwapWrapper`, interposed between them and the governance
/// Timelock. It serves two purposes a Timelock owning the pool directly cannot:
///
/// 1. Emergency response inside the timelock delay. Pool admin functions are all
///    `onlyOwner`, so the role is split here instead: the guardian receives only
///    the four one-way switches below, whose boolean arguments are fixed in
///    bytecode.
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
    error NotAContract();
    error PoolMismatch();
    error WrapperMismatch();
    error AdminNotGoverned();

    constructor(address pool_, address wrapper_, address admin_, address guardian_) {
        if (pool_ == address(0) || wrapper_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        POOL = pool_;
        WRAPPER = wrapper_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        // Optional: a zero guardian deploys the no-guardian variant, and governance
        // can grant the role later.
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
    /// Self-calls are refused, so this cannot reach the role-management surface
    /// with `msg.sender == address(this)`.
    function execute(address target, bytes calldata data) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bytes memory) {
        if (target == address(this)) revert SelfCallForbidden();
        if (data.length >= 4) {
            bytes4 sel = bytes4(data[:4]);
            if (sel == Ownable.renounceOwnership.selector || sel == Ownable.transferOwnership.selector) {
                revert OwnershipCallForbidden();
            }
        }
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            // Bubble the target's revert data rather than masking it; a failed
            // proposal should say why.
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /// The only path by which ownership of `POOL` and `WRAPPER` may leave this
    /// contract. Both move in one call, so they cannot end up under different
    /// owners.
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

        emit AdminMigrated(newAdmin);
        Ownable(POOL).transferOwnership(newAdmin);
        Ownable(WRAPPER).transferOwnership(newAdmin);
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

    /// Revokes a swap adapter. An allowlisted adapter is called with escrowed
    /// funds.
    function disallowAdapter(address adapter) external onlyRole(GUARDIAN_ROLE) {
        IWrapperAdmin(WRAPPER).setAdapterAllowed(adapter, false);
        emit GuardianAction(IWrapperAdmin.setAdapterAllowed.selector, 0, adapter);
    }
}
