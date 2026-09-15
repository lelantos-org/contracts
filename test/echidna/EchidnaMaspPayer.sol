// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// The fixture payer as a deployed contract rather than a cheatcode.
///
/// The Foundry suites use `vm.etch` to place `MockERC1271`'s code at a fixed
/// address, so Permit2 accepts any signature from it, and `vm.prank` to
/// impersonate it for payer-restricted calls. Echidna on hevm drives every
/// call from its configured senders, so that approach is unavailable.
///
/// As a deployed contract the payer has code, so Permit2 checks signatures
/// through ERC-1271 and this contract approves any; and it originates its own
/// calls through `exec`, so `cancelDeposit`'s `PayerNotSender` guard sees the
/// real sender.
contract EchidnaMaspPayer {
    /// Permissive ERC-1271: any digest, any signature bytes.
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    /// Forward a call so it originates from this contract.
    ///
    /// Unguarded, since the handler is the only caller. Bubbles the revert: a
    /// swallowed revert would let a failed `cancelDeposit` update the
    /// handler's ghost state while the pool's state stayed unchanged, causing
    /// the invariants to report drift at the wrong place.
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}
