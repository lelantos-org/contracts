// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Minimal stand-in for Permit2's `AllowanceTransfer` surface.
///
/// `MASP.depositAuthorized` reaches Permit2 through one function,
/// `transferFrom(from, to, amount, token)`, and `initialize` only requires the
/// address to have code. The real Permit2 adds an allowance ledger, a nonce
/// bitmap and an EIP-712 signature check, which symbolic execution would explore
/// on every deposit and which the escrow proofs do not concern.
///
/// The pull performs a real ERC-20 transfer, so pool balances remain consistent.
/// Only the Permit2 authorization is omitted, which is Permit2's responsibility
/// rather than the pool's.
contract MockAllowanceTransfer {
    /// Satellites call this from `_approveToken` (`NativeAdapter` in its
    /// constructor, `SwapWrapper` in `prepareToken`). The grant is not recorded,
    /// because `transferFrom` below does not check one.
    function approve(address, address, uint160, uint48) external { }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        // The real Permit2 first debits the Permit2 allowance; here the payer
        // has granted this contract a plain ERC-20 approval instead.
        IERC20(token).transferFrom(from, to, uint256(amount));
    }
}
