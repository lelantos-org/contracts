// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { IWrappedNative } from "../interfaces/IWrappedNative.sol";
import { PubInputs } from "../libs/PubInputs.sol";
import { AuxValidation } from "../libs/AuxValidation.sol";

import { IMASPPool } from "../interfaces/IMASPPool.sol";
import { MaspEscrowSatellite } from "../MaspEscrowSatellite.sol";

/// Native-coin bridge for an ERC-20-only MASP. The pool never sees native coin:
/// this adapter wraps on the way in and unwraps on the way out, holding funds
/// only for the duration of a call, plus refunds awaiting collection.
///
/// - `depositNative` — wraps `msg.value`, escrows it via `depositAuthorized`
///   with the adapter as `payer`, then unwraps and returns any excess.
/// - `cancelNative` — drives `MASP.cancelDeposit` for an adapter-owned escrow
///   and forwards the refund as native coin to whoever funded it. The pool
///   restricts contract payers to cancelling their own deposits, so this is the
///   only way an adapter-owned escrow can be settled by refund.
/// - `withdrawNative` — drives `MASP.withdraw` with the adapter as `recipient`,
///   then unwraps and forwards the proceeds to `pi.payer`.
///
/// Every amount is measured as a balance delta across the pool call. The escrow
/// record and the Permit2 and cancel plumbing come from
/// [MaspEscrowSatellite](../MaspEscrowSatellite.sol); the withdraw leg measures
/// inline, as the pool pushes on that path rather than pulling.
///
/// Ownerless and permissionless. All authority comes from the SNARK public
/// inputs (`pi.payer` names the native recipient on the spend side) or from the
/// adapter's own escrow bookkeeping.
contract NativeAdapter is MaspEscrowSatellite {
    IWrappedNative public immutable WRAPPED_NATIVE;

    event NativeDeposited(uint256 indexed id, address indexed refundTo, uint256 escrowed, uint256 returned);
    event NativeRefunded(uint256 indexed id, address indexed refundTo, uint256 amount);
    event NativeWithdrawn(address indexed recipient, uint256 amount);
    /// `recipient` could not take `amount` on the 2300 stipend, so it was paid
    /// without its `receive` running.
    event NativeForceSent(address indexed recipient, uint256 amount);

    error ZeroValue();
    error AdapterNotPayer();
    error AdapterNotRecipient();
    error AdapterNotRelayer();
    error NothingUnshielded();
    error NativeTransferFailed();
    error UnauthorizedNativeSender();
    error PoolNotAContract();

    constructor(IMASPPool pool, IWrappedNative wrappedNative, IAllowanceTransfer permit2)
        MaspEscrowSatellite(pool, permit2)
    {
        if (address(wrappedNative) == address(0)) revert ZeroAddress();
        // `_forwardWithdraw` is a low-level call, which succeeds against no code.
        if (address(pool).code.length == 0) revert PoolNotAContract();
        WRAPPED_NATIVE = wrappedNative;
        _approveToken(WRAPPED_NATIVE);
    }

    /// Only the wrapped-native contract may push raw native coin; every other
    /// inbound path here is an explicit entry point.
    receive() external payable {
        if (msg.sender != address(WRAPPED_NATIVE)) revert UnauthorizedNativeSender();
    }

    /// The funder of an adapter-owned escrow and the amount the pool pulled.
    /// The asset is always wrapped native, so no token is recorded.
    function escrows(uint256 id) external view returns (address refundTo, uint256 amount) {
        Escrow storage e = _escrows[id];
        return (e.refundTo, e.amount);
    }

    /// The adapter holds one immutable token, so no per-escrow token is recorded.
    function _escrowToken(uint256, uint64) internal view override returns (IERC20) {
        return WRAPPED_NATIVE;
    }

    /// Re-arms the wrapped-native approval. Idempotent and permissionless; the
    /// constructor performs it. Needed again only if a non-standard
    /// wrapped-native token decays either allowance.
    function arm() external {
        _approveToken(WRAPPED_NATIVE);
    }

    // -------- deposit ---------------------------------------------------

    /// Wraps `msg.value` and escrows it into MASP. `d.payer` must be this
    /// adapter: the coin arrives with the call, so there is no Permit2 signature
    /// from the sender and the pool pulls against the adapter's own allowance.
    /// `d.recipient` and `d.outCm` still bind the note to the depositor, so the
    /// adapter learns nothing the pool does not.
    ///
    /// `msg.value` above the pool's pull (deposit amount, fee and relayer note
    /// value) is unwrapped and returned, so a caller may overshoot rather than
    /// compute the fee.
    ///
    /// The relayer note is paid in wrapped native or carries no value:
    /// `d.feeAssetId` must be `d.publicAssetId`, or 0 with a zero `feeIn`. The
    /// coin arrives as one token, so there is nothing to fund a note in another
    /// asset with; `_escrowMeasured` reverts `FeeAssetMismatch` otherwise.
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

        // The wrap credits `msg.value` to this contract before the pool pulls,
        // so the pull is measured against the pre-wrap balance plus it.
        // `depositNative` is `nonReentrant`, and both calls below are on the
        // immutable wrapped-native contract rather than caller-supplied code, so
        // the escrow write cannot be observed mid-flight.
        // aderyn-fp-next-line(reentrancy-state-change)
        uint256 baseline = WRAPPED_NATIVE.balanceOf(address(this)) + msg.value;
        // aderyn-fp-next-line(reentrancy-state-change)
        WRAPPED_NATIVE.deposit{ value: msg.value }();

        // The pull is the escrowed total (amount, fee and relayer note value)
        // and must land in `[1, msg.value]`. The floor rejects an empty pull,
        // which is also how a non-wrapped-native asset id measures, since the
        // adapter holds and permits no other token. The ceiling confines the
        // pull to the coin this call supplied, keeping refunds held here for
        // other depositors out of reach of an oversized `d.publicIn`.
        uint256 pulled;
        (id, pulled) = _escrowMeasured(WRAPPED_NATIVE, baseline, 1, msg.value, d, aux, feeAux);

        _escrows[id] = Escrow({ refundTo: msg.sender, amount: uint96(pulled) });

        uint256 returned = msg.value - pulled;
        if (returned != 0) {
            WRAPPED_NATIVE.withdraw(returned);
            _sendNative(msg.sender, returned);
        }
        emit NativeDeposited(id, msg.sender, pulled, returned);
    }

    /// Cancels an adapter-owned escrow past MASP's `cancelDelay` and forwards
    /// the refund as native coin to the address that funded it. Anyone may call;
    /// the destination is the recorded funder, not the caller. The digest
    /// preimage comes from the deposit's `DepositEscrowed` event, less `payer`,
    /// which is always this adapter. `feeNote.feeAssetId` is the event's
    /// `feeAssetId`: the wrapped-native id, or 0 for a zero-value note.
    ///
    /// The refund is attributed by the wrapped-balance delta across the pool
    /// call. MASP refuses a cancel of a contract payer's deposit from any other
    /// sender, so the adapter is necessarily the caller. An already-settled
    /// deposit was flushed and has no refund to forward.
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
        (, address refundTo, uint256 amount) = _cancelAndVerify(
            id, publicIn, cm, cvDep, publicAssetId, fbps, submittedAt, feeNote
        );

        WRAPPED_NATIVE.withdraw(amount);
        _sendNative(refundTo, amount);
        emit NativeRefunded(id, refundTo, amount);
    }

    // -------- withdraw --------------------------------------------------

    /// Unshields to native coin. The proof must name this adapter as both
    /// `recipient` (the pool pushes wrapped coin here) and `relayer` (MASP pins
    /// `relayer == msg.sender`, and the adapter is the caller).
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
        PubInputs.SpendTree calldata tpi,
        AuxValidation.Output[6] calldata aux
    ) external nonReentrant returns (uint256 net) {
        if (pi.recipient != address(this)) revert AdapterNotRecipient();
        if (pi.relayer != address(this)) revert AdapterNotRelayer();

        uint256 balanceBefore = WRAPPED_NATIVE.balanceOf(address(this));
        // Read only by the pool, which decodes the forwarded bytes itself.
        (p, tp, tpi, aux);
        _forwardWithdraw();
        net = WRAPPED_NATIVE.balanceOf(address(this)) - balanceBefore;
        // A zero delta means the spend was denominated in another asset, pushed
        // here as a token this contract cannot return; the revert undoes the
        // unshield. Exact zero is a presence test on a measured delta: any
        // nonzero value is coin this call unshielded.
        // slither-disable-next-line incorrect-equality
        if (net == 0) revert NothingUnshielded();

        WRAPPED_NATIVE.withdraw(net);
        _sendNative(pi.payer, net);
        emit NativeWithdrawn(pi.payer, net);
    }

    /// `POOL.withdraw` with this call's own argument bytes. `withdrawNative`
    /// takes exactly `withdraw`'s arguments, so only the selector differs and
    /// re-encoding them would copy the same bytes.
    function _forwardWithdraw() private {
        address pool = address(POOL);
        bytes4 sel = IMASPPool.withdraw.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            calldatacopy(add(ptr, 4), 4, sub(calldatasize(), 4))
            if iszero(call(gas(), pool, 0, ptr, calldatasize(), 0, 0)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }

    /// Delivers `amount` to `to` without letting `to` change any state or fail
    /// the call.
    ///
    /// `withdrawNative` runs inside relayer bundles, where `to` is a user-chosen
    /// address: forwarding it all gas would let it revert the item, consume the
    /// bundle's gas, or re-enter the pool (whose guard is released once
    /// `withdraw` returns) and move its state under later items. The push
    /// therefore passes no gas beyond the 2300 value stipend, at which every
    /// `SSTORE` fails (EIP-2200). A recipient that needs more is paid by a
    /// contract that self-destructs to it in its constructor, which moves the
    /// balance without running `to`'s code (EIP-6780 preserves that for a
    /// contract created in the same transaction).
    function _sendNative(address to, uint256 amount) private {
        // slither-disable-next-line arbitrary-send-eth,low-level-calls
        (bool ok,) = to.call{ value: amount, gas: 0 }("");
        if (ok) return;
        bool sent;
        assembly ("memory-safe") {
            // Init code `PUSH20 to SELFDESTRUCT`, in scratch space: 0x73 at 0x0b,
            // `to` right-aligned in the first word, 0xff at 0x20.
            mstore(0x00, to)
            mstore8(0x0b, 0x73)
            mstore8(0x20, 0xff)
            sent := iszero(iszero(create(amount, 0x0b, 0x16)))
        }
        // `create` returns zero only when short of gas or past the call-depth
        // limit; either reverts the whole call, and a relayer can retry with a
        // higher gas limit.
        if (!sent) revert NativeTransferFailed();
        emit NativeForceSent(to, amount);
    }
}
