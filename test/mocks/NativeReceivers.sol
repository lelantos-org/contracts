// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Native-coin payout recipients with hostile or minimal `receive` hooks, for the
/// `NativeAdapter` force-send tests.

/// Rejects raw native, forcing the `_sendNative` push to fail.
contract NativeRejector {
    receive() external payable {
        revert("no native");
    }
}

/// Writes storage on receipt, which the 2300 stipend cannot pay for.
contract NativeStateWriter {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/// Accepts native on the stipend.
contract NativeAcceptor {
    receive() external payable { }
}
