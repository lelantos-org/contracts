// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// The slice of the pool's admin surface the guardian drives.
///
/// Declared here rather than importing `MASP`, which would pull in the pool's
/// whole dependency tree for three selectors. The swap adapters declare their
/// router surfaces for the same reason.
interface IPoolAdmin {
    function setAssetDisabled(uint64 id, bool disabled) external;
    function setHalted(uint64 id, bool halted) external;
    function emergencyUnwind(uint64 id) external returns (uint256);
}

/// The slice of `DelayedUpgradeProxy`'s reserved surface that `ProtocolAdmin`
/// drives as the pool's proxy admin. These selectors are answered by the proxy
/// itself and never reach the implementation.
interface IUpgradeProxyAdmin {
    function proxyAdmin() external view returns (address);
    function changeProxyAdmin(address newAdmin) external;
    function pauseSpends(uint256 duration) external;
}

/// The slice of `SwapWrapper`'s admin surface the guardian drives.
interface IWrapperAdmin {
    function setAdapterAllowed(address adapter, bool allowed) external;
}

/// What `ProtocolAdmin.migrateAdmin` reads back from a candidate successor
/// before handing it the pool.
///
/// These checks catch misconfiguration, not a hostile proposal: a malicious
/// successor controls its own return values. The timelock delay and the
/// guardian's cancel role bound that case.
interface IProtocolAdmin {
    function POOL() external view returns (address);
    function WRAPPER() external view returns (address);
}
