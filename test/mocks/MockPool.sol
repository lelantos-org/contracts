// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Stand-in for a pool implementation behind `DelayedUpgradeProxy`.
///
/// Uses sequential storage like `MASP`, so the exit-window state at its ERC-7201
/// slot must not collide with these low slots.
contract MockPoolV1 {
    uint256 public totalDeposited; // slot 0
    mapping(address => uint256) public balanceOf; // slot 1
    uint16 public withdrawBps; // slot 2

    bool private _initialized;

    error AlreadyInitialized();
    error Insufficient();

    function initialize(uint16 withdrawBps_) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        withdrawBps = withdrawBps_;
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }

    function deposit(uint256 amount) external {
        balanceOf[msg.sender] += amount;
        totalDeposited += amount;
    }

    /// Net of the withdraw fee, so a change to the rate is observable.
    function withdraw(uint256 amount) external virtual returns (uint256 net) {
        if (balanceOf[msg.sender] < amount) revert Insufficient();
        balanceOf[msg.sender] -= amount;
        totalDeposited -= amount;
        net = amount - (amount * withdrawBps) / 10_000;
    }
}

/// Same layout with an appended field, the shape an upgrade must take.
contract MockPoolV2 is MockPoolV1 {
    uint256 public extraField; // slot 3, appended

    function version() external pure override returns (uint256) {
        return 2;
    }

    /// A changed withdrawal term: this implementation retains half of every
    /// withdrawal. The exit window lets holders leave before it activates.
    function withdraw(uint256 amount) external override returns (uint256 net) {
        if (balanceOf[msg.sender] < amount) revert Insufficient();
        balanceOf[msg.sender] -= amount;
        totalDeposited -= amount;
        extraField += 1;
        net = amount / 2;
    }
}

/// Declares a selector that collides with the proxy's reserved set, so the
/// collision test can be shown to detect one.
contract SelectorProbe {
    function activateUpgrade() external pure returns (uint256) {
        return 42;
    }
}
