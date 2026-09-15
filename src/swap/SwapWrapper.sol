// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { PubInputs } from "../libs/PubInputs.sol";
import { SnarkCompression } from "../SnarkCompression.sol";
import { AuxValidation } from "../libs/AuxValidation.sol";

import { IMASPPool } from "../interfaces/IMASPPool.sol";
import { MaspEscrowSatellite } from "../MaspEscrowSatellite.sol";
import { ISwapAdapter } from "./ISwapAdapter.sol";

/// Atomic shielded-swap wrapper. Three legs:
///   1. `MASP.withdraw` — unshield A to this wrapper.
///   2. `ISwapAdapter.swap` — A to B, with `actualOut >= minOut`.
///   3. `MASP.depositAuthorized` — escrow B back via Permit2.
///
/// `pi_w.recipient` binds the wrapper as the sole unshield destination;
/// `pi_w.payer` binds the address permitted to drive the swap; `pi_w.intentHash`
/// binds the swap's output, floor, venue, deadline and refund owner. `minOut` is
/// re-checked and bounds the measured MASP pull, tying the escrowed leg to the
/// venue output. The adapter must be allowlisted, and `tokenOut` must have been
/// passed to `prepareToken`.
///
/// The escrow record and the Permit2 and cancel plumbing come from
/// [MaspEscrowSatellite](../MaspEscrowSatellite.sol); the swap legs and the
/// treasury dust sweep are defined here.
contract SwapWrapper is MaspEscrowSatellite, Ownable {
    using SafeERC20 for IERC20;

    address public treasury;

    mapping(address adapter => bool allowed) public adapterAllowed;

    event AdapterAllowedSet(address indexed adapter, bool allowed);
    event TreasurySet(address indexed treasury);
    event TokenPrepared(address indexed token);
    event EscrowRefunded(uint256 indexed depositId, address indexed refundTo, address token, uint256 amount);
    event SwapExecuted(
        address indexed adapter,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 actualOut,
        uint256 dust,
        uint256 depositId
    );
    /// The venue leg failed, so what leg 1 received was escrowed back as A.
    /// `reason` is the failure's selector, zero when it carried none.
    event SwapRefunded(
        address indexed adapter,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 dust,
        uint256 depositId,
        bytes4 reason
    );

    error AdapterNotAllowed();
    error InsufficientOut(uint256 actualOut, uint256 minOut);
    error LeftoverBalance(address token, uint256 amount);
    error InsufficientWithdraw(uint256 received, uint256 amountIn);
    error UnauthorizedSwapCaller(address caller, address authorized);
    error WrapperNotPayer();
    error WrapperNotRecipient();
    error WrapperNotRelayer();
    error InvalidRefundTo();
    error IntentMismatch();
    error AmountInZero();
    error MinOutZero();
    error SameToken();
    error SwapExpired();
    error VenueOutOfGas();
    error OnlySelf();
    /// `tokenIn` is not the registry token of the withdraw proof's asset, or the
    /// refund note is denominated in another token.
    error TokenInMismatch();
    /// `tokenOut` is not the registry token of the output note's asset.
    error TokenOutMismatch();

    /// Proofs and public inputs for the two MASP entry points, plus the adapter
    /// and token addresses, packed into one struct to stay within stack limits.
    struct SwapArgs {
        // --- tokens + amounts ---
        address tokenIn;
        address tokenOut;
        // Floor on tokenIn received from `MASP.withdraw`, net of its fee:
        // `publicOut * scale - fee`. The swap uses the balance-delta receipt,
        // not this value. Reverts `InsufficientWithdraw` if less arrives.
        uint256 amountIn;
        // Floor on the pool's pull: `deposit_d.publicIn * scale`, plus MASP's
        // fee, plus the relayer note's value, all in `tokenOut`.
        uint256 minOut;
        // --- venue ---
        address adapter;
        bytes route;
        // Expiry (unix seconds). Past it the venue leg fails `SwapExpired` and
        // the swap refunds; it is also forwarded to the adapter.
        uint256 deadline;
        // Where a cancelled output escrow refunds. Must be an account that can
        // move tokens, never the driver when that is a contract.
        address refundTo;
        // --- leg 1: withdraw A from MASP into the wrapper ---
        IMASPPool.Proof p_w;
        PubInputs.Transact pi_w;
        IMASPPool.Proof tp_w;
        PubInputs.SpendTree tpi_w;
        AuxValidation.Output[6] aux_w;
        // --- leg 2: escrow B into MASP via Permit2 AllowanceTransfer ---
        PubInputs.DepositRequest deposit_d;
        // The depositor's payload for the B note. A deposit occupies two
        // leaves; the second payload is `fee_aux_d`.
        AuxValidation.Output aux_d;
        // The relayer leaf's payload. Not optional and not zeroable: MASP runs
        // it through `AuxValidation` like any other, so a zeroed struct reverts
        // `CiphertextTooShort` and `deposit_d.feeCm == 0` reverts `ZeroCm`. To
        // pay no flush relayer, set `deposit_d.feeIn` to zero and
        // `deposit_d.feeAssetId` to 0, and still supply a well-formed payload;
        // the leaf is minted either way.
        //
        // A valued relayer note is in B: `deposit_d.feeAssetId` must equal
        // `deposit_d.publicAssetId`. The wrapper holds only what the venue
        // delivered, so a note in another asset has nothing to fund it, and
        // `_escrowMeasured` reverts `FeeAssetMismatch`. Its value is funded on
        // top of the escrowed principal, out of the slippage cushion `minOut`
        // leaves behind, so `_escrowAndSettle` bounds the pull by `actualOut`
        // rather than `minOut`.
        AuxValidation.Output fee_aux_d;
        // --- refund: escrow A back into MASP if the venue leg fails ---
        // The A note the unshield returns to when the venue reverts, delivers
        // less than `minOut`, or the deadline has passed. Denominated in
        // `tokenIn`, pulled from what leg 1 received; its payloads play the roles
        // of `aux_d` and `fee_aux_d`, and a valued refund relayer note is in A
        // (`refund_d.feeAssetId == refund_d.publicAssetId`), or 0 when
        // `refund_d.feeIn` is zero.
        PubInputs.DepositRequest refund_d;
        AuxValidation.Output refund_aux_d;
        AuxValidation.Output refund_fee_aux_d;
    }

    /// Gas held back from the venue leg so a failed one can still be refunded:
    /// the refund escrow, the leftover checks and the event. Should the venue
    /// run out of gas instead, `swap` reverts `VenueOutOfGas` rather than refund
    /// a swap that more gas would have completed.
    uint256 internal constant REFUND_GAS_RESERVE = 400_000;

    constructor(IMASPPool pool, IAllowanceTransfer permit2, address owner_, address treasury_)
        MaspEscrowSatellite(pool, permit2)
        Ownable(owner_)
    {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// Who a canceled escrow refunds to, and what the pool pulled for it.
    /// `MASP.cancelDeposit` returns the coin to the digest-bound payer, this
    /// wrapper, so without a record the refund would have no owner. The owner is
    /// the intent-bound `refundTo`. The token is not stored: it is the registry
    /// token of the deposit's `publicAssetId`, read from its `DepositEscrowed`
    /// event.
    function escrows(uint256 depositId) external view returns (address refundTo, uint256 amount) {
        Escrow storage e = _escrows[depositId];
        return (e.refundTo, e.amount);
    }

    /// The registry token of `publicAssetId`. The id is caller-supplied, but
    /// `MASP.cancelDeposit` checks it against the escrow digest in the same call,
    /// and registry tokens never change. It is the token `swap` escrowed: the
    /// pull was measured in `tokenOut`, or in `tokenIn` for a refund, and a
    /// deposit in any other token moves none of it and reverts `PullBelowMin`.
    function _escrowToken(uint256, uint64 publicAssetId) internal view override returns (IERC20 token) {
        token = IERC20(POOL.asset(publicAssetId).token);
    }

    // -------- admin -----------------------------------------------------

    /// @param adapter Adapter contract to flip in the allowlist.
    /// @param allowed New allow state.
    function setAdapterAllowed(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        adapterAllowed[adapter] = allowed;
        emit AdapterAllowedSet(adapter, allowed);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    /// Arms a token for escrow into MASP. Required once per token before any
    /// swap escrows into it, which is every `tokenOut` and, for a refund, every
    /// `tokenIn`; idempotent thereafter.
    function prepareToken(IERC20 token) external {
        _approveToken(token);
        emit TokenPrepared(address(token));
    }

    // -------- swap ------------------------------------------------------

    /// Executes the shielded swap, or refunds it: once leg 1 has unshielded A,
    /// the call lands either way. A venue failure, output below `minOut`, or a
    /// passed deadline escrows A back into MASP as `refund_d` instead of
    /// reverting, so a swap bundled with other operations cannot fail them on
    /// market conditions. What `swap` still reverts on is fixed before it is
    /// sent (the checks in `_validate`, leg 1, a failing escrow), and a venue
    /// short of gas reverts `VenueOutOfGas`.
    ///
    /// Every amount is measured as a balance delta across an external call,
    /// which is what `reentrancy-balance` reports. Re-entry is blocked on both
    /// sides (`nonReentrant` here and on the MASP entry points), the adapter is
    /// owner-allowlisted, and the closing leftover invariant reverts on any net
    /// drift in either token, so a stale snapshot cannot settle silently.
    ///
    /// @return actualOut Adapter-reported output, asserted `>= minOut`; zero if
    ///         the swap was refunded.
    /// @return depositId MASP-assigned id for the deposit, of B or of the
    ///         refunded A.
    // slither-disable-next-line reentrancy-balance
    function swap(SwapArgs calldata a) external nonReentrant returns (uint256 actualOut, uint256 depositId) {
        _validate(a);

        IERC20 inToken = IERC20(a.tokenIn);
        IERC20 outToken = IERC20(a.tokenOut);
        // Snapshot balances so the leftover check tolerates donations: only
        // the funds this swap moves must net to zero.
        uint256 inBefore = inToken.balanceOf(address(this));
        uint256 outBefore = outToken.balanceOf(address(this));

        // Leg 1: unshield A. The receipt is measured by balance delta, as MASP
        // nets a withdraw fee.
        POOL.withdraw(a.p_w, a.pi_w, a.tp_w, a.tpi_w, a.aux_w);
        uint256 received = inToken.balanceOf(address(this)) - inBefore;
        if (received < a.amountIn) revert InsufficientWithdraw(received, a.amountIn);

        // Leg 2a: forward the received A to the adapter, receiving `actualOut`
        // of B. A failure unwinds inside its own frame, leaving A here.
        (bool swapped, uint256 out, bytes4 reason) = _tryVenueLeg(a, received);

        // Leg 2b: escrow B into MASP via Permit2, or A back. B's pull must land
        // in `[minOut, actualOut]`: the floor makes `deposit_d` carry at least
        // the requested output, and the ceiling is `actualOut` rather than
        // `minOut`, leaving the relayer note fundable from the slippage cushion.
        // A refund's pull must land in `[1, received]`: its size is the intent's,
        // which the wallet sets to what leg 1 delivers.
        uint256 dust;
        if (swapped) {
            actualOut = out;
            (depositId, dust) = _escrowAndSettle(outToken, a.minOut, out, a.deposit_d, a.aux_d, a.fee_aux_d, a.refundTo);
            emit SwapExecuted(a.adapter, a.tokenIn, a.tokenOut, received, out, dust, depositId);
        } else {
            (depositId, dust) =
                _escrowAndSettle(inToken, 1, received, a.refund_d, a.refund_aux_d, a.refund_fee_aux_d, a.refundTo);
            emit SwapRefunded(a.adapter, a.tokenIn, received, dust, depositId, reason);
        }

        // Donation-tolerant leftover invariant: the pre-swap balances must be
        // untouched. Drift is reported as a magnitude, since a balance below the
        // snapshot violates the invariant as much as one above and a
        // fixed-direction subtraction would underflow.
        uint256 leftIn = inToken.balanceOf(address(this));
        if (leftIn != inBefore) revert LeftoverBalance(a.tokenIn, _absDiff(leftIn, inBefore));
        uint256 leftOut = outToken.balanceOf(address(this));
        if (leftOut != outBefore) revert LeftoverBalance(a.tokenOut, _absDiff(leftOut, outBefore));
    }

    /// Leg 2a of `swap` in a frame of its own, so that a failure can be caught
    /// with A still on the wrapper. Only the wrapper may call it, and only from
    /// `swap`, which holds the guard.
    function venueLeg(
        address tokenIn,
        address tokenOut,
        address adapter,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        bytes calldata route
    ) external returns (uint256 actualOut) {
        if (msg.sender != address(this)) revert OnlySelf();
        if (block.timestamp > deadline) revert SwapExpired();
        IERC20(tokenIn).safeTransfer(adapter, amountIn);
        actualOut = ISwapAdapter(adapter).swap(tokenIn, tokenOut, amountIn, minOut, deadline, route);
        if (actualOut < minOut) revert InsufficientOut(actualOut, minOut);
    }

    // -------- internal --------------------------------------------------

    function _validate(SwapArgs calldata a) private view {
        if (a.amountIn == 0) revert AmountInZero();
        if (a.minOut == 0) revert MinOutZero();
        if (a.tokenIn == a.tokenOut) revert SameToken();
        if (!adapterAllowed[a.adapter]) revert AdapterNotAllowed();
        // The deadline is checked in `venueLeg`, where a passed one refunds.
        // The proofs bind the funds to this wrapper. The `relayer` check
        // duplicates MASP's as defense in depth and reverts earlier.
        if (a.pi_w.recipient != address(this)) revert WrapperNotRecipient();
        if (a.pi_w.relayer != address(this)) revert WrapperNotRelayer();
        if (a.deposit_d.payer != address(this) || a.refund_d.payer != address(this)) revert WrapperNotPayer();
        // `swap` is permissionless, so without this check a withdraw proof
        // could be lifted from the mempool and landed by anyone. `payer` is a
        // public input of the withdraw proof with no other constraint on the
        // spend path, so it names the address permitted to drive the swap.
        if (msg.sender != a.pi_w.payer) revert UnauthorizedSwapCaller(msg.sender, a.pi_w.payer);
        // A cancelled escrow pays out to `refundTo`. Zero reads as "no record"
        // in `_cancelAndVerify`, and this wrapper cannot pay itself, so either
        // would strand the escrow.
        if (a.refundTo == address(0) || a.refundTo == address(this)) revert InvalidRefundTo();
        // Every amount below is measured as a balance delta in `tokenIn` or
        // `tokenOut`, so each must be the token the pool actually moves on that
        // leg. `tokenIn` is outside the intent, but `pi_w.publicAssetId` is a
        // proof input, so binding it to that asset's registry token fixes it.
        // Without these checks a token with a scripted `balanceOf` passes every
        // pull bound and the leftover check, while `refund_d` escrows whatever
        // real token the wrapper holds into the caller's note.
        address inToken = POOL.asset(a.pi_w.publicAssetId).token;
        if (a.tokenIn != inToken) revert TokenInMismatch();
        if (a.refund_d.publicAssetId != a.pi_w.publicAssetId && POOL.asset(a.refund_d.publicAssetId).token != inToken) {
            revert TokenInMismatch();
        }
        if (a.tokenOut != POOL.asset(a.deposit_d.publicAssetId).token) revert TokenOutMismatch();
        // `deposit_d`, `refund_d` and their payloads, `tokenOut`, `minOut`,
        // `adapter`, `deadline` and `refundTo` are calldata the proof does not
        // carry. The withdraw proof commits to their hash instead, so the driver,
        // the payer included, cannot redirect the output or refund note, lower
        // the floor, swap the venue, extend the deadline or take the refund.
        // `route` stays free: it cannot deliver less than `minOut`. Checked last,
        // so a malformed field still reports its own error.
        if (a.pi_w.intentHash != _intentHash(a)) revert IntentMismatch();
    }

    /// The value a swap's withdraw proof must carry as `pi_w.intentHash`:
    /// `keccak256(abi.encode(refundTo, tokenOut, minOut, adapter, deadline,
    /// deposit_d, aux_d, fee_aux_d, refund_d, refund_aux_d, refund_fee_aux_d))`
    /// reduced into the BN254 scalar field, so every off-chain challenge
    /// implementation handles it as a field element. `DepositRequest` encodes
    /// in place, `feeAssetId` included, so its field order is part of this
    /// preimage.
    function _intentHash(SwapArgs calldata a) private pure returns (uint256) {
        return uint256(
            keccak256(
            abi.encode(
            a.refundTo,
            a.tokenOut,
            a.minOut,
            a.adapter,
            a.deadline,
            a.deposit_d,
            a.aux_d,
            a.fee_aux_d,
            a.refund_d,
            a.refund_aux_d,
            a.refund_fee_aux_d
        )
        )
        ) % SnarkCompression.R;
    }

    function _absDiff(uint256 x, uint256 y) private pure returns (uint256) {
        return x > y ? x - y : y - x;
    }

    /// Runs `venueLeg` with all gas but `REFUND_GAS_RESERVE`. A failure is
    /// returned rather than propagated, with its selector, unless the leg used
    /// at least 7/8 of its gas: that reads as a limit too low, and refunding
    /// would settle a swap that a higher limit would have completed, so it
    /// reverts `VenueOutOfGas` for the sender to retry with more.
    ///
    /// The slack covers the 1/64 each nested frame keeps back (EIP-150). An
    /// out-of-gas `d` frames below `venueLeg` leaves roughly `d/64` of the
    /// budget unspent, since each ancestor returns the share it retained. The
    /// V3 path is 3–5 frames deep (`venueLeg`, adapter, router, pool, token
    /// callback), and misclassifying such an out-of-gas as a market failure
    /// would let the driver, who picks the gas limit, force a refund. 1/8
    /// covers about eight frames. The cost is that a venue that
    /// reverts on its own after spending over 7/8 of its budget reverts the
    /// swap instead of refunding it; the sender retries with more gas and gets
    /// the refund then.
    function _tryVenueLeg(SwapArgs calldata a, uint256 amountIn)
        private
        returns (bool swapped, uint256 actualOut, bytes4 reason)
    {
        uint256 g = gasleft();
        if (g <= REFUND_GAS_RESERVE) revert VenueOutOfGas();
        uint256 budget = g - REFUND_GAS_RESERVE;
        try this.venueLeg{ gas: budget }(
            a.tokenIn, a.tokenOut, a.adapter, amountIn, a.minOut, a.deadline, a.route
        ) returns (
            uint256 out
        ) {
            return (true, out, bytes4(0));
        } catch {
            if (g - gasleft() >= budget - budget / 8) revert VenueOutOfGas();
            assembly ("memory-safe") {
                if gt(returndatasize(), 3) {
                    returndatacopy(0x00, 0, 4)
                    reason := shl(224, shr(224, mload(0x00)))
                }
            }
        }
    }

    /// Escrows `d` in `token` via Permit2, pulling within `[minPull, available]`,
    /// and forwards the rest of `available` to the treasury: the venue's
    /// slippage cushion for B, rounding for a refund of A. The pull is measured
    /// by balance delta, as the fee total is not visible to the wrapper. The
    /// floor also proves `d` is denominated in `token`, as any other asset
    /// yields a zero delta, and the ceiling keeps balances held here for other
    /// parties out of reach. The caller enforces the leftover invariant against
    /// the pre-swap snapshots.
    ///
    /// Reached only from `swap`, which holds the reentrancy guard; see there for
    /// why the balance-delta measurement is sound.
    // slither-disable-next-line reentrancy-balance
    function _escrowAndSettle(
        IERC20 token,
        uint256 minPull,
        uint256 available,
        PubInputs.DepositRequest calldata d,
        AuxValidation.Output calldata aux,
        AuxValidation.Output calldata feeAux,
        address refundTo
    ) private returns (uint256 depositId, uint256 dust) {
        uint256 pulled;
        (depositId, pulled) = _escrowMeasured(token, token.balanceOf(address(this)), minPull, available, d, aux, feeAux);

        // The pool refunds this wrapper, so a cancel needs a record of who the
        // escrow belongs to. That is `refundTo`, not `pi_w.payer`: the payer is
        // whoever drives the swap, which may be a contract with no way to move
        // tokens out, such as a relayer's `Bundler`. `refundTo` is intent-bound,
        // so the driver cannot redirect it.
        _escrows[depositId] = Escrow({ refundTo: refundTo, amount: uint96(pulled) });

        dust = available - pulled;
        if (dust > 0) token.safeTransfer(treasury, dust);
    }

    // -------- escrow recovery -------------------------------------------

    /// Cancels an escrow this wrapper created and returns the refund to the
    /// intent-bound `refundTo`. Anyone may call; the destination is the
    /// recorded `refundTo`, not the caller. The digest preimage comes from the
    /// deposit's `DepositEscrowed` event, less `payer`, which is always this
    /// wrapper.
    ///
    /// `feeNote` is the relayer leaf's half of that preimage. The wrapper cannot
    /// reconstruct it: MASP binds it at submit from caller-supplied calldata and
    /// stores only the digest, so it comes back in from the event like every
    /// other preimage field.
    ///
    /// Without this, an escrow that is never flushed is unrecoverable: MASP
    /// refunds the digest-bound payer, and a contract payer may cancel only its
    /// own deposit.
    ///
    /// The refund is attributed by balance delta across the pool call, sound
    /// because the wrapper is necessarily the caller. An already-settled deposit
    /// was flushed and has no refund to forward.
    // slither-disable-next-line reentrancy-balance
    function cancelEscrow(
        uint256 depositId,
        uint48 publicIn,
        bytes32 cm,
        uint256[2] calldata cvDep,
        uint64 publicAssetId,
        uint16 fbps,
        uint32 submittedAt,
        PubInputs.FeeNote calldata feeNote
    ) external nonReentrant {
        (IERC20 token, address refundTo, uint256 amount) = _cancelAndVerify(
            depositId, publicIn, cm, cvDep, publicAssetId, fbps, submittedAt, feeNote
        );

        token.safeTransfer(refundTo, amount);
        emit EscrowRefunded(depositId, refundTo, address(token), amount);
    }
}
