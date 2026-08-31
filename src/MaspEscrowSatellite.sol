// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { PubInputs } from "./libs/PubInputs.sol";
import { AuxValidation } from "./libs/AuxValidation.sol";

import { IMASPPool } from "./interfaces/IMASPPool.sol";

/// Base for peripherals that escrow into MASP as their own payer.
///
/// A satellite calls `depositAuthorized` with `d.payer == address(this)` and
/// holds the Permit2 allowance the pool pulls against. The pool therefore
/// refunds the satellite on a cancel rather than the address that funded the
/// deposit, so each escrow carries an on-satellite record of its funder.
///
/// Amounts are measured as balance deltas across the pool call: a satellite
/// cannot observe MASP's deposit fee or the relayer note, and a mirrored fee
/// calculation would diverge whenever an asset's fee rate changed.
///
/// Provided here:
///
/// * `_approveToken` — the ERC-20 → Permit2 → MASP approval pair. *
/// `_escrowMeasured` — `depositAuthorized`, with the pull measured and bounded.
/// * `_cancelAndVerify` — the cancel guards, record clearing, and refund check.
///
/// Payout is left to the subclass: `_cancelAndVerify` returns the destination,
/// token and amount without transferring.
///
/// The escrow record carries no token address, so a satellite holding one
/// immutable token pays no storage for it; that satellite returns the token
/// from `_consumeEscrowToken`, and one handling an open set keeps its own
/// per-escrow record and clears it there.
///
/// Ownerless, and stateless beyond the escrow records. A balance delta is valid
/// only if no re-entry can move the balance between its two reads, so
/// `ReentrancyGuardTransient` is inherited here; subclasses apply
/// `nonReentrant` at their own entry points.
abstract contract MaspEscrowSatellite is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IMASPPool public immutable POOL;
    IAllowanceTransfer public immutable PERMIT2;

    /// The funder of a satellite-owned escrow and the amount the pool pulled
    /// for it. `MASP.cancelDeposit` refunds the digest-bound payer, which is
    /// this contract, so this record is the only source of the funder address.
    ///
    /// `amount` is `uint96` so the pair occupies one slot, saving a cold
    /// `SSTORE` on every escrow. The pool bounds what can land here well below
    /// that width: `publicIn` and `feeIn` are each validated against
    /// `type(uint48).max`, so a pull cannot exceed roughly `2^48 * scale * (2 +
    /// MAX_FEE_BPS/BPS_DENOMINATOR)`, which stays under `type(uint96).max` for
    /// any `scale` below about `1.2e14`. Registered scales are orders of
    /// magnitude smaller.
    ///
    /// On a yield asset that ceiling carries a further factor of the pool's
    /// index, which grows without bound as the venue earns, so the headroom is
    /// large but not permanent. Both `_escrowMeasured` and `_cancelAndVerify`
    /// enforce the width explicitly, so an amount outside the range reverts
    /// rather than truncating.
    struct Escrow {
        address refundTo;
        uint96 amount;
    }

    /// Exposed by each satellite through its own `escrows` getter, which may
    /// fold in additional per-escrow fields.
    mapping(uint256 id => Escrow) internal _escrows;

    error ZeroAddress();
    error NoEscrowRecord(uint256 id);
    error DepositAlreadySettled(uint256 id);
    error RefundNotFunded(uint256 id);
    error PullBelowMin(uint256 pulled, uint256 minPull);
    error PullExceedsMax(uint256 pulled, uint256 maxPull);
    /// The measured pull does not fit `Escrow.amount`; see that struct.
    error EscrowAmountTooLarge(uint256 pulled);

    constructor(IMASPPool pool, IAllowanceTransfer permit2) {
        if (address(pool) == address(0)) revert ZeroAddress();
        if (address(permit2) == address(0)) revert ZeroAddress();
        POOL = pool;
        PERMIT2 = permit2;
    }

    /// Idempotent per-token approval bootstrap: ERC-20 → Permit2 at infinite
    /// allowance, then Permit2 → MASP at maximum cap and expiry. Required again
    /// only if a non-standard token decays either allowance.
    function _approveToken(IERC20 token) internal {
        token.forceApprove(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token), address(POOL), type(uint160).max, type(uint48).max);
    }

    /// Returns the token an escrow is denominated in, and clears any per-escrow
    /// token record the override keeps. `_cancelAndVerify` calls it once its
    /// guards have passed and before any external call, placing that state
    /// change inside the same CEI ordering.
    function _consumeEscrowToken(uint256 id) internal virtual returns (IERC20);

    /// Escrow into MASP and measure the pull as a balance delta.
    ///
    /// Requires the subclass's reentrancy guard; see the contract notice.
    ///
    /// @param token Asset the pull is measured in. @param baseline Balance the
    /// pull is measured against: the caller's snapshot plus any amount it
    /// credits to itself before the pool pulls. @param minPull Inclusive floor
    /// on the measured pull. A deposit denominated in another asset moves none
    /// of `token` and trips it. @param maxPull Inclusive ceiling on the
    /// measured pull. The Permit2 allowance granted to the pool is unbounded
    /// and covers this contract's entire balance, and `d` is unauthenticated
    /// calldata, so without a ceiling an oversized `d.publicIn` would escrow
    /// balances held here for other parties. The pull is separately bounded by
    /// the width of `Escrow.amount`.
    // slither-disable-next-line reentrancy-balance
    function _escrowMeasured(
        IERC20 token,
        uint256 baseline,
        uint256 minPull,
        uint256 maxPull,
        PubInputs.DepositRequest calldata d,
        AuxValidation.Output calldata aux,
        AuxValidation.Output calldata feeAux
    ) internal returns (uint256 id, uint256 pulled) {
        id = POOL.depositAuthorized(d, aux, feeAux);
        pulled = baseline - token.balanceOf(address(this));
        if (pulled < minPull) revert PullBelowMin(pulled, minPull);
        if (pulled > maxPull) revert PullExceedsMax(pulled, maxPull);
        if (pulled > type(uint96).max) revert EscrowAmountTooLarge(pulled);
    }

    /// Cancel a satellite-owned escrow and verify that the refund arrived.
    ///
    /// The digest preimage is supplied from the deposit's `DepositEscrowed`
    /// event, less `payer`, which is always this contract. MASP rejects a
    /// cancel of a contract payer's deposit from any other sender, so this
    /// contract is necessarily the caller and the balance delta attributes to
    /// this refund. An already-settled deposit was flushed and carries no
    /// refund.
    ///
    /// Returns the verified record; the caller performs the payout.
    ///
    /// Requires the subclass's reentrancy guard; see the contract notice.
    // slither-disable-next-line reentrancy-balance
    function _cancelAndVerify(
        uint256 id,
        uint48 publicIn,
        bytes32 cm,
        uint256[2] calldata cvDep,
        uint64 publicAssetId,
        uint16 fbps,
        uint32 submittedAt,
        PubInputs.FeeNote calldata feeNote
    ) internal returns (IERC20 token, address refundTo, uint256 amount) {
        // Storage pointer: a rejected cancel does not load `amount`.
        Escrow storage e = _escrows[id];
        refundTo = e.refundTo;
        if (refundTo == address(0)) revert NoEscrowRecord(id);
        if (POOL.escrowed(id) == bytes32(0)) revert DepositAlreadySettled(id);

        amount = e.amount;
        // CEI: both halves of the record are cleared before any external call.
        delete _escrows[id];
        token = _consumeEscrowToken(id);

        uint256 balanceBefore = token.balanceOf(address(this));
        POOL.cancelDeposit(id, publicIn, cm, cvDep, publicAssetId, fbps, address(this), submittedAt, feeNote);
        // Measured, not asserted equal. On a yield asset the refund is the
        // escrowed units valued at the current index, so it exceeds the amount
        // pulled at submit by whatever the funds earned in escrow; an exact
        // match would revert every cancel once the index has moved, and WETH is
        // the wrapped native token on every deployed chain, so the native path
        // would go with it.
        //
        // The floor catches the failure this guard exists for: an underfunded
        // or partially delivered refund. It does not catch an over-delivery on
        // a plain asset, which would indicate fee-on-transfer behaviour;
        // distinguishing the two here needs the asset's registry entry, which
        // no satellite holds.
        uint256 delta = token.balanceOf(address(this)) - balanceBefore;
        if (delta < amount) revert RefundNotFunded(id);
        if (delta > type(uint96).max) revert EscrowAmountTooLarge(delta);
        // Forwarded to the caller so the payout matches what actually arrived:
        // `NativeAdapter` unwraps this and `SwapWrapper` transfers it, so both
        // follow the index.
        amount = delta;
    }
}
