// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// The pool and wrapper stand-ins `ProtocolAdmin` drives.
///
/// `ProtocolAdmin` reaches its two targets through exactly five selectors —
/// `setAssetDisabled`, `setHalted`, `emergencyUnwind`, `setAdapterAllowed` and
/// `Ownable.transferOwnership` — and is otherwise a call forwarder. That is the
/// whole of what these proofs need. The real `MASP` behind them would drag the
/// spend path into every path explored, and `svm.createBytes` calldata
/// dispatched against its full ABI is exactly the non-terminating shape
/// `test/symbolic/README.md` warns about.
///
/// Ownership is real `Ownable`, not a stub: the property under proof is that
/// `execute` cannot move it, and a stubbed owner would prove nothing about the
/// selector guard that exists to prevent that.
///
/// Every setter records rather than acts, so a proof can read back which
/// direction a guardian switch was driven in.
contract MockAdminTarget is Ownable {
    mapping(uint64 id => bool) public disabled;
    mapping(uint64 id => bool) public halted;
    mapping(address adapter => bool) public adapterAllowed;

    /// Set by any owner-gated call that is neither an ownership move nor one of
    /// the guardian switches, so a proof can tell "the call went through" from
    /// "the call was refused" without reading ownership.
    uint256 public touched;

    constructor(address owner_) Ownable(owner_) { }

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

    /// Stands in for the ordinary governance surface — `addAsset`,
    /// `setAssetFee`, `setTreasury` — that `execute` exists to reach. Its only
    /// job is to make a successful `execute` reachable, so the proofs that
    /// quantify over calldata are not satisfied vacuously by everything
    /// reverting.
    function setParam(uint256 v) external onlyOwner {
        touched = v;
    }
}

/// A candidate successor for `migrateAdmin`, which reads back three values
/// before handing over: the successor's `POOL`, its `WRAPPER`, and whether the
/// calling Timelock administers it.
///
/// All three are settable so a proof can quantify over what a successor claims,
/// including the three misconfigurations the guards reject — a successor wired
/// to a different pool, to a different wrapper, or one this Timelock does not
/// administer.
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
