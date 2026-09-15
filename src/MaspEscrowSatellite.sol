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
/// refunds the satellite on a cancel, not the address that funded the deposit,
/// so each escrow carries an on-satellite record of its funder.
///
/// Amounts are measured as balance deltas across the pool call: a satellite
/// cannot observe MASP's deposit fee or the relayer note, and a mirrored fee
/// calculation would diverge on any rate change.
///
/// Provided here:
///
/// - `_approveToken` — the ERC-20 → Permit2 → MASP approval pair.
/// - `_escrowMeasured` — `depositAuthorized`, with the pull measured and
///   bounded.
/// - `_cancelAndVerify` — the cancel guards, record clearing, and refund check.
///
/// Payout is left to the subclass: `_cancelAndVerify` returns the destination,
/// token and amount without transferring.
///
/// The escrow record carries no token address. A satellite returns the token
/// from `_escrowToken`: an immutable one, or the registry token of the
/// digest-checked `publicAssetId`.
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
    /// for it. `MASP.cancelDeposit` refunds the digest-bound payer, this
    /// contract, so this record is the only source of the funder address.
    ///
    /// `amount` is `uint96` so the pair occupies one slot. The pool bounds what
    /// can land here well below that width: `publicIn` and `feeIn` are each
    /// validated against `type(uint48).max`, so a pull cannot exceed roughly
    /// `2^48 * scale * (2 + MAX_FEE_BPS/BPS_DENOMINATOR)`, under
    /// `type(uint96).max` for any `scale` below about `1.2e14`. Registered
    /// scales are far smaller.
    ///
    /// On a yield asset that ceiling carries a further factor of the pool's
    /// index, which grows as the venue earns, so the headroom is not permanent.
    /// `_escrowMeasured` enforces the width, so an out-of-range amount reverts
    /// rather than truncating. A cancel refunds at most the recorded pull.
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
    /// The balance that arrived differs from the refund the pool reports paying.
    error RefundMismatch(uint256 id, uint256 delivered, uint256 reported);
    error PullBelowMin(uint256 pulled, uint256 minPull);
    error PullExceedsMax(uint256 pulled, uint256 maxPull);
    /// The measured pull does not fit `Escrow.amount`; see that struct.
    error EscrowAmountTooLarge(uint256 pulled);
    /// The relayer note is charged in another asset than the deposit
    /// (`PubInputs.feeInDepositAsset` fails). A satellite measures and refunds
    /// one token, so it escrows only deposits whose whole pull is in that token.
    error FeeAssetMismatch();

    constructor(IMASPPool pool, IAllowanceTransfer permit2) {
        if (address(pool) == address(0)) revert ZeroAddress();
        if (address(permit2) == address(0)) revert ZeroAddress();
        POOL = pool;
        PERMIT2 = permit2;
    }

    /// Idempotent per-token approval bootstrap: ERC-20 → Permit2 at infinite
    /// allowance, then Permit2 → MASP at maximum cap and expiry. Needed again
    /// only if a non-standard token decays either allowance.
    function _approveToken(IERC20 token) internal {
        token.forceApprove(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token), address(POOL), type(uint160).max, type(uint48).max);
    }

    /// Returns the token an escrow is denominated in. `publicAssetId` is not yet
    /// checked when this runs; `POOL.cancelDeposit` checks it against the digest
    /// in the same call, so an override may derive the token from it.
    function _escrowToken(uint256 id, uint64 publicAssetId) internal virtual returns (IERC20);

    /// Escrows into MASP and measures the pull as a balance delta. Requires the
    /// subclass's reentrancy guard; see the contract notice.
    ///
    /// @param token Asset the pull is measured in. Must be the registry token of
    /// `d.publicAssetId`, derived by the caller from something the caller cannot
    /// choose: a token taken from calldata can report any balance, satisfying
    /// both bounds while the pool pulls a different token held here.
    /// @param baseline Balance the pull is measured against: the caller's
    /// snapshot plus any amount it credits to itself before the pool pulls.
    /// @param minPull Inclusive floor on the measured pull. A deposit
    /// denominated in another asset moves none of `token` and trips it. A
    /// relayer note charged in another asset is rejected up front
    /// (`FeeAssetMismatch`): the pool would pull a second token, possibly one
    /// held here for other parties, which this measurement cannot see.
    /// @param maxPull Inclusive ceiling on the measured pull. The Permit2
    /// allowance granted to the pool covers this contract's entire balance and
    /// `d` is unauthenticated calldata, so without a ceiling an oversized
    /// `d.publicIn` would escrow balances held here for other parties. The pull
    /// is separately bounded by the width of `Escrow.amount`.
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
        // `!PubInputs.feeInDepositAsset(...)`, spelled inline: the optimizer
        // does not inline that call here, and every satellite deposit would
        // pay for the jump.
        if (d.feeIn != 0 && d.feeAssetId != d.publicAssetId) revert FeeAssetMismatch();
        id = POOL.depositAuthorized(d, aux, feeAux);
        pulled = baseline - token.balanceOf(address(this));
        if (pulled < minPull) revert PullBelowMin(pulled, minPull);
        if (pulled > maxPull) revert PullExceedsMax(pulled, maxPull);
        if (pulled > type(uint96).max) revert EscrowAmountTooLarge(pulled);
    }

    /// Cancels a satellite-owned escrow and verifies that the refund arrived.
    /// Returns the verified record; the caller performs the payout. Requires the
    /// subclass's reentrancy guard; see the contract notice.
    ///
    /// The digest preimage is supplied from the deposit's `DepositEscrowed`
    /// event, less `payer`, which is always this contract. MASP rejects a cancel
    /// of a contract payer's deposit from any other sender, so this contract is
    /// necessarily the caller and the balance delta attributes to this refund.
    /// An already-settled deposit was flushed and carries no refund.
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
        refundTo = _escrows[id].refundTo;
        if (refundTo == address(0)) revert NoEscrowRecord(id);
        if (POOL.escrowed(id) == bytes32(0)) revert DepositAlreadySettled(id);

        // CEI: the record is cleared before any external call.
        delete _escrows[id];
        token = _escrowToken(id, publicAssetId);

        uint256 balanceBefore = token.balanceOf(address(this));
        (uint256 reported, uint256 feeRefunded) =
            POOL.cancelDeposit(id, publicIn, cm, cvDep, publicAssetId, fbps, address(this), submittedAt, feeNote);
        // Unreachable for an escrow this contract made, since `_escrowMeasured`
        // refuses a relayer note in another asset. Checked so a second token
        // can never arrive unaccounted for.
        if (feeRefunded != 0) revert FeeAssetMismatch();
        // Checked against the pool's own refund, not the amount pulled at
        // submit. A yield-asset refund is the escrow's value at the current
        // index, floored and capped at the ceilinged pull, so it is at most the
        // recorded amount and falls below it by a wei of rounding at a flat
        // index, or by a venue loss. A floor at the recorded amount would revert
        // those cancels and leave the escrow with no refund path, since the pool
        // accepts a contract payer's cancel only from the payer itself.
        //
        // Equality catches a refund delivered short or long in either direction,
        // including fee-on-transfer behaviour, and the delta is attributable:
        // this contract is the only permitted caller and holds its guard.
        uint256 delta = token.balanceOf(address(this)) - balanceBefore;
        if (delta != reported) revert RefundMismatch(id, delta, reported);
        amount = delta;
    }
}
