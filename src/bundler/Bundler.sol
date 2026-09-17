// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { MASP } from "../MASP.sol";
import { OwnableInit } from "../OwnableInit.sol";
import { NativeAdapter } from "../native/NativeAdapter.sol";
import { SwapWrapper } from "../swap/SwapWrapper.sol";
import { GenericCallWrapper } from "../generic/GenericCallWrapper.sol";

/// What a `Bundler` reads from its deployer during construction.
interface IBundlerDeployer {
    /// Operators of the Bundler being deployed.
    function pendingOperators() external view returns (address[] memory);
}

/// One relayer's submission contract: lands several tree-advancing operations
/// in a single transaction.
///
/// Every tree-advancing call must extend the live tree (`startIndex ==
/// committedCount`, and the old root is `currentRoot()`), so K chained tree
/// updates can only land in order. `execute` makes the K calls in one
/// transaction, each seeing the state the previous one left.
///
/// The calls are plain `CALL`s, so the pool and adapters are unchanged and see
/// the Bundler as `msg.sender`:
///
/// - pool spends bind `pi.relayer = this` (`MASP._validateRequest`);
/// - `withdrawNative` still binds `pi.relayer` to the adapter
///   (`NativeAdapter.withdrawNative`);
/// - swaps bind `pi_w.payer = this` (`SwapWrapper._validate`);
/// - generic calls bind `pi_w.payer = this` (`GenericCallWrapper._validate`);
/// - `flushBatch` is permissionless.
///
/// Each relayer runs its own Bundler (`BundlerFactory`), so a proof bound to one
/// relayer's Bundler reverts through any other's. `execute` is restricted to
/// operators for the same reason: only the relayer that published this address
/// may spend proofs made against it.
///
/// The callable contracts are immutable, each limited to its own entry points.
/// Supporting another adapter takes a new factory.
///
/// Execution stops at the first failing call and keeps the calls before it.
/// Stopping saves gas on the bundles relayers build: those are chained, each
/// call's tree update starting where the previous one ends, so every later call
/// would revert (`BatchMisaligned` for a spend, `StaleOldRoot` for a flush).
/// The Bundler does not check the chaining, and a later call proved on an
/// earlier root is not made either. Keeping the prefix, rather than reverting
/// the whole bundle, stops a market-dependent swap revert, or an item that runs
/// out of gas, from undoing other users' operations.
///
/// Holds no funds and grants no approvals. Nothing here is `payable`, so a
/// stray native transfer reverts.
contract Bundler is OwnableInit, ReentrancyGuardTransient {
    struct Call {
        address target;
        bytes data;
    }

    /// Longest revert payload kept from a failed call. Allowed targets revert
    /// with custom errors; the cap only bounds the copy of an unexpectedly large
    /// payload.
    uint256 internal constant MAX_REASON_BYTES = 1024;

    /// Gas kept back from every call for what `execute` does after one fails:
    /// copying up to `MAX_REASON_BYTES` of reason, the two events and the
    /// return, about 13k at most; the reserve is twice that, rounded up. Without
    /// it a call that runs out of gas leaves only EIP-150's 1/64, too little to
    /// finish at a low gas limit, and the revert would undo the calls before it.
    uint256 internal constant CALL_GAS_RESERVE = 30_000;

    /// Bound on every calldata offset and length `_decode` reads, well above any
    /// real calldata size, so the sums it checks cannot overflow and each
    /// position and length fits the 48 bits `_decode` packs it into.
    uint256 private constant MAX_CALLDATA_POS = 0xffffffffffff;

    /// `transfer`, `withdraw` and `flushBatch` only.
    address public immutable POOL;
    /// `withdrawNative` only; zero on a chain without the adapter.
    address public immutable NATIVE_ADAPTER;
    /// `swap` only; zero on a chain without the wrapper.
    address public immutable SWAP_WRAPPER;
    /// `execute` only; zero on a chain without the wrapper.
    address public immutable GENERIC_CALL_WRAPPER;

    mapping(address => bool) public isOperator;

    event OperatorSet(address indexed operator, bool enabled);
    event BundleExecuted(uint256 executed, uint256 total);
    event BundleItemFailed(uint256 indexed index, bytes reason);

    error NotOperator(address caller);
    error CallNotAllowed(uint256 index);
    /// `calls[index]` is not a well-formed ABI `Call` inside the calldata.
    error MalformedCall(uint256 index);
    error EmptyBundle();
    error ZeroAddress();
    /// Never raised; the `reason` of a call that ran out of gas (see `_call`).
    error ItemOutOfGas();

    /// Deployed by `BundlerFactory.create`, which supplies the operators through
    /// `pendingOperators` so they stay out of the address.
    constructor(address owner_, address pool, address nativeAdapter, address swapWrapper, address genericCallWrapper) {
        if (pool == address(0)) revert ZeroAddress();
        _initOwner(owner_);
        POOL = pool;
        NATIVE_ADAPTER = nativeAdapter;
        SWAP_WRAPPER = swapWrapper;
        GENERIC_CALL_WRAPPER = genericCallWrapper;
        address[] memory operators = IBundlerDeployer(msg.sender).pendingOperators();
        for (uint256 i; i < operators.length; ++i) {
            _setOperator(operators[i], true);
        }
    }

    // ============== Admin ====================================================

    /// Rotates signing keys without moving the Bundler's address, which is what
    /// in-flight proofs are bound to.
    function setOperator(address operator, bool enabled) external onlyOwner {
        _setOperator(operator, enabled);
    }

    function _setOperator(address operator, bool enabled) private {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = enabled;
        emit OperatorSet(operator, enabled);
    }

    // ============== Execution ================================================

    /// Calls each entry in order, stopping at the first that reverts. Every entry
    /// is checked before any is called, so a malformed bundle reverts whole
    /// rather than landing a prefix.
    ///
    /// @return executed Number of calls that succeeded; `calls.length` unless one
    ///         failed.
    /// @return reason The failing call's revert payload, truncated to
    ///         `MAX_REASON_BYTES`, or `ItemOutOfGas` if it ran out of gas; empty
    ///         when every call succeeded.
    function execute(Call[] calldata calls) external nonReentrant returns (uint256 executed, bytes memory reason) {
        if (!isOperator[msg.sender]) revert NotOperator(msg.sender);
        uint256 n = calls.length;
        if (n == 0) revert EmptyBundle();
        uint256[] memory items = _decode(calls);

        for (; executed < n; ++executed) {
            (bool ok, bool outOfGas) = _call(items[executed]);
            if (!ok) {
                reason = outOfGas ? abi.encodeWithSelector(ItemOutOfGas.selector) : _revertReason();
                emit BundleItemFailed(executed, reason);
                break;
            }
        }
        emit BundleExecuted(executed, n);
    }

    /// Reads every `calls[i]` once, straight from calldata, into one packed word:
    /// target in the low 160 bits, then the payload's calldata position and
    /// length in 48 bits each. Reverts `MalformedCall` unless the element head
    /// and the payload lie inside the calldata, and `CallNotAllowed` unless the
    /// payload holds a selector its target admits.
    ///
    /// The array's own offset and length are checked by the ABI decoder on entry,
    /// so the head slot of every element is in bounds; everything it points at is
    /// checked here.
    function _decode(Call[] calldata calls) private view returns (uint256[] memory items) {
        uint256 n = calls.length;
        items = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            bool bad;
            address target;
            uint256 data;
            uint256 len;
            bytes4 selector;
            assembly ("memory-safe") {
                let base := calls.offset
                let end := calldatasize()
                // Offsets are relative to the array's first head slot, and the
                // payload's to its element.
                let rel := calldataload(add(base, shl(5, i)))
                let elem := add(base, rel)
                let t := calldataload(elem)
                let dataRel := calldataload(add(elem, 0x20))
                let lenPos := add(elem, dataRel)
                len := calldataload(lenPos)
                data := add(lenPos, 0x20)
                bad := or(
                    or(gt(rel, MAX_CALLDATA_POS), gt(add(elem, 0x40), end)),
                    or(
                        or(gt(dataRel, MAX_CALLDATA_POS), gt(data, end)),
                        or(gt(len, MAX_CALLDATA_POS), or(gt(add(data, len), end), shr(160, t)))
                    )
                )
                target := t
                selector := shl(224, shr(224, calldataload(data)))
            }
            if (bad) revert MalformedCall(i);
            if (len < 4 || !_allowed(target, selector)) revert CallNotAllowed(i);
            items[i] = uint256(uint160(target)) | (data << 160) | (len << 208);
        }
    }

    /// Each target admits only its own tree-advancing entry points. The selector
    /// check keeps an operator from using the Bundler's address for anything
    /// else, such as a token transfer or a cancel.
    function _allowed(address target, bytes4 selector) private view returns (bool) {
        if (target == address(0)) return false;
        if (target == POOL) {
            return selector == MASP.transfer.selector || selector == MASP.withdraw.selector
                || selector == MASP.flushBatch.selector;
        }
        if (target == NATIVE_ADAPTER) return selector == NativeAdapter.withdrawNative.selector;
        if (target == SWAP_WRAPPER) return selector == SwapWrapper.swap.selector;
        if (target == GENERIC_CALL_WRAPPER) return selector == GenericCallWrapper.execute.selector;
        return false;
    }

    /// Calls a `_decode` item with no value and all gas but `CALL_GAS_RESERVE`,
    /// and ignores return data. Makes no call if the reserve is all that is left.
    ///
    /// A failed call counts as out of gas when it used at least 31/32 of what it
    /// was given. The slack covers the 1/64 each nested frame keeps back and
    /// returns when it runs dry. A revert that happens to spend as much is
    /// reported the same way: the signal says a higher limit is worth a try, not
    /// that one would succeed.
    ///
    /// The payload is copied past the free memory pointer without moving it, so
    /// every call reuses the same region. Allocating each payload would instead
    /// grow memory by their sum, and memory cost is quadratic in its size.
    function _call(uint256 item) private returns (bool ok, bool outOfGas) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let len := shr(208, item)
            calldatacopy(ptr, and(shr(160, item), MAX_CALLDATA_POS), len)
            let g := gas()
            // What the callee gets: all but the reserve, or EIP-150's all but
            // 1/64 where that is less.
            let budget := 0
            if gt(g, CALL_GAS_RESERVE) {
                budget := sub(g, CALL_GAS_RESERVE)
                let cap := sub(g, div(g, 64))
                if gt(budget, cap) { budget := cap }
                ok := call(budget, and(item, 0xffffffffffffffffffffffffffffffffffffffff), 0, ptr, len, 0, 0)
            }
            if iszero(ok) { outOfGas := iszero(lt(sub(g, gas()), sub(budget, shr(5, budget)))) }
        }
    }

    /// The last call's return data, capped at `MAX_REASON_BYTES`.
    function _revertReason() private pure returns (bytes memory reason) {
        uint256 size;
        assembly ("memory-safe") {
            size := returndatasize()
        }
        if (size > MAX_REASON_BYTES) size = MAX_REASON_BYTES;
        reason = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(reason, 0x20), 0, size)
        }
    }
}
