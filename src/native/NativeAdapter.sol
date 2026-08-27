// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { IWrappedNative } from "../interfaces/IWrappedNative.sol";
import { PubInputs } from "../libs/PubInputs.sol";
import { AuxValidation } from "../libs/AuxValidation.sol";

import { IMASPPool } from "../interfaces/IMASPPool.sol";

/// Native-coin bridge for an ERC-20-only MASP. The pool never sees native coin:
/// this adapter wraps on the way in and unwraps on the way out, holding funds
/// only for the duration of a call, plus refunds awaiting collection.
///
/// * `depositNative` — wrap `msg.value`, escrow it via `depositAuthorized` with
///   the adapter as `payer`, then unwrap and return any excess.
/// * `cancelNative` — drive `MASP.cancelDeposit` for an adapter-owned escrow
///   and forward the refund as native coin to whoever funded it. The pool
///   restricts contract payers to cancelling their own deposits, so this is
///   the only way an adapter-owned escrow can be settled by refund.
/// * `withdrawNative` — drive `MASP.withdraw` with the adapter as `recipient`,
///   then unwrap and forward the proceeds to `pi.payer`.
///
/// Every amount is measured as a balance delta across the pool call. MASP's
/// deposit and withdraw fees are not visible here, and a mirrored fee
/// calculation would drift whenever the asset's fee rate changes.
///
/// Ownerless and permissionless. All authority comes from the SNARK public
/// inputs (`pi.payer` names the native recipient on the spend side) or from the
/// adapter's own escrow bookkeeping.
contract NativeAdapter is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IMASPPool public immutable POOL;
    IWrappedNative public immutable WRAPPED_NATIVE;
    IAllowanceTransfer public immutable PERMIT2;

    /// Who funded an adapter-owned escrow, and how much the pool pulled.
    /// `MASP.cancelDeposit` refunds the digest-bound payer, which is the
    /// adapter, so this is the only record of where the coin came from.
    struct Escrow {
        address refundTo;
        uint256 amount;
    }

    mapping(uint256 id => Escrow) public escrows;

    event NativeDeposited(uint256 indexed id, address indexed refundTo, uint256 escrowed, uint256 returned);
    event NativeRefunded(uint256 indexed id, address indexed refundTo, uint256 amount);
    event NativeWithdrawn(address indexed recipient, uint256 amount);

    error ZeroAddress();
    error ZeroValue();
    error AdapterNotPayer();
    error AdapterNotRecipient();
    error AdapterNotRelayer();
    error NothingEscrowed();
    error PullExceedsValue(uint256 pulled, uint256 value);
    error NothingUnshielded();
    error NoEscrowRecord(uint256 id);
    error DepositAlreadySettled(uint256 id);
    error RefundNotFunded(uint256 id);
    error NativeTransferFailed();
    error UnauthorizedNativeSender();

    constructor(IMASPPool pool, IWrappedNative wrappedNative, IAllowanceTransfer permit2) {
        if (address(pool) == address(0)) revert ZeroAddress();
        if (address(wrappedNative) == address(0)) revert ZeroAddress();
        if (address(permit2) == address(0)) revert ZeroAddress();
        POOL = pool;
        WRAPPED_NATIVE = wrappedNative;
        PERMIT2 = permit2;
        _arm();
    }

    /// Only the wrapped-native contract may push raw native coin; every other
    /// inbound path here is an explicit entry point.
    receive() external payable {
        if (msg.sender != address(WRAPPED_NATIVE)) revert UnauthorizedNativeSender();
    }

    /// Re-arm the escrow approvals (ERC-20 → Permit2 → MASP). Idempotent and
    /// permissionless; the constructor already runs it. Both allowances are set
    /// to their infinite sentinel, so this is needed only if a non-standard
    /// wrapped-native token decays them.
    function arm() external {
        _arm();
    }

    function _arm() private {
        IERC20(address(WRAPPED_NATIVE)).forceApprove(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(WRAPPED_NATIVE), address(POOL), type(uint160).max, type(uint48).max);
    }

    // -------- deposit ---------------------------------------------------

    /// Wrap `msg.value` and escrow it into MASP. `d.payer` must be this adapter:
    /// the coin arrives with the call, so no Permit2 signature from the sender
    /// exists and the pool pulls against the adapter's own allowance.
    /// `d.recipient` and `d.outCm` still bind the note to the depositor, so the
    /// adapter learns nothing the pool does not.
    ///
    /// `msg.value` above the pool's pull (deposit amount plus fee) is unwrapped
    /// and returned, so a caller may overshoot instead of computing the fee.
    ///
    /// @return id MASP-assigned deposit id.
    // slither-disable-next-line reentrancy-balance
    function depositNative(
        PubInputs.DepositRequest calldata d,
        AuxValidation.Output calldata aux,
        AuxValidation.Output calldata feeAux
    ) external payable nonReentrant returns (uint256 id) {
        if (msg.value == 0) revert ZeroValue();
        if (d.payer != address(this)) revert AdapterNotPayer();

        IERC20 weth = IERC20(address(WRAPPED_NATIVE));
        uint256 balanceBefore = weth.balanceOf(address(this));
        WRAPPED_NATIVE.deposit{ value: msg.value }();

        id = POOL.depositAuthorized(d, aux, feeAux);

        // What the pool took is the escrowed total (amount plus fee at submit).
        // A non-wrapped-native asset id cannot reach here: the adapter holds no
        // other token and permits none, so the pull would revert.
        uint256 pulled = balanceBefore + msg.value - weth.balanceOf(address(this));
        // Exact zero is a presence test on a measured delta, not arithmetic on
        // an attacker-movable quantity. A partial pull is caught by the record
        // and by the ceiling check below.
        // slither-disable-next-line incorrect-equality
        if (pulled == 0) revert NothingEscrowed();
        // The Permit2 allowance to the pool is unbounded and covers this
        // contract's whole balance, so without this bound a caller who oversizes
        // `d.publicIn` could escrow refunds parked here for other depositors
        // into a note of their own.
        if (pulled > msg.value) revert PullExceedsValue(pulled, msg.value);

        escrows[id] = Escrow({ refundTo: msg.sender, amount: pulled });

        uint256 returned = msg.value - pulled;
        if (returned != 0) {
            WRAPPED_NATIVE.withdraw(returned);
            _sendNative(msg.sender, returned);
        }
        emit NativeDeposited(id, msg.sender, pulled, returned);
    }

    /// Cancel an adapter-owned escrow past MASP's `cancelDelay` and forward
    /// the refund as native coin to the address that funded it. Anyone may
    /// call; the destination is the recorded funder, not the caller. The digest
    /// preimage comes from the deposit's `DepositEscrowed` event, minus `payer`
    /// — that is always this adapter.
    ///
    /// The refund is attributed by the wrapped-balance delta across the pool
    /// call. MASP refuses a cancel of a contract payer's deposit from any other
    /// sender, so the adapter is necessarily the caller; a deposit that is
    /// already settled was flushed and has no refund to forward.
    // slither-disable-next-line reentrancy-balance
    function cancelNative(
        uint256 id,
        uint48 publicIn,
        bytes32 cm,
        uint256[2] calldata cvDep,
        uint64 publicAssetId,
        uint16 fbps,
        uint32 submittedAt,
        PubInputs.FeeNote calldata feeNote
    ) external nonReentrant {
        Escrow memory e = escrows[id];
        if (e.refundTo == address(0)) revert NoEscrowRecord(id);
        if (POOL.escrowed(id) == bytes32(0)) revert DepositAlreadySettled(id);

        // CEI: clear the record before any external call.
        delete escrows[id];

        IERC20 weth = IERC20(address(WRAPPED_NATIVE));
        uint256 balanceBefore = weth.balanceOf(address(this));
        POOL.cancelDeposit(id, publicIn, cm, cvDep, publicAssetId, fbps, address(this), submittedAt, feeNote);
        if (weth.balanceOf(address(this)) - balanceBefore != e.amount) revert RefundNotFunded(id);

        WRAPPED_NATIVE.withdraw(e.amount);
        _sendNative(e.refundTo, e.amount);
        emit NativeRefunded(id, e.refundTo, e.amount);
    }

    // -------- withdraw --------------------------------------------------

    /// Unshield to native coin. The proof must name this adapter as both
    /// `recipient` (the pool pushes wrapped coin here) and `relayer` (MASP
    /// pins `relayer == msg.sender`, and the adapter is the caller).
    ///
    /// The native coin goes to `pi.payer`, a public input of the proof that
    /// carries no other constraint on the spend path. Binding the destination to
    /// the proof keeps the call permissionless for relayers and leaves no field
    /// a front-runner could repoint.
    ///
    /// @return net Native coin forwarded, i.e. the unshield net of MASP's fee.
    // slither-disable-next-line reentrancy-balance
    function withdrawNative(
        IMASPPool.Proof calldata p,
        PubInputs.Transact calldata pi,
        IMASPPool.Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[4] calldata aux
    ) external nonReentrant returns (uint256 net) {
        if (pi.recipient != address(this)) revert AdapterNotRecipient();
        if (pi.relayer != address(this)) revert AdapterNotRelayer();

        IERC20 weth = IERC20(address(WRAPPED_NATIVE));
        uint256 balanceBefore = weth.balanceOf(address(this));
        POOL.withdraw(p, pi, tp, tpi, aux);
        net = weth.balanceOf(address(this)) - balanceBefore;
        // A zero delta means the spend was denominated in another asset, which
        // the pool has pushed here as a token this contract cannot return; the
        // revert undoes the unshield. Exact zero is a presence test on a
        // measured delta: any nonzero value is coin this call unshielded.
        // slither-disable-next-line incorrect-equality
        if (net == 0) revert NothingUnshielded();

        WRAPPED_NATIVE.withdraw(net);
        _sendNative(pi.payer, net);
        emit NativeWithdrawn(pi.payer, net);
    }

    function _sendNative(address to, uint256 amount) private {
        // slither-disable-next-line arbitrary-send-eth,low-level-calls
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
    }
}
