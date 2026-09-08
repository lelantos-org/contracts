// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Minimal stand-in for Permit2's `AllowanceTransfer` surface.
///
/// `MASP.depositAuthorized` reaches Permit2 through exactly one function —
/// `transferFrom(from, to, amount, token)` — and `initialize` only requires the
/// address to carry code. The real Permit2 behind that call is an allowance
/// ledger, a nonce bitmap and an EIP-712 signature check; symbolic execution
/// would explore all of it on every deposit, and none of it is what the escrow
/// proofs are about.
///
/// The pull itself stays real: it moves tokens with a genuine ERC-20 transfer,
/// so the pool's balances still have to line up. Only the authorization is
/// elided, and that is Permit2's concern rather than the pool's.
contract MockAllowanceTransfer {
    /// The satellites bootstrap their allowance through this in their
    /// constructors. A real Permit2 records the grant; nothing here reads it
    /// back, because `transferFrom` below does not check one.
    function approve(address, address, uint160, uint48) external { }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        // The real Permit2 debits a signed allowance first; the payer here has
        // granted this contract a plain ERC-20 approval instead.
        IERC20(token).transferFrom(from, to, uint256(amount));
    }
}
