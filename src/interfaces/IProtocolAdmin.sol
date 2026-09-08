// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// The slice of the pool's admin surface the guardian drives.
///
/// Declared here rather than importing `MASP`: the pool sits close to the
/// EIP-170 limit and pulling it in would drag its whole dependency tree along
/// for three selectors. The same reasoning the swap adapters use for their
/// router surfaces.
interface IPoolAdmin {
    function setAssetDisabled(uint64 id, bool disabled) external;
    function setHalted(uint64 id, bool halted) external;
    function emergencyUnwind(uint64 id) external returns (uint256);
}

/// The slice of `SwapWrapper`'s admin surface the guardian drives.
interface IWrapperAdmin {
    function setAdapterAllowed(address adapter, bool allowed) external;
}

/// What `ProtocolAdmin.migrateAdmin` reads back from a candidate successor
/// before handing it the pool.
///
/// These checks stop accidents, not a hostile proposal — a malicious successor
/// can return whatever it likes here. What bounds that is the timelock delay and
/// the guardian's veto.
interface IProtocolAdmin {
    function POOL() external view returns (address);
    function WRAPPER() external view returns (address);
}
