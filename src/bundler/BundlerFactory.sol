// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Bundler, IBundlerDeployer } from "./Bundler.sol";

/// Permissionless factory for per-relayer `Bundler`s.
///
/// Anyone may run a relayer, so anyone may create a Bundler. The creator owns
/// it, and its address is a function of the creator alone, so a relayer can
/// publish its Bundler address before deploying it.
///
/// The owner is `msg.sender` rather than an argument. Were it an argument, a
/// third party could watch a relayer advertise its predicted address and create
/// that Bundler first with operators of its own choosing. Owner and salt both
/// come from the caller, so a Bundler at a given address can only be created by
/// the account it belongs to.
///
/// The contracts a Bundler may call are fixed here, for every Bundler this
/// factory creates. Supporting another adapter takes a new factory, and each
/// relayer a new Bundler from it.
contract BundlerFactory is IBundlerDeployer {
    address public immutable POOL;
    /// Zero on a chain without the adapter.
    address public immutable NATIVE_ADAPTER;
    /// Zero on a chain without the wrapper.
    address public immutable SWAP_WRAPPER;

    /// Transient slot of the operator list `create` hands its Bundler: the
    /// length, then one address per following slot.
    uint256 private constant PENDING_OPERATORS_SLOT = uint256(keccak256("lelantos.BundlerFactory.pendingOperators"));

    event BundlerCreated(address indexed owner, address indexed bundler);

    error AlreadyCreated(address owner, address bundler);
    error ZeroAddress();
    error NotAContract(address target);

    constructor(address pool, address nativeAdapter, address swapWrapper) {
        if (pool == address(0)) revert ZeroAddress();
        _requireCode(pool);
        _requireCode(nativeAdapter);
        _requireCode(swapWrapper);
        POOL = pool;
        NATIVE_ADAPTER = nativeAdapter;
        SWAP_WRAPPER = swapWrapper;
    }

    /// Deploys the caller's Bundler. Reverts if the caller already has one.
    ///
    /// @param operators Keys allowed to call `execute`; the owner may change them.
    function create(address[] calldata operators) external returns (Bundler bundler) {
        // Checked up front: a CREATE2 collision consumes all the gas it is given
        // before failing, so a repeated `create` would otherwise consume the
        // whole transaction's gas limit.
        address existing = predict(msg.sender);
        if (existing.code.length != 0) revert AlreadyCreated(msg.sender, existing);

        uint256 slot = PENDING_OPERATORS_SLOT;
        uint256 n = operators.length;
        for (uint256 i; i < n; ++i) {
            address operator = operators[i];
            assembly ("memory-safe") {
                tstore(add(slot, add(i, 1)), operator)
            }
        }
        assembly ("memory-safe") {
            tstore(slot, n)
        }
        bundler = new Bundler{ salt: _salt(msg.sender) }(msg.sender, POOL, NATIVE_ADAPTER, SWAP_WRAPPER);
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
        emit BundlerCreated(msg.sender, address(bundler));
    }

    /// The operators of the Bundler `create` is deploying; empty outside it.
    function pendingOperators() external view returns (address[] memory operators) {
        uint256 slot = PENDING_OPERATORS_SLOT;
        uint256 n;
        assembly ("memory-safe") {
            n := tload(slot)
        }
        operators = new address[](n);
        for (uint256 i; i < n; ++i) {
            address operator;
            assembly ("memory-safe") {
                operator := tload(add(slot, add(i, 1)))
            }
            operators[i] = operator;
        }
    }

    /// The address `owner_`'s Bundler has, or will have once created: CREATE2
    /// over `Bundler`'s creation code and its constructor arguments.
    function predict(address owner_) public view returns (address) {
        bytes32 initCodeHash = keccak256(
            // No collision: the creation code is a compile-time constant, so the
            // boundary between it and the encoded arguments cannot shift.
            // aderyn-fp-next-line(abi-encode-packed-hash-collision)
            abi.encodePacked(type(Bundler).creationCode, abi.encode(owner_, POOL, NATIVE_ADAPTER, SWAP_WRAPPER))
        );
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(owner_), initCodeHash))))
        );
    }

    /// Zero passes: an adapter the chain lacks.
    function _requireCode(address a) private view {
        if (a != address(0) && a.code.length == 0) revert NotAContract(a);
    }

    function _salt(address owner_) private pure returns (bytes32) {
        return bytes32(uint256(uint160(owner_)));
    }
}
