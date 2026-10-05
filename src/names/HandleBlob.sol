// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// A handle's controller and value, held as the code of a contract.
///
/// Writing a value to storage costs a slot per 32 bytes; deploying it as code
/// costs a fixed creation charge and a fraction of that per byte. For a value
/// the length of a shielded address the blob is about a third of the price, and
/// the handle's record shrinks to the blob's address.
///
/// Layout of a blob's code:
///
///   byte 0        STOP, so a call to the blob does nothing
///   bytes 1..20   the controller
///   bytes 21..    the value, possibly empty
///
/// A blob is immutable. A new value is a new blob; the old one stays on chain.
library HandleBlob {
    /// STOP and the controller: the code before the value.
    uint256 private constant HEADER_LENGTH = 21;

    /// The creation code, left-aligned in a word with a zero size: ten bytes
    /// that return everything after them.
    ///
    ///   61 SSSS   PUSH2 size        size = HEADER_LENGTH + the value's length
    ///   80        DUP1
    ///   60 0a     PUSH1 10          the creation code's own length
    ///   3d        RETURNDATASIZE    0
    ///   39        CODECOPY          memory[0, size) = code[10, 10 + size)
    ///   3d        RETURNDATASIZE    0
    ///   f3        RETURN            memory[0, size)
    uint256 private constant CREATION_CODE = 0x61000080600a3d393df3 << 176;
    /// Where `size` sits in that word: bytes 1 and 2.
    uint256 private constant SIZE_SHIFT = 232;

    /// The deploy ran out of gas or hit the code size limit.
    error BlobNotCreated();

    /// Deploys a blob holding `controller` and `value`.
    function write(address controller, string calldata value) internal returns (address blob) {
        uint256 offset;
        assembly ("memory-safe") {
            offset := value.offset
        }
        return _deploy(controller, offset, bytes(value).length);
    }

    /// Deploys a blob holding `controller` and an empty value.
    function writeEmpty(address controller) internal returns (address blob) {
        return _deploy(controller, 0, 0);
    }

    function controllerOf(address blob) internal view returns (address controller) {
        assembly ("memory-safe") {
            // Right-aligned in the scratch word at 0x00, whose upper bytes are masked off.
            extcodecopy(blob, 0x0c, 1, 20)
            controller := and(mload(0x00), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function valueOf(address blob) internal view returns (string memory value) {
        assembly ("memory-safe") {
            let length := sub(extcodesize(blob), HEADER_LENGTH)
            value := mload(0x40)
            mstore(0x40, and(add(add(value, 0x3f), length), not(0x1f)))
            mstore(value, length)
            extcodecopy(blob, add(value, 0x20), HEADER_LENGTH, length)
        }
    }

    /// Deploys `STOP ‖ controller ‖ calldata[valueOffset, valueOffset + valueLength)`.
    ///
    /// The creation code, the STOP and the controller fill 31 bytes of one word;
    /// the value is copied in right behind them.
    function _deploy(address controller, uint256 valueOffset, uint256 valueLength) private returns (address blob) {
        assembly ("memory-safe") {
            let code := mload(0x40)
            let size := add(HEADER_LENGTH, valueLength)
            let owner := and(controller, 0xffffffffffffffffffffffffffffffffffffffff)
            mstore(code, or(CREATION_CODE, or(shl(SIZE_SHIFT, size), shl(8, owner))))
            calldatacopy(add(code, 31), valueOffset, valueLength)
            blob := create(0, code, add(31, valueLength))
        }
        if (blob == address(0)) revert BlobNotCreated();
    }
}
