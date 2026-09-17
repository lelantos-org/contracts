// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { PubInputs } from "../libs/PubInputs.sol";
import { SnarkCompression } from "../SnarkCompression.sol";
import { AuxValidation } from "../libs/AuxValidation.sol";

import { IMASPPool } from "../interfaces/IMASPPool.sol";
import { MaspEscrowSatellite } from "../MaspEscrowSatellite.sol";
import { CallExecutor } from "./CallExecutor.sol";

/// Atomic shielded execution of arbitrary calls, in three legs:
///   1. Unshield: `MASP.withdraw` sends one asset to this wrapper.
///   2. Call: a fresh `CallExecutor` clone receives it, makes the calls, and
///      returns every measured token.
///   3. Re-shield: each output is escrowed back through `MASP.depositAuthorized`.
///
/// The generic counterpart of `SwapWrapper`: calldata the wallet builds replaces
/// the allowlisted adapter, so an integration needs no contract and no
/// governance action. The calls, outputs, floors, refund, deadline, gas floor and
/// receivers are hashed into `pi_w.intentHash`, so whoever submits cannot change
/// any of them.
///
/// If leg 2 fails (a call reverts, an output misses its floor, the deadline has
/// passed), it unwinds and the input is escrowed back as `refund_d` instead.
///
/// Ownerless. It holds the Permit2 allowance to the pool and the escrow records,
/// which is why the calls never run from here. What stays public is what any
/// unshield exposes: the calls, the amounts and `surplusTo`.
contract GenericCallWrapper is MaspEscrowSatellite {
    using SafeERC20 for IERC20;

    // =====================================================================
    // Constants and types
    // =====================================================================

    /// Outputs per execution. Each costs one escrow, two leaves and a Permit2 pull.
    uint256 public constant MAX_OUTPUTS = 4;
    /// Calls per execution. Bounds the intent preimage hashed on every execution.
    uint256 public constant MAX_CALLS = 16;

    /// Gas held back from the call leg so that a failed one can still be
    /// refunded: the refund escrow, the balance checks and the event.
    uint256 internal constant REFUND_GAS_RESERVE = 450_000;

    /// The implementation every execution clones.
    address public immutable EXECUTOR_IMPL;

    /// One shielded output: a note of the registry token of `deposit.publicAssetId`.
    struct Output {
        /// Floor on what the calls deliver in the output token, and on the
        /// pool's pull for `deposit`.
        uint256 minOut;
        PubInputs.DepositRequest deposit;
        AuxValidation.Output aux;
        AuxValidation.Output feeAux;
    }

    struct GenericArgs {
        /// Floor on what leg 1 delivers, net of the unshield fee. Not part of
        /// the intent: the withdraw proof itself fixes the amount.
        uint256 amountIn;
        CallExecutor.Call[] calls;
        Output[] outputs;
        /// Expiry in unix seconds. Past it the call leg refunds.
        uint256 deadline;
        /// Gas the call leg must be forwarded. Below it `execute` reverts, so a
        /// submitter cannot pick a gas limit that forces a refund.
        uint256 minGas;
        /// Receives a cancelled escrow's refund.
        address refundTo;
        /// Receives slippage cushions, unused input and native leftovers.
        address surplusTo;
        // --- leg 1: the withdraw proof ---
        IMASPPool.Proof p_w;
        PubInputs.Transact pi_w;
        IMASPPool.Proof tp_w;
        PubInputs.SpendTree tpi_w;
        AuxValidation.Output[6] aux_w;
        // --- the refund note, escrowed if leg 2 fails ---
        PubInputs.DepositRequest refund_d;
        AuxValidation.Output refund_aux_d;
        AuxValidation.Output refund_fee_aux_d;
    }

    /// The arguments of `callLeg` besides the calls, which are forwarded straight
    /// from calldata rather than copied into this struct.
    struct CallLeg {
        address tokenIn;
        uint256 amountIn;
        /// Every measured token: see `_measuredTokens`.
        address[] tokens;
        /// This contract's balance of each `tokens` entry before leg 1. It is
        /// also the balance once the input has left for the clone, since leg 1
        /// delivered exactly what the clone was sent; the closing balance check
        /// enforces that.
        uint256[] baseline;
        /// One floor per output, aligned with the head of `tokens`.
        uint256[] minOuts;
        uint256 deadline;
        address nativeTo;
    }

    // =====================================================================
    // Events and errors
    // =====================================================================

    event TokenPrepared(address indexed token);
    /// The calls landed. `returned[i]` is what came back of `tokens[i]` (see
    /// `_measuredTokens`), outputs first.
    event CallsExecuted(
        address indexed executor, address indexed tokenIn, uint256 received, uint256[] depositIds, uint256[] returned
    );
    /// The call leg failed and the input was escrowed back. `reason` is the
    /// failure's selector, zero when it carried none.
    event CallsRefunded(address indexed tokenIn, uint256 received, uint256 surplus, uint256 depositId, bytes4 reason);
    event EscrowRefunded(uint256 indexed depositId, address indexed refundTo, address token, uint256 amount);

    // --- shape ---
    error AmountInZero();
    error BadOutputCount();
    error TooManyCalls();
    error MinOutZero(uint256 index);
    // --- bindings ---
    error UnauthorizedCaller(address caller, address authorized);
    error WrapperNotRecipient();
    error WrapperNotRelayer();
    error WrapperNotPayer();
    error InvalidRefundTo();
    error InvalidSurplusTo();
    error IntentMismatch();
    // --- tokens ---
    /// The refund note is not denominated in the token leg 1 delivers.
    error TokenInMismatch();
    error DuplicateOutputToken(address token);
    error YieldAssetNotSupported(uint64 assetId);
    // --- execution ---
    error InsufficientWithdraw(uint256 received, uint256 amountIn);
    error InsufficientGas(uint256 forwarded, uint256 minGas);
    error CallLegOutOfGas();
    error OnlySelf();
    error Expired();
    error InsufficientOut(uint256 index, uint256 delivered, uint256 minOut);
    error LeftoverBalance(address token, uint256 drift);

    constructor(IMASPPool pool, IAllowanceTransfer permit2) MaspEscrowSatellite(pool, permit2) {
        EXECUTOR_IMPL = address(new CallExecutor(address(this), address(pool)));
    }

    // =====================================================================
    // Execution
    // =====================================================================

    /// Unshields, runs the calls and re-shields the outputs, or refunds the
    /// input if the calls fail. Reverts only on what is fixed before sending
    /// (validation, leg 1, the gas floor, an escrow) or on a call leg that
    /// exhausts its gas.
    ///
    /// Every amount is a balance delta across an external call. That is sound
    /// because re-entry is blocked here and on MASP, the calls run in a clone
    /// with no access to this contract's balances, and every measured balance
    /// must end where it started.
    ///
    /// @return depositIds The output escrows, or the single refund escrow.
    // slither-disable-next-line reentrancy-balance
    function execute(GenericArgs calldata a) external nonReentrant returns (uint256[] memory depositIds) {
        (address tokenIn, address[] memory tokens) = _validate(a);
        uint256[] memory snapshot = _balancesOf(tokens);

        uint256 received = _unshield(a, tokenIn, snapshot[_indexOf(tokens, tokenIn)]);
        (bool landed, address executor, uint256[] memory returned, bytes4 reason) =
            _tryCallLeg(a, tokenIn, tokens, snapshot, received);

        depositIds = landed
            ? _settleOutputs(a, tokenIn, tokens, received, executor, returned)
            : _settleRefund(a, tokenIn, received, reason);

        _requireBalancesUnchanged(tokens, snapshot);
    }

    /// Leg 2, in a frame of its own so that a failure unwinds with the input
    /// still here and no clone created. Callable only from `execute`.
    ///
    /// @return executor The clone the calls ran in.
    /// @return returned What came back of each `leg.tokens` entry.
    function callLeg(CallExecutor.Call[] calldata calls, CallLeg calldata leg)
        external
        returns (address executor, uint256[] memory returned)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        if (block.timestamp > leg.deadline) revert Expired();

        executor = Clones.clone(EXECUTOR_IMPL);
        IERC20(leg.tokenIn).safeTransfer(executor, leg.amountIn);

        address[] memory tokens = leg.tokens;
        CallExecutor(payable(executor)).run(calls, tokens, leg.nativeTo);

        returned = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            returned[i] = IERC20(tokens[i]).balanceOf(address(this)) - leg.baseline[i];
        }
        for (uint256 i; i < leg.minOuts.length; ++i) {
            if (returned[i] < leg.minOuts[i]) revert InsufficientOut(i, returned[i], leg.minOuts[i]);
        }
    }

    /// The value the withdraw proof must carry as `pi_w.intentHash`: the
    /// keccak of every field the proof does not already fix, reduced into the
    /// BN254 scalar field.
    function intentHash(GenericArgs calldata a) public pure returns (uint256) {
        bytes32 digest = keccak256(
            abi.encode(
                a.refundTo,
                a.surplusTo,
                a.deadline,
                a.minGas,
                a.calls,
                a.outputs,
                a.refund_d,
                a.refund_aux_d,
                a.refund_fee_aux_d
            )
        );
        return uint256(digest) % SnarkCompression.R;
    }

    // =====================================================================
    // Escrow management
    // =====================================================================

    /// Arms a token for escrow into MASP. Required once per token before any
    /// execution escrows into it; idempotent.
    function prepareToken(IERC20 token) external {
        _approveToken(token);
        emit TokenPrepared(address(token));
    }

    /// Cancels an escrow this wrapper created and pays the refund to its recorded
    /// `refundTo`. Anyone may call. The preimage comes from the deposit's
    /// `DepositEscrowed` event; see `SwapWrapper.cancelEscrow`.
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

    function escrows(uint256 depositId) external view returns (address refundTo, uint256 amount) {
        Escrow storage e = _escrows[depositId];
        return (e.refundTo, e.amount);
    }

    /// The registry token of `publicAssetId`, which `cancelDeposit` checks
    /// against the escrow digest in the same call.
    function _escrowToken(uint256, uint64 publicAssetId) internal view override returns (IERC20) {
        return IERC20(_registryToken(publicAssetId));
    }

    // =====================================================================
    // Validation
    // =====================================================================

    /// Checks everything `execute` binds before any external call that moves
    /// funds, and derives the measured tokens from the registry.
    function _validate(GenericArgs calldata a) private view returns (address tokenIn, address[] memory tokens) {
        _validateShape(a);
        _validateBindings(a);
        tokenIn = _registryToken(a.pi_w.publicAssetId);
        tokens = _measuredTokens(a, tokenIn);
        // Checked last, so a malformed field reports its own error.
        if (a.pi_w.intentHash != intentHash(a)) revert IntentMismatch();
    }

    function _validateShape(GenericArgs calldata a) private pure {
        if (a.amountIn == 0) revert AmountInZero();
        if (a.outputs.length == 0 || a.outputs.length > MAX_OUTPUTS) revert BadOutputCount();
        if (a.calls.length > MAX_CALLS) revert TooManyCalls();
        for (uint256 i; i < a.outputs.length; ++i) {
            if (a.outputs[i].minOut == 0) revert MinOutZero(i);
        }
    }

    /// Binds the funds to this wrapper and the proof to its submitter.
    function _validateBindings(GenericArgs calldata a) private view {
        // `execute` is permissionless, so without this a withdraw proof lifted
        // from the mempool could be landed by anyone.
        if (msg.sender != a.pi_w.payer) revert UnauthorizedCaller(msg.sender, a.pi_w.payer);
        if (a.pi_w.recipient != address(this)) revert WrapperNotRecipient();
        // Duplicates MASP's own check, to fail earlier with a named error.
        if (a.pi_w.relayer != address(this)) revert WrapperNotRelayer();
        // Every escrow is pulled against this wrapper's Permit2 allowance.
        if (a.refund_d.payer != address(this)) revert WrapperNotPayer();
        for (uint256 i; i < a.outputs.length; ++i) {
            if (a.outputs[i].deposit.payer != address(this)) revert WrapperNotPayer();
        }
        if (a.refundTo == address(0) || a.refundTo == address(this)) revert InvalidRefundTo();
        if (a.surplusTo == address(0) || a.surplusTo == address(this)) revert InvalidSurplusTo();
    }

    /// The tokens an execution measures: each output's token in output order,
    /// then `tokenIn` unless it is itself an output.
    ///
    /// Every one comes from the registry, never from calldata: a token with a
    /// scripted `balanceOf` would pass every bound while the pool pulls a real
    /// token held here. Outputs must be distinct by address, since two asset ids
    /// may share a token and one balance cannot be counted twice.
    function _measuredTokens(GenericArgs calldata a, address tokenIn) private view returns (address[] memory tokens) {
        // The refund usually names the withdrawn asset itself, whose token is
        // `tokenIn` by definition; only another id needs a registry read.
        uint64 refundAsset = a.refund_d.publicAssetId;
        if (refundAsset != a.pi_w.publicAssetId && _registryToken(refundAsset) != tokenIn) revert TokenInMismatch();
        _requireNotYield(refundAsset);

        uint256 n = a.outputs.length;
        address[] memory outputTokens = new address[](n);
        bool inputIsOutput = false;
        for (uint256 i; i < n; ++i) {
            uint64 assetId = a.outputs[i].deposit.publicAssetId;
            _requireNotYield(assetId);
            address token = _registryToken(assetId);
            for (uint256 j; j < i; ++j) {
                if (outputTokens[j] == token) revert DuplicateOutputToken(token);
            }
            outputTokens[i] = token;
            if (token == tokenIn) inputIsOutput = true;
        }
        if (inputIsOutput) return outputTokens;

        tokens = new address[](n + 1);
        for (uint256 i; i < n; ++i) {
            tokens[i] = outputTokens[i];
        }
        tokens[n] = tokenIn;
    }

    /// Yield-asset escrows are refused until the pool settles a cancelled yield
    /// escrow at its submit-time value: until then an escrow made unflushable
    /// earns the venue index fee-free for as long as it stays.
    function _requireNotYield(uint64 assetId) private view {
        if (POOL.isYieldAsset(assetId)) revert YieldAssetNotSupported(assetId);
    }

    function _registryToken(uint64 assetId) private view returns (address) {
        return POOL.asset(assetId).token;
    }

    // =====================================================================
    // Legs
    // =====================================================================

    /// Leg 1. The receipt is a balance delta from `before`, as MASP nets its fee.
    function _unshield(GenericArgs calldata a, address tokenIn, uint256 before) private returns (uint256 received) {
        POOL.withdraw(a.p_w, a.pi_w, a.tp_w, a.tpi_w, a.aux_w);
        received = IERC20(tokenIn).balanceOf(address(this)) - before;
        if (received < a.amountIn) revert InsufficientWithdraw(received, a.amountIn);
    }

    /// Runs `callLeg` and reports a failure instead of propagating it, unless the
    /// leg used at least 7/8 of its gas: that reads as a gas limit too low, and
    /// refunding would settle an execution more gas would have completed. The
    /// 1/8 slack covers the 1/64 each nested frame keeps back; see
    /// `SwapWrapper._tryVenueLeg`.
    function _tryCallLeg(
        GenericArgs calldata a,
        address tokenIn,
        address[] memory tokens,
        uint256[] memory baseline,
        uint256 amountIn
    ) private returns (bool landed, address executor, uint256[] memory returned, bytes4 reason) {
        CallLeg memory leg = CallLeg({
            tokenIn: tokenIn,
            amountIn: amountIn,
            tokens: tokens,
            baseline: baseline,
            minOuts: _minOuts(a),
            deadline: a.deadline,
            nativeTo: a.surplusTo
        });

        uint256 gasBefore = gasleft();
        uint256 budget = _callLegBudget(gasBefore, a.minGas);
        try this.callLeg{ gas: budget }(a.calls, leg) returns (address executor_, uint256[] memory returned_) {
            return (true, executor_, returned_, bytes4(0));
        } catch {
            if (gasBefore - gasleft() >= budget - budget / 8) revert CallLegOutOfGas();
            reason = _lastRevertSelector();
        }
    }

    /// The gas the call leg is forwarded: all but `REFUND_GAS_RESERVE`, or
    /// EIP-150's all but 1/64 where that is less. `minGas` is checked against
    /// that figure, so a very high gas limit cannot pass the check yet forward
    /// less.
    function _callLegBudget(uint256 available, uint256 minGas) private pure returns (uint256 budget) {
        if (available <= REFUND_GAS_RESERVE) revert InsufficientGas(0, minGas);
        budget = available - REFUND_GAS_RESERVE;
        uint256 cap = available - available / 64;
        if (budget > cap) budget = cap;
        if (budget < minGas) revert InsufficientGas(budget, minGas);
    }

    /// Leg 3 after a landed call leg: escrows each output within
    /// `[minOut, delivered]` and sends unused input to `surplusTo`.
    function _settleOutputs(
        GenericArgs calldata a,
        address tokenIn,
        address[] memory tokens,
        uint256 received,
        address executor,
        uint256[] memory returned
    ) private returns (uint256[] memory depositIds) {
        uint256 n = a.outputs.length;
        depositIds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            Output calldata o = a.outputs[i];
            (depositIds[i],) = _escrowAndSettle(a, IERC20(tokens[i]), o.minOut, returned[i], o.deposit, o.aux, o.feeAux);
        }
        // Present only when the input token is not itself an output.
        if (tokens.length > n && returned[n] != 0) IERC20(tokenIn).safeTransfer(a.surplusTo, returned[n]);
        emit CallsExecuted(executor, tokenIn, received, depositIds, returned);
    }

    /// Leg 3 after a failed call leg: escrows the input back as `refund_d`.
    function _settleRefund(GenericArgs calldata a, address tokenIn, uint256 received, bytes4 reason)
        private
        returns (uint256[] memory depositIds)
    {
        depositIds = new uint256[](1);
        uint256 surplus;
        (depositIds[0], surplus) =
            _escrowAndSettle(a, IERC20(tokenIn), 1, received, a.refund_d, a.refund_aux_d, a.refund_fee_aux_d);
        emit CallsRefunded(tokenIn, received, surplus, depositIds[0], reason);
    }

    /// Escrows `d` in `token` with the pull bounded to `[minPull, available]`,
    /// records the escrow for `refundTo`, and sends the rest of `available` to
    /// `surplusTo`.
    // slither-disable-next-line reentrancy-balance
    function _escrowAndSettle(
        GenericArgs calldata a,
        IERC20 token,
        uint256 minPull,
        uint256 available,
        PubInputs.DepositRequest calldata d,
        AuxValidation.Output calldata aux,
        AuxValidation.Output calldata feeAux
    ) private returns (uint256 depositId, uint256 surplus) {
        uint256 pulled;
        (depositId, pulled) = _escrowMeasured(token, token.balanceOf(address(this)), minPull, available, d, aux, feeAux);
        _escrows[depositId] = Escrow({ refundTo: a.refundTo, amount: uint96(pulled) });
        surplus = available - pulled;
        if (surplus != 0) token.safeTransfer(a.surplusTo, surplus);
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _minOuts(GenericArgs calldata a) private pure returns (uint256[] memory minOuts) {
        minOuts = new uint256[](a.outputs.length);
        for (uint256 i; i < minOuts.length; ++i) {
            minOuts[i] = a.outputs[i].minOut;
        }
    }

    function _indexOf(address[] memory tokens, address token) private pure returns (uint256 i) {
        while (tokens[i] != token) ++i;
    }

    function _balancesOf(address[] memory tokens) private view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    /// Donation-tolerant leftover check: every measured balance is back at its
    /// snapshot, so nothing this execution moved stayed here or went missing.
    function _requireBalancesUnchanged(address[] memory tokens, uint256[] memory snapshot) private view {
        uint256[] memory current = _balancesOf(tokens);
        for (uint256 i; i < tokens.length; ++i) {
            if (current[i] != snapshot[i]) {
                uint256 drift = current[i] > snapshot[i] ? current[i] - snapshot[i] : snapshot[i] - current[i];
                revert LeftoverBalance(tokens[i], drift);
            }
        }
    }

    /// The selector of the last call's revert payload, zero if it had none.
    function _lastRevertSelector() private pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            if gt(returndatasize(), 3) {
                returndatacopy(0x00, 0, 4)
                selector := shl(224, shr(224, mload(0x00)))
            }
        }
    }
}
