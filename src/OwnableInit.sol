// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Ownership for a contract deployed behind a proxy.
///
/// OpenZeppelin's `Ownable` assigns the owner in its constructor, which does not
/// run for a proxy: it would write the implementation's storage and leave the
/// proxy unowned. The owner is assigned from an initializer instead.
///
/// `renounceOwnership` is not declared, so ownership cannot be dropped.
/// `transferOwnership` is declared because `ProtocolAdmin.migrateAdmin` calls it
/// and the deploy uses it to hand the pool to governance; once `ProtocolAdmin`
/// holds ownership its `execute` rejects that selector, leaving `migrateAdmin`
/// as the only route.
///
/// `_owner` occupies a sequential slot, matching the position OZ's `Ownable`
/// takes in the inheritance chain.
abstract contract OwnableInit {
    address private _owner;

    /// Mirrors OZ's `Ownable` errors for tooling compatibility.
    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        _requireOwner();
        _;
    }

    /// Held outside the modifier: the check guards functions across four
    /// contracts, and inlining it at each site costs bytecode.
    function _requireOwner() private view {
        if (msg.sender != _owner) revert OwnableUnauthorizedAccount(msg.sender);
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    /// Assigned once, from the initializer. Rejects zero.
    function _initOwner(address owner_) internal {
        if (owner_ == address(0)) revert OwnableInvalidOwner(address(0));
        _owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// Transfers ownership. Rejects zero, so it cannot serve as a renounce.
    function transferOwnership(address newOwner) external onlyOwner {
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        address old = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }
}
