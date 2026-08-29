// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { PubInputs } from "../libs/PubInputs.sol";
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
/// `pi_w.payer` binds the address permitted to drive the swap. `minOut` is
/// re-checked and bounds the measured MASP pull, tying the escrowed leg to the
/// venue output. The adapter must be allowlisted, and `tokenOut` must have been
/// passed to `prepareToken`.
///
/// The escrow record and the Permit2 and cancel plumbing come from
/// [MaspEscrowSatellite](../MaspEscrowSatellite.sol); the swap legs, the
/// treasury dust sweep and the per-escrow token record are defined here.
contract SwapWrapper is MaspEscrowSatellite, Ownable {
    using SafeERC20 for IERC20;

    address public treasury;

    mapping(address adapter => bool allowed) public adapterAllowed;

    /// The escrowed token, alongside the base `refundTo`/`amount` record. The
    /// wrapper handles an open set of tokens, so the asset cannot be recovered
    /// from an immutable. Written by `swap`, consumed by `cancelEscrow`.
    mapping(uint256 depositId => address token) internal _escrowToken;

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

    error AdapterNotAllowed();
    error InsufficientOut(uint256 actualOut, uint256 minOut);
    error LeftoverBalance(address token, uint256 amount);
    error InsufficientWithdraw(uint256 received, uint256 amountIn);
    error UnauthorizedSwapCaller(address caller, address authorized);
    error WrapperNotPayer();
    error WrapperNotRecipient();
    error WrapperNotRelayer();
    error AmountInZero();
    error MinOutZero();
    error SameToken();
    error SwapExpired();

    /// Proofs and public inputs for the two MASP entry points, plus the adapter
    /// and token addresses, packed into one struct to stay within stack limits.
    struct SwapArgs {
        // --- tokens + amounts ---
        address tokenIn;
        address tokenOut;
        // Floor on tokenIn received from `MASP.withdraw`, net of its fee; set to
        // `publicOut * scale - fee`. The swap uses the balance-delta receipt,
        // not this value. Reverts `InsufficientWithdraw` if less arrives.
        uint256 amountIn;
        // Floor on the pool's pull: `deposit_d.publicIn * scale`, plus MASP's
        // fee, plus the relayer note's value.
        uint256 minOut;
        // --- venue ---
        address adapter;
        bytes route;
        // Expiry (unix seconds). The wrapper reverts `SwapExpired` past it and
        // forwards it to the adapter.
        uint256 deadline;
        // --- leg 1: withdraw A from MASP into the wrapper ---
        IMASPPool.Proof p_w;
        PubInputs.Transact pi_w;
        IMASPPool.Proof tp_w;
        PubInputs.TreeUpdateBatch tpi_w;
        AuxValidation.Output[6] aux_w;
        // --- leg 2: escrow B into MASP via Permit2 AllowanceTransfer ---
        PubInputs.DepositRequest deposit_d;
        // The depositor's payload for the B note. A deposit carries one payload
        // per leaf and occupies two; the second is `fee_aux_d`.
        AuxValidation.Output aux_d;
        // The relayer leaf's payload. Not optional and not zeroable: MASP runs
        // it through `AuxValidation` like any other, so a zeroed struct reverts
        // `CiphertextTooShort`, and `deposit_d.feeCm == 0` reverts `ZeroCm`.
        // A deployment that does not want to pay a flush relayer sets
        // `deposit_d.feeIn` to zero and still supplies a well-formed payload;
        // the leaf is minted either way.
        //
        // Its value is funded on top of the escrowed principal, out of the
        // slippage cushion `minOut` leaves behind, so `_escrowAndSettle` bounds
        // the pull by `actualOut` and not by `minOut`.
        AuxValidation.Output fee_aux_d;
    }

    constructor(IMASPPool pool, IAllowanceTransfer permit2, address owner_, address treasury_)
        MaspEscrowSatellite(pool, permit2)
        Ownable(owner_)
    {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// Who a canceled escrow refunds to, in which token, and what the pool
    /// pulled for it. `MASP.cancelDeposit` returns the coin to the digest-bound
    /// payer — this wrapper — so without a record the refund would have no
    /// owner.
    function escrows(uint256 depositId) external view returns (address refundTo, address token, uint256 amount) {
        Escrow storage e = _escrows[depositId];
        return (e.refundTo, _escrowToken[depositId], e.amount);
    }

    /// @inheritdoc MaspEscrowSatellite
    function _consumeEscrowToken(uint256 depositId) internal override returns (IERC20 token) {
        token = IERC20(_escrowToken[depositId]);
        delete _escrowToken[depositId];
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

    /// Arm a token for use as a swap output. Required once per `tokenOut`
    /// before any swap escrows into it; idempotent thereafter.
    function prepareToken(IERC20 token) external {
        _approveToken(token);
        emit TokenPrepared(address(token));
    }

    // -------- swap ------------------------------------------------------

    /// Execute the three-leg shielded swap atomically.
    /// @return actualOut Adapter-reported output (≥ minOut, asserted).
    /// @return depositId  MASP-assigned id for the deposit.
    ///
    /// Every amount here is measured as a balance delta across an external call;
    /// this is what `reentrancy-balance` reports. Re-entry is blocked
    /// on both sides (`nonReentrant` here and on the MASP entry points), the
    /// adapter is owner-allowlisted, and the closing leftover invariant reverts
    /// on any net drift in either token, so a stale snapshot cannot settle
    /// silently.
    // slither-disable-next-line reentrancy-balance
    function swap(SwapArgs calldata a) external nonReentrant returns (uint256 actualOut, uint256 depositId) {
        _validate(a);

        IERC20 inToken = IERC20(a.tokenIn);
        IERC20 outToken = IERC20(a.tokenOut);
        // Snapshot balances so the leftover check tolerates donations: only the
        // funds this swap moves must net to zero.
        uint256 inBefore = inToken.balanceOf(address(this));
        uint256 outBefore = outToken.balanceOf(address(this));

        // Leg 1: unshield A. The receipt is measured by balance delta, because
        // MASP nets a withdraw fee.
        POOL.withdraw(a.p_w, a.pi_w, a.tp_w, a.tpi_w, a.aux_w);
        uint256 received = inToken.balanceOf(address(this)) - inBefore;
        if (received < a.amountIn) revert InsufficientWithdraw(received, a.amountIn);

        // Leg 2a: forward the received A to the adapter, receiving `actualOut`
        // of B.
        actualOut = _executeAdapterSwap(a, received);

        // Leg 2b: escrow into MASP via Permit2 and settle dust.
        uint256 dust;
        (depositId, dust) = _escrowAndSettle(a, actualOut);

        // Donation-tolerant leftover invariant: the pre-swap balances must be
        // untouched. Drift is reported as a magnitude, since a balance below the
        // snapshot violates the invariant as much as one above, and a
        // fixed-direction subtraction would underflow.
        uint256 leftIn = inToken.balanceOf(address(this));
        if (leftIn != inBefore) revert LeftoverBalance(a.tokenIn, _absDiff(leftIn, inBefore));
        uint256 leftOut = outToken.balanceOf(address(this));
        if (leftOut != outBefore) revert LeftoverBalance(a.tokenOut, _absDiff(leftOut, outBefore));

        emit SwapExecuted(a.adapter, a.tokenIn, a.tokenOut, received, actualOut, dust, depositId);
    }

    // -------- internal --------------------------------------------------

    function _validate(SwapArgs calldata a) private view {
        if (a.amountIn == 0) revert AmountInZero();
        if (a.minOut == 0) revert MinOutZero();
        if (a.tokenIn == a.tokenOut) revert SameToken();
        if (!adapterAllowed[a.adapter]) revert AdapterNotAllowed();
        if (block.timestamp > a.deadline) revert SwapExpired();
        // The proofs bind the funds to this wrapper. The `relayer` check is
        // defense-in-depth (MASP also enforces it) and gives an earlier revert.
        if (a.pi_w.recipient != address(this)) revert WrapperNotRecipient();
        if (a.pi_w.relayer != address(this)) revert WrapperNotRelayer();
        if (a.deposit_d.payer != address(this)) revert WrapperNotPayer();
        // `swap` is permissionless, and `deposit_d`, which names the output
        // note's commitments and recipient, is unauthenticated calldata. Without
        // this check the withdraw proof could be replayed from the mempool under
        // a different deposit, redirecting the swap output. `payer` is a public
        // input of the withdraw proof and carries no other constraint on the
        // spend path, so it names the address permitted to drive the swap.
        if (msg.sender != a.pi_w.payer) revert UnauthorizedSwapCaller(msg.sender, a.pi_w.payer);
    }

    function _absDiff(uint256 x, uint256 y) private pure returns (uint256) {
        return x > y ? x - y : y - x;
    }

    function _executeAdapterSwap(SwapArgs calldata a, uint256 amountIn) private returns (uint256 actualOut) {
        IERC20(a.tokenIn).safeTransfer(a.adapter, amountIn);
        actualOut = ISwapAdapter(a.adapter).swap(a.tokenIn, a.tokenOut, amountIn, a.minOut, a.deadline, a.route);
        if (actualOut < a.minOut) revert InsufficientOut(actualOut, a.minOut);
    }

    /// Escrow B via Permit2 and forward dust to the treasury. The pull is
    /// measured by balance delta, because the fee total is not visible to the
    /// wrapper. The leftover invariant is enforced by the caller against the
    /// pre-swap balance snapshots.
    ///
    /// Reached only from `swap`, which holds the reentrancy guard; see there for
    /// why the balance-delta measurement is sound.
    // slither-disable-next-line reentrancy-balance
    function _escrowAndSettle(SwapArgs calldata a, uint256 actualOut)
        private
        returns (uint256 depositId, uint256 dust)
    {
        IERC20 outToken = IERC20(a.tokenOut);

        // The pull must land in `[minOut, actualOut]`. The floor constrains
        // `deposit_d`: the escrowed leg must be denominated in `tokenOut`, as
        // any other asset yields a zero delta, and must carry at least the
        // requested output rather than routing it to the treasury as dust. The
        // ceiling is `actualOut` rather than `minOut`, leaving the relayer note
        // fundable out of the slippage cushion.
        uint256 balanceBefore = outToken.balanceOf(address(this));
        uint256 pulled;
        (depositId, pulled) =
            _escrowMeasured(outToken, balanceBefore, a.minOut, actualOut, a.deposit_d, a.aux_d, a.fee_aux_d);

        // The pool refunds this wrapper, not the swap's driver, so a cancel
        // needs a record of who the escrow belongs to. `pi_w.payer` is the
        // address authorized to drive this swap (see `_validate`).
        _escrows[depositId] = Escrow({ refundTo: a.pi_w.payer, amount: uint96(pulled) });
        _escrowToken[depositId] = a.tokenOut;

        // Forward venue output above what MASP pulled (slippage cushion).
        dust = actualOut - pulled;
        if (dust > 0) outToken.safeTransfer(treasury, dust);
    }

    // -------- escrow recovery -------------------------------------------

    /// Cancel an escrow this wrapper created and return the refund to the
    /// address that drove the swap. Anyone may call; the destination is the
    /// recorded driver, not the caller. The digest preimage comes from the
    /// deposit's `DepositEscrowed` event, minus `payer` — always this wrapper.
    ///
    /// `feeNote` is the relayer leaf's half of that preimage. The wrapper
    /// cannot reconstruct it: MASP binds it at submit from caller-supplied
    /// calldata and stores only the digest, so it has to come back in from the
    /// event like every other preimage field.
    ///
    /// Without this, an escrow that is never flushed is unrecoverable: MASP
    /// refunds the digest-bound payer, and a contract payer may only cancel its
    /// own deposit, so no other party can reach it.
    ///
    /// The refund is attributed by balance delta across the pool call, which is
    /// sound because the wrapper is necessarily the caller. A deposit that is
    /// already settled was flushed and has no refund to forward.
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
