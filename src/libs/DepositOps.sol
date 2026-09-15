// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// Two-token deposit pulls for `MASP`, deployed as an external library.
///
/// A deposit whose relayer note is charged in another asset pulls two tokens
/// through Permit2's batch entry points. That code does not fit the pool under
/// the EIP-170 limit, so, like `YieldOps`, it is deployed once at its own
/// address and reached by `delegatecall`. The boundary is the token movement
/// alone: validation, the path decision (`PubInputs.feeInDepositAsset`),
/// pricing, settlement and the escrow record stay in the pool, as do the
/// single-token pulls every other deposit takes, so those pay no library call.
///
/// Under `delegatecall` the library runs in the pool's context: `address(this)`
/// is the pool, so Permit2 sees the pool as spender and delivers to it. The
/// library holds no state, events or errors of its own; a direct call is
/// refused by solc's library call guard.
library DepositOps {
    /// Permit2 witness binding, defined here because both the pool's single
    /// pull and this library's batch pull use it; `MASP` re-exposes both
    /// constants. `piHash = keccak256(abi.encode(d, aux, feeAux))`. The inner
    /// `MASPDeposit(bytes32 piHash)` of the type string must match the
    /// typehash. The type string serves the single and the batch permit alike:
    /// Permit2 prefixes its own primary-type stub to it.
    bytes32 internal constant DEPOSIT_WITNESS_TYPEHASH = keccak256("MASPDeposit(bytes32 piHash)");
    string internal constant DEPOSIT_WITNESS_TYPE_STRING =
        "MASPDeposit witness)MASPDeposit(bytes32 piHash)TokenPermissions(address token,uint256 amount)";

    /// Pulls a signature-authorized two-token deposit with the deposit
    /// witness. The payer signed a `PermitBatchWitnessTransferFrom` over
    /// `[token: maxTotal, feeToken: maxFee]`, in that order, and Permit2 checks
    /// `total` and `feePull` each against its own entry. The two tokens may be
    /// one ERC-20 named by two asset ids.
    function pullSignedBatch(
        ISignatureTransfer permit2,
        address payer,
        IERC20 token,
        uint256 total,
        IERC20 feeToken,
        uint256 feePull,
        uint256 nonce,
        uint256 deadline,
        uint256 maxTotal,
        uint256 maxFee,
        bytes calldata signature,
        bytes32 piHash
    ) external {
        ISignatureTransfer.TokenPermissions[] memory permitted = new ISignatureTransfer.TokenPermissions[](2);
        permitted[0] = ISignatureTransfer.TokenPermissions({ token: address(token), amount: maxTotal });
        permitted[1] = ISignatureTransfer.TokenPermissions({ token: address(feeToken), amount: maxFee });
        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](2);
        details[0] = ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: total });
        details[1] = ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: feePull });
        permit2.permitWitnessTransferFrom(
            ISignatureTransfer.PermitBatchTransferFrom({ permitted: permitted, nonce: nonce, deadline: deadline }),
            details,
            payer,
            keccak256(abi.encode(DEPOSIT_WITNESS_TYPEHASH, piHash)),
            DEPOSIT_WITNESS_TYPE_STRING,
            signature
        );
    }

    /// Pulls an allowance-authorized two-token deposit with a two-entry batch
    /// `transferFrom`. Each entry spends `allowance[payer][token][pool]` on its
    /// own, so the two may name one ERC-20 and each still draws its own amount.
    ///
    /// The caller has checked both amounts against `type(uint160).max`.
    function pullAuthorizedBatch(
        IAllowanceTransfer permit2,
        address payer,
        IERC20 token,
        uint256 total,
        IERC20 feeToken,
        uint256 feePull
    ) external {
        IAllowanceTransfer.AllowanceTransferDetails[] memory t = new IAllowanceTransfer.AllowanceTransferDetails[](2);
        t[0] = IAllowanceTransfer.AllowanceTransferDetails({
            from: payer,
            to: address(this),
            // forge-lint: disable-next-line(unsafe-typecast)
            // aderyn-fp-next-line(unsafe-casting)
            amount: uint160(total),
            token: address(token)
        });
        t[1] = IAllowanceTransfer.AllowanceTransferDetails({
            from: payer,
            to: address(this),
            // forge-lint: disable-next-line(unsafe-typecast)
            // aderyn-fp-next-line(unsafe-casting)
            amount: uint160(feePull),
            token: address(feeToken)
        });
        permit2.transferFrom(t);
    }
}
