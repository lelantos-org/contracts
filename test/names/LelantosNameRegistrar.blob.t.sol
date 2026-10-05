// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { NameRegistrarTestBase } from "./NameRegistrarTestBase.sol";

/// How a handle is stored: one slot naming a `HandleBlob`, whose code is a STOP
/// byte, the controller, then the value.
contract LelantosNameRegistrarBlobTest is NameRegistrarTestBase {
    uint256 internal constant DEADLINE = 2_000_000_000;

    /// The blob named by the one slot `write` wrote in the registrar.
    function _blobWrittenBy(function() internal write) internal returns (address blob, uint64 nonce) {
        vm.record();
        write();
        (, bytes32[] memory writes) = vm.accesses(address(registrar));
        for (uint256 i = 1; i < writes.length; ++i) {
            assertEq(writes[i], writes[0], "one storage slot per handle");
        }
        uint256 slot = uint256(vm.load(address(registrar), writes[0]));
        blob = address(uint160(slot));
        nonce = uint64(slot >> 160);
    }

    function _register() internal {
        registrar.register(LABEL, VALUE, controller);
    }

    function _setNext() internal {
        registrar.setValue(LABEL, "lelantos1next", DEADLINE, _sign(CONTROLLER_KEY, LABEL, "lelantos1next", DEADLINE));
    }

    function _clear() internal {
        registrar.setValue(LABEL, "", DEADLINE, _sign(CONTROLLER_KEY, LABEL, "", DEADLINE));
    }

    function test_register_writesOneSlotAndABlobOfControllerAndValue() public {
        (address blob, uint64 nonce) = _blobWrittenBy(_register);
        assertEq(nonce, 0, "nonce");
        assertEq(blob.code, abi.encodePacked(hex"00", controller, VALUE), "blob code");
    }

    /// The blob's first byte is STOP: calling it runs nothing and changes nothing.
    function test_blob_isInert() public {
        (address blob,) = _blobWrittenBy(_register);
        (bool ok, bytes memory out) =
            blob.call(abi.encodeWithSignature("register(string,string,address)", "x", "y", this));
        assertTrue(ok, "a call to it succeeds");
        assertEq(out.length, 0, "and returns nothing");
        assertEq(_resolveText(LABEL), VALUE, "the record is unchanged");
    }

    function test_setValue_deploysANewBlobAndKeepsTheController() public {
        (address first,) = _blobWrittenBy(_register);
        (address second, uint64 nonce) = _blobWrittenBy(_setNext);

        assertTrue(second != first, "a new blob");
        assertEq(nonce, 1, "nonce bumped in the same slot");
        assertEq(second.code, abi.encodePacked(hex"00", controller, "lelantos1next"), "new blob code");
        // The old blob is immutable and stays where it was.
        assertEq(first.code, abi.encodePacked(hex"00", controller, VALUE), "old blob untouched");
    }

    function test_clearedRecord_keepsABlobOfTheControllerAlone() public {
        _register();
        (address blob,) = _blobWrittenBy(_clear);
        assertEq(blob.code, abi.encodePacked(hex"00", controller), "controller only");

        (string memory value, address ctl, uint64 nonce) = registrar.recordOf(LABEL);
        assertEq(value, "", "value");
        assertEq(ctl, controller, "controller");
        assertEq(nonce, 1, "nonce");
    }

    function test_reservedLabel_hasABlobOfItsControllerAlone() public view {
        (string memory value, address ctl, uint64 nonce) = registrar.recordOf("admin");
        assertEq(value, "", "value");
        assertEq(ctl, RESERVED_CONTROLLER, "controller");
        assertEq(nonce, 0, "nonce");
    }

    function test_unregisteredLabel_readsAsNothing() public view {
        (string memory value, address ctl, uint64 nonce) = registrar.recordOf("nobody");
        assertEq(value, "", "value");
        assertEq(ctl, address(0), "controller");
        assertEq(nonce, 0, "nonce");
        assertEq(registrar.valueOf(keccak256("nobody")), "", "valueOf");
    }

    /// Every length up to the cap round-trips, across word boundaries and the
    /// blob's 21-byte header.
    function testFuzz_valueRoundTrips(uint256 length, uint8 seed) public {
        length = bound(length, 1, registrar.MAX_VALUE_LENGTH());
        bytes memory raw = new bytes(length);
        for (uint256 i; i < length; ++i) {
            raw[i] = bytes1(uint8(0x21 + ((i + seed) % 94)));
        }
        registrar.register("fuzzed", string(raw), controller);

        (string memory value, address ctl,) = registrar.recordOf("fuzzed");
        assertEq(value, string(raw), "value");
        assertEq(ctl, controller, "controller");
        assertEq(registrar.valueOf(keccak256("fuzzed")), string(raw), "valueOf");
    }

    /// The controller survives any address, including ones with leading zero bytes.
    function testFuzz_controllerRoundTrips(address anyController) public {
        vm.assume(anyController != address(0));
        registrar.register("fuzzed", VALUE, anyController);
        (, address ctl,) = registrar.recordOf("fuzzed");
        assertEq(ctl, anyController);
    }
}
