// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Runs the arbitrary calls of one `GenericCallWrapper.execute`, then hands
/// back what they produced.
///
/// The wrapper deploys this once as an implementation and runs every execution
/// in a fresh ERC-1167 clone of it. Both immutables live in the implementation's
/// runtime code, so every clone carries them.
///
/// A clone is used once. Calls may leave approvals behind, on tokens or on
/// Permit2, and a shared executor would carry them into the next user's calls,
/// where a spender reached through a hook or callback could pull that user's
/// slippage cushion. A clone starts with no allowances and is abandoned after
/// its execution. If the execution refunds instead, the clone's creation and
/// everything its calls did are rolled back with it.
///
/// It holds no privilege anywhere: no Permit2 allowance to the pool and no
/// escrow records. The wrapper holds both, which is why it never makes these
/// calls itself.
contract CallExecutor {
    using SafeERC20 for IERC20;

    struct Call {
        address target;
        /// Paid from the clone's own native balance.
        uint256 value;
        bytes data;
    }

    /// Longest revert payload re-raised from a failing call. A longer one is
    /// replaced by `CallFailed`, so a target cannot make the wrapper copy
    /// unbounded return data.
    uint256 internal constant MAX_REASON_BYTES = 1024;

    /// The only permitted caller of `run`, and a denied target.
    address public immutable WRAPPER;
    /// A denied target: the calls have no business with the pool directly.
    address public immutable POOL;

    error OnlyWrapper();
    error TargetNotAllowed(uint256 index, address target);
    error CallFailed(uint256 index);
    error NativeSweepFailed();

    constructor(address wrapper, address pool) {
        WRAPPER = wrapper;
        POOL = pool;
    }

    /// Native coin arrives from calls, such as a wrapped-native unwrap, and is
    /// swept to `nativeTo` at the end of `run`.
    receive() external payable { }

    /// Makes `calls` in order, reverting on the first that fails, then sends
    /// this clone's whole balance of every `tokens` entry to the wrapper and its
    /// whole native balance to `nativeTo`.
    ///
    /// Balances are swept whole rather than checked for leftovers: an address
    /// can be sent tokens or native coin before it holds code, and a leftover
    /// check would let anyone force a refund that way.
    ///
    /// @param calls The intent-bound calls.
    /// @param tokens Every token the wrapper measures: the outputs and the input.
    /// @param nativeTo The intent-bound receiver of native leftovers.
    function run(Call[] calldata calls, address[] calldata tokens, address nativeTo) external {
        if (msg.sender != WRAPPER) revert OnlyWrapper();
        _makeCalls(calls);
        _sweepTokens(tokens);
        _sweepNative(nativeTo);
    }

    function _makeCalls(Call[] calldata calls) private {
        for (uint256 i; i < calls.length; ++i) {
            Call calldata c = calls[i];
            _requireAllowedTarget(i, c);
            if (!_forwardCall(c.target, c.value, c.data)) _revertWithCallReason(i);
        }
    }

    /// Denies the zero address, the pool, the wrapper and this clone. A call
    /// with a payload must reach code, since a call to an account without code
    /// succeeds without doing anything; an empty payload is a plain native
    /// transfer and may go anywhere.
    function _requireAllowedTarget(uint256 index, Call calldata c) private view {
        address target = c.target;
        bool denied = target == address(0) || target == POOL || target == WRAPPER || target == address(this);
        bool inert = c.data.length != 0 && target.code.length == 0;
        if (denied || inert) revert TargetNotAllowed(index, target);
    }

    function _sweepTokens(address[] calldata tokens) private {
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 token = IERC20(tokens[i]);
            uint256 balance = token.balanceOf(address(this));
            if (balance != 0) token.safeTransfer(WRAPPER, balance);
        }
    }

    function _sweepNative(address nativeTo) private {
        uint256 amount = address(this).balance;
        if (amount != 0) {
            bool ok;
            assembly ("memory-safe") {
                ok := call(gas(), nativeTo, amount, 0, 0, 0, 0)
            }
            if (!ok) revert NativeSweepFailed();
        }
    }

    /// A `CALL` with all remaining gas and `data` read straight from calldata.
    /// The payload is copied past the free memory pointer without moving it, so
    /// every call reuses the same region, and no return data is copied.
    function _forwardCall(address target, uint256 value, bytes calldata data) private returns (bool ok) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, data.offset, data.length)
            ok := call(gas(), target, value, ptr, data.length, 0, 0)
        }
    }

    /// Re-raises the last call's revert payload when it is non-empty and fits
    /// `MAX_REASON_BYTES`, otherwise reverts `CallFailed(index)`.
    function _revertWithCallReason(uint256 index) private pure {
        uint256 size;
        assembly ("memory-safe") {
            size := returndatasize()
        }
        if (size == 0 || size > MAX_REASON_BYTES) revert CallFailed(index);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            returndatacopy(ptr, 0, size)
            revert(ptr, size)
        }
    }
}
