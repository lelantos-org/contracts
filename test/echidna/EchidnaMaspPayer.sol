// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// The fixture payer, as a contract rather than a cheatcode.
///
/// The Foundry suites build this payer with two cheatcodes: `vm.etch` puts
/// `MockERC1271`'s code at a hard-coded address so Permit2 accepts any
/// signature from it, and `vm.prank` then impersonates it for the calls MASP
/// restricts to the payer. Echidna runs on hevm and drives every call from one
/// of its configured senders, so neither trick is available in the shape the
/// Foundry handlers use them.
///
/// Deploying the payer instead gets both properties honestly: it has code, so
/// Permit2 routes signature checking through ERC-1271 and this contract
/// approves anything; and it can originate calls itself through `exec`, so
/// `cancelDeposit`'s `PayerNotSender` guard is satisfied by the real sender
/// rather than by impersonation.
contract EchidnaMaspPayer {
    /// Permissive ERC-1271: any digest, any signature bytes.
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    /// Forward a call so it originates from this contract.
    ///
    /// Deliberately unguarded and deliberately bubbling the revert: the
    /// handler is the only caller, and a swallowed revert here would let a
    /// failed `cancelDeposit` leave the handler's ghost state updated while
    /// the pool's state stayed put — which is exactly the drift the
    /// invariants exist to detect, reported at the wrong place.
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
