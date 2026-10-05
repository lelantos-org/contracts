// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import { OwnableInit } from "../OwnableInit.sol";
import { HandleBlob } from "./HandleBlob.sol";

/// Handles: a short label mapped to one text value, the holder's shielded
/// address.
///
/// Registration is first come, first served, and open to any caller. It is
/// meant to be reached through `GenericCallWrapper`, where `msg.sender` is a
/// single-use clone: the registrant is therefore not an account, and a handle
/// is controlled by `controller`, the address of a key its holder keeps. Only a
/// signature by that key changes the value; the owner has no power over a
/// registered handle.
///
/// The value is opaque here: bounded and printable, never parsed. Readers
/// validate it.
///
/// A handle takes one storage slot. Its controller and value are the code of a
/// `HandleBlob`, which costs about a third of what the same bytes cost in
/// storage; changing the value deploys a new blob.
///
/// This contract knows nothing about ENS. A `LelantosNameResolver` per parent
/// name serves these records as that parent's subnames.
contract LelantosNameRegistrar is OwnableInit, EIP712 {
    using SafeERC20 for IERC20;

    // =====================================================================
    // Constants and types
    // =====================================================================

    uint256 public constant MIN_LABEL_LENGTH = 3;
    uint256 public constant MAX_LABEL_LENGTH = 32;
    uint256 public constant MAX_VALUE_LENGTH = 1024;

    bytes32 public constant SET_VALUE_TYPEHASH =
        keccak256("SetValue(string label,string value,uint256 nonce,uint256 deadline)");

    /// A registered handle, in one slot. `blob` is never zero for one, so it
    /// doubles as the existence flag.
    struct Record {
        /// The `HandleBlob` holding the controller and the current value.
        address blob;
        /// Count of `setValue` calls, bound into the next one's signature.
        uint64 nonce;
    }

    mapping(bytes32 labelHash => Record) private _records;

    /// The token and amount `register` pulls from its caller. Zero amount
    /// charges nothing.
    IERC20 public feeToken;
    uint96 public feeAmount;
    /// Receives the fee directly; this contract never holds it.
    address public treasury;

    // =====================================================================
    // Events and errors
    // =====================================================================

    event HandleRegistered(bytes32 indexed labelHash, address indexed controller, string label);
    event ValueChanged(bytes32 indexed labelHash, string value);
    event FeeSet(IERC20 indexed token, uint96 amount, address indexed treasury);

    error InvalidLabel();
    error InvalidValue();
    error InvalidController();
    error LabelTaken();
    error UnknownLabel();
    error SignatureExpired();
    error InvalidSigner();
    error InvalidFee();

    /// @param reservedLabels Registered here, with an empty value, to
    /// `reservedController`. Seeded in the constructor because nothing can take
    /// a handle back once the contract is live.
    constructor(
        address owner_,
        IERC20 feeToken_,
        uint96 feeAmount_,
        address treasury_,
        string[] memory reservedLabels,
        address reservedController
    ) EIP712("LelantosNameRegistrar", "1") {
        _initOwner(owner_);
        _setFee(feeToken_, feeAmount_, treasury_);
        if (reservedLabels.length != 0 && reservedController == address(0)) revert InvalidController();
        for (uint256 i; i < reservedLabels.length; ++i) {
            string memory label = reservedLabels[i];
            if (!_isValidLabel(bytes(label))) revert InvalidLabel();
            bytes32 labelHash = keccak256(bytes(label));
            if (_records[labelHash].blob != address(0)) revert LabelTaken();
            _records[labelHash].blob = HandleBlob.writeEmpty(reservedController);
            emit HandleRegistered(labelHash, reservedController, label);
        }
    }

    // =====================================================================
    // Registration
    // =====================================================================

    /// Registers `label` with `value`, controlled by `controller`. Pulls the
    /// fee from the caller when one is set.
    function register(string calldata label, string calldata value, address controller) external {
        if (!_isValidLabel(bytes(label))) revert InvalidLabel();
        if (bytes(value).length == 0 || !_isValidValue(value)) revert InvalidValue();
        if (controller == address(0)) revert InvalidController();

        bytes32 labelHash = keccak256(bytes(label));
        Record storage r = _records[labelHash];
        if (r.blob != address(0)) revert LabelTaken();
        r.blob = HandleBlob.write(controller, value);

        emit HandleRegistered(labelHash, controller, label);
        emit ValueChanged(labelHash, value);

        uint256 amount = feeAmount;
        if (amount != 0) feeToken.safeTransferFrom(msg.sender, treasury, amount);
    }

    /// Replaces the value of `label`, authorized by a signature of its
    /// controller over the handle's current nonce. Anyone may submit it. An
    /// empty value clears the record; the handle stays registered.
    function setValue(string calldata label, string calldata value, uint256 deadline, bytes calldata signature)
        external
    {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (!_isValidValue(value)) revert InvalidValue();

        bytes32 labelHash = keccak256(bytes(label));
        Record memory r = _records[labelHash];
        if (r.blob == address(0)) revert UnknownLabel();

        address controller = HandleBlob.controllerOf(r.blob);
        bytes32 digest = _setValueDigest(labelHash, value, r.nonce, deadline);
        if (ECDSA.recover(digest, signature) != controller) revert InvalidSigner();

        _records[labelHash] = Record({ blob: HandleBlob.write(controller, value), nonce: r.nonce + 1 });
        emit ValueChanged(labelHash, value);
    }

    // =====================================================================
    // Administration
    // =====================================================================

    /// Sets what `register` charges and who receives it. A zero amount
    /// disables the fee.
    function setFee(IERC20 token, uint96 amount, address treasury_) external onlyOwner {
        _setFee(token, amount, treasury_);
    }

    function _setFee(IERC20 token, uint96 amount, address treasury_) private {
        if (amount != 0 && (address(token) == address(0) || treasury_ == address(0))) revert InvalidFee();
        feeToken = token;
        feeAmount = amount;
        treasury = treasury_;
        emit FeeSet(token, amount, treasury_);
    }

    // =====================================================================
    // Views
    // =====================================================================

    /// The record of `label`. `controller` is zero when it is not registered.
    function recordOf(string calldata label)
        external
        view
        returns (string memory value, address controller, uint64 nonce)
    {
        Record memory r = _records[keccak256(bytes(label))];
        if (r.blob == address(0)) return ("", address(0), 0);
        return (HandleBlob.valueOf(r.blob), HandleBlob.controllerOf(r.blob), r.nonce);
    }

    /// The value of the handle whose label hashes to `labelHash`; empty when
    /// unregistered or cleared.
    function valueOf(bytes32 labelHash) external view returns (string memory) {
        address blob = _records[labelHash].blob;
        return blob == address(0) ? "" : HandleBlob.valueOf(blob);
    }

    /// Whether `label` is valid and unregistered.
    function available(string calldata label) external view returns (bool) {
        return _isValidLabel(bytes(label)) && _records[keccak256(bytes(label))].blob == address(0);
    }

    function isValidLabel(string calldata label) external pure returns (bool) {
        return _isValidLabel(bytes(label));
    }

    /// The EIP-712 digest a controller signs for `setValue` at the handle's
    /// current nonce.
    function setValueDigest(string calldata label, string calldata value, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        bytes32 labelHash = keccak256(bytes(label));
        return _setValueDigest(labelHash, value, _records[labelHash].nonce, deadline);
    }

    function _setValueDigest(bytes32 labelHash, string calldata value, uint64 nonce, uint256 deadline)
        private
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(SET_VALUE_TYPEHASH, labelHash, keccak256(bytes(value)), uint256(nonce), deadline))
        );
    }

    // =====================================================================
    // Validation
    // =====================================================================

    /// `[a-z0-9-]`, 3 to 32 bytes, no leading or trailing hyphen and no two
    /// hyphens in a row. Every such label is its own ENSIP-15 normal form;
    /// `--` is excluded because ENSIP-15 rejects it in positions 3 and 4.
    function _isValidLabel(bytes memory label) private pure returns (bool) {
        uint256 n = label.length;
        if (n < MIN_LABEL_LENGTH || n > MAX_LABEL_LENGTH) return false;
        bool prevHyphen = true;
        for (uint256 i; i < n; ++i) {
            bytes1 c = label[i];
            bool hyphen = c == 0x2d;
            if (hyphen) {
                if (prevHyphen) return false;
            } else if (!((c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39))) {
                return false;
            }
            prevHyphen = hyphen;
        }
        return !prevHyphen;
    }

    /// At most `MAX_VALUE_LENGTH` bytes, each printable ASCII without space
    /// (`0x21..0x7e`). Checked a word at a time; the tail word is padded with
    /// `0x21`, which passes.
    function _isValidValue(string calldata value) private pure returns (bool ok) {
        if (bytes(value).length > MAX_VALUE_LENGTH) return false;
        assembly ("memory-safe") {
            ok := 1
            let hi := 0x8080808080808080808080808080808080808080808080808080808080808080
            for { let i := 0 } lt(i, value.length) { i := add(i, 32) } {
                let w := calldataload(add(value.offset, i))
                let rem := sub(value.length, i)
                if lt(rem, 32) {
                    let keep := not(shr(shl(3, rem), not(0)))
                    w := or(
                        and(w, keep),
                        and(0x2121212121212121212121212121212121212121212121212121212121212121, not(keep))
                    )
                }
                // A byte fails when its high bit is set, when adding 0x5f does
                // not set it (below 0x21), or when adding 1 sets it (0x7f).
                // With no high bit set, neither addition carries across bytes.
                if or(
                    and(w, hi),
                    or(
                        xor(and(add(w, 0x5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f), hi), hi),
                        and(add(w, 0x0101010101010101010101010101010101010101010101010101010101010101), hi)
                    )
                ) { ok := 0 }
            }
        }
    }
}
