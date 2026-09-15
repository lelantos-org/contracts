// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// The pool and wrapper stand-ins `ProtocolAdmin` drives.
///
/// `ProtocolAdmin` calls its two targets through eight selectors
/// (`setAssetDisabled`, `setHalted`, `emergencyUnwind`, `setAdapterAllowed`,
/// `Ownable.transferOwnership`, and the proxy's `proxyAdmin`, `changeProxyAdmin`
/// and `pauseSpends`) and otherwise forwards calls. The real `MASP`
/// would add the spend path to every explored path, and `svm.createBytes`
/// calldata dispatched against its full ABI does not terminate (see
/// `test/symbolic/README.md`).
///
/// Ownership uses the real `Ownable`: the property under proof is that `execute`
/// cannot move it, which a stubbed owner could not demonstrate.
///
/// The proxy admin is a second seat beside ownership, as on
/// `DelayedUpgradeProxy`: `changeProxyAdmin` and `pauseSpends` are gated on
/// `proxyAdmin` rather than on `owner`, and `changeProxyAdmin` is the only way
/// to move it. The real
/// proxy would forward every other selector to an implementation by
/// `delegatecall`, which the proofs here do not depend on.
///
/// Every setter only records its arguments, so a proof can read back which
/// direction a guardian switch was set to.
contract MockAdminTarget is Ownable {
    mapping(uint64 id => bool) public disabled;
    mapping(uint64 id => bool) public halted;
    mapping(address adapter => bool) public adapterAllowed;

    /// Written by `setParam` and `emergencyUnwind`, so a proof can distinguish a
    /// forwarded call from a refused one without reading ownership.
    uint256 public touched;

    /// The upgrade seat. Starts with the owner, as the deployer holds both until
    /// the handover.
    address public proxyAdmin;
    /// The duration of the last `pauseSpends`, so a proof can read back that the
    /// guardian's pause reached the proxy.
    uint256 public pausedFor;

    error NotProxyAdmin();
    error ZeroAdmin();

    constructor(address owner_) Ownable(owner_) {
        proxyAdmin = owner_;
    }

    modifier onlyProxyAdmin() {
        if (msg.sender != proxyAdmin) revert NotProxyAdmin();
        _;
    }

    function changeProxyAdmin(address newAdmin) external onlyProxyAdmin {
        if (newAdmin == address(0)) revert ZeroAdmin();
        proxyAdmin = newAdmin;
    }

    function pauseSpends(uint256 duration) external onlyProxyAdmin {
        pausedFor = duration;
    }

    function setAssetDisabled(uint64 id, bool value) external onlyOwner {
        disabled[id] = value;
    }

    function setHalted(uint64 id, bool value) external onlyOwner {
        halted[id] = value;
    }

    function emergencyUnwind(uint64 id) external onlyOwner returns (uint256) {
        touched = uint256(id);
        return uint256(id);
    }

    function setAdapterAllowed(address adapter, bool value) external onlyOwner {
        adapterAllowed[adapter] = value;
    }

    /// Stands in for the ordinary governance surface (`addAsset`, `setAssetFee`,
    /// `setTreasury`) reached through `execute`. It makes a successful `execute`
    /// reachable, so proofs quantifying over calldata are not satisfied
    /// vacuously by every call reverting.
    function setParam(uint256 v) external onlyOwner {
        touched = v;
    }
}

/// A candidate successor for `migrateAdmin`, which checks three values before
/// transferring ownership: the successor's `POOL`, its `WRAPPER`, and whether the
/// calling Timelock administers it.
///
/// All three are configurable so a proof can quantify over what a successor
/// claims, including the three rejected misconfigurations: a different pool, a
/// different wrapper, or a successor this Timelock does not administer.
contract MockSuccessorAdmin {
    address public POOL;
    address public WRAPPER;

    mapping(bytes32 role => mapping(address account => bool)) internal _roles;

    constructor(address pool_, address wrapper_) {
        POOL = pool_;
        WRAPPER = wrapper_;
    }

    function grant(bytes32 role, address account) external {
        _roles[role][account] = true;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }
}
