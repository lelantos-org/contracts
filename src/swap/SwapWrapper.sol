// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { PubInputs } from "../libs/PubInputs.sol";
import { AuxValidation } from "../libs/AuxValidation.sol";

import { IMASPSwap } from "./IMASPSwap.sol";
import { ISwapAdapter } from "./ISwapAdapter.sol";

/// Atomic shielded-swap wrapper. Three legs:
///   1. `MASP.withdraw` — unshield A to this wrapper.
///   2. `ISwapAdapter.swap` — A→B, `actualOut >= minOut`.
///   3. `MASP.submitIntentAuthorized` — escrow B back via Permit2.
///
/// SNARK `payer`/`recipient` bind wrapper as sole caller. `minOut`
/// re-checked. Adapter allowlisted. `tokenOut` must be `prepareToken`'d.
contract SwapWrapper is ReentrancyGuardTransient, Ownable {
    using SafeERC20 for IERC20;

    IMASPSwap public immutable POOL;
    IAllowanceTransfer public immutable PERMIT2;
    address public treasury;

    /// adapter ⇒ allowed flag.
    mapping(address adapter => bool allowed) public adapterAllowed;

    event AdapterAllowedSet(address indexed adapter, bool allowed);
    event TreasurySet(address indexed treasury);
    event TokenPrepared(address indexed token);
    event SwapExecuted(
        address indexed adapter,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 actualOut,
        uint256 dust,
        uint256 intentId
    );

    error AdapterNotAllowed();
    error InsufficientOut(uint256 actualOut, uint256 minOut);
    error LeftoverBalance(address token, uint256 amount);
    error MaspPullExceedsActualOut(uint256 actualOut, uint256 pulled);
    error InsufficientWithdraw(uint256 received, uint256 amountIn);
    error WrapperNotPayer();
    error WrapperNotRecipient();
    error WrapperNotRelayer();
    error AmountInZero();
    error MinOutZero();
    error SameToken();
    error ZeroAddress();
    error SwapExpired();

    /// All proofs + PIs for the two MASP entry points, the adapter, and the
    /// token addresses, packed into one struct to avoid stack-depth limits.
    struct SwapArgs {
        // --- tokens + amounts ---
        address tokenIn;
        address tokenOut;
        // Floor on tokenIn received from `MASP.withdraw` (net of its fee). The
        // wrapper swaps the measured receipt, not this value; reverts
        // `InsufficientWithdraw` if less arrives. Set to `publicOut*scale - fee`.
        uint256 amountIn;
        uint256 minOut; // must equal intent_d.publicIn * scale
        // --- venue ---
        address adapter;
        bytes route;
        // Expiry (unix seconds). Wrapper reverts `SwapExpired` past it; also
        // forwarded to the adapter.
        uint256 deadline;
        // --- leg 1: withdraw A from MASP into the wrapper ---
        IMASPSwap.Proof p_w;
        PubInputs.Transact pi_w;
        IMASPSwap.Proof tp_w;
        PubInputs.TreeUpdateBatch tpi_w;
        AuxValidation.Output[2] aux_w;
        // --- leg 2: escrow B into MASP via Permit2 AllowanceTransfer ---
        PubInputs.DepositIntent intent_d;
        AuxValidation.Output[2] aux_d;
    }

    constructor(IMASPSwap pool, IAllowanceTransfer permit2, address owner_, address treasury_) Ownable(owner_) {
        if (address(pool) == address(0)) revert ZeroAddress();
        if (address(permit2) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        POOL = pool;
        PERMIT2 = permit2;
        treasury = treasury_;
        emit TreasurySet(treasury_);
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

    /// One-time-per-token approval bootstrap (idempotent):
    /// ERC20 → Permit2, then Permit2 → MASP (max cap, max expiry).
    function prepareToken(IERC20 token) external {
        token.forceApprove(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token), address(POOL), type(uint160).max, type(uint48).max);
        emit TokenPrepared(address(token));
    }

    // -------- swap ------------------------------------------------------

    /// Execute the three-leg shielded swap atomically.
    /// @return actualOut Adapter-reported output (≥ minOut, asserted).
    /// @return intentId  MASP-assigned id for the deposit intent.
    function swap(SwapArgs calldata a) external nonReentrant returns (uint256 actualOut, uint256 intentId) {
        _validate(a);

        IERC20 inToken = IERC20(a.tokenIn);
        IERC20 outToken = IERC20(a.tokenOut);
        // Snapshot balances so the leftover check tolerates donations: only
        // funds this swap moves must net to zero.
        uint256 inBefore = inToken.balanceOf(address(this));
        uint256 outBefore = outToken.balanceOf(address(this));

        // Leg 1: unshield A. Measure the receipt (MASP nets a withdraw fee).
        POOL.withdraw(a.p_w, a.pi_w, a.tp_w, a.tpi_w, a.aux_w);
        uint256 received = inToken.balanceOf(address(this)) - inBefore;
        if (received < a.amountIn) revert InsufficientWithdraw(received, a.amountIn);

        // Leg 2a: hand the measured A to the adapter; receive `actualOut` of B.
        actualOut = _executeAdapterSwap(a, received);

        // Leg 2b: escrow into MASP via Permit2 + settle dust.
        uint256 dust;
        (intentId, dust) = _escrowAndSettle(a, actualOut);

        // Donation-tolerant leftover invariant: pre-swap balances untouched.
        uint256 leftIn = inToken.balanceOf(address(this));
        if (leftIn != inBefore) revert LeftoverBalance(a.tokenIn, leftIn - inBefore);
        uint256 leftOut = outToken.balanceOf(address(this));
        if (leftOut != outBefore) revert LeftoverBalance(a.tokenOut, leftOut - outBefore);

        emit SwapExecuted(a.adapter, a.tokenIn, a.tokenOut, received, actualOut, dust, intentId);
    }

    // -------- internal --------------------------------------------------

    function _validate(SwapArgs calldata a) private view {
        if (a.amountIn == 0) revert AmountInZero();
        if (a.minOut == 0) revert MinOutZero();
        if (a.tokenIn == a.tokenOut) revert SameToken();
        if (!adapterAllowed[a.adapter]) revert AdapterNotAllowed();
        if (block.timestamp > a.deadline) revert SwapExpired();
        // SNARKs bind funds to this wrapper. The `relayer` check is
        // defense-in-depth (MASP also enforces it) for a clearer early revert.
        if (a.pi_w.recipient != address(this)) revert WrapperNotRecipient();
        if (a.pi_w.relayer != address(this)) revert WrapperNotRelayer();
        if (a.intent_d.payer != address(this)) revert WrapperNotPayer();
    }

    function _executeAdapterSwap(SwapArgs calldata a, uint256 amountIn) private returns (uint256 actualOut) {
        IERC20(a.tokenIn).safeTransfer(a.adapter, amountIn);
        actualOut = ISwapAdapter(a.adapter).swap(a.tokenIn, a.tokenOut, amountIn, a.minOut, a.deadline, a.route);
        if (actualOut < a.minOut) revert InsufficientOut(actualOut, a.minOut);
    }

    /// Escrow B via Permit2; forward dust to treasury. Pull measured via
    /// balance delta (fee total unknown to wrapper). The leftover invariant
    /// is enforced by the caller against pre-swap balance snapshots.
    function _escrowAndSettle(SwapArgs calldata a, uint256 actualOut) private returns (uint256 intentId, uint256 dust) {
        IERC20 outToken = IERC20(a.tokenOut);

        uint256 balanceBefore = outToken.balanceOf(address(this));
        intentId = POOL.submitIntentAuthorized(a.intent_d, a.aux_d);
        uint256 pulled = balanceBefore - outToken.balanceOf(address(this));
        if (pulled > actualOut) revert MaspPullExceedsActualOut(actualOut, pulled);

        // Forward venue output above what MASP pulled (slippage cushion).
        dust = actualOut - pulled;
        if (dust > 0) outToken.safeTransfer(treasury, dust);
    }
}
