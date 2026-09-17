// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";
import { Bundler } from "../../src/bundler/Bundler.sol";

import { BundlerTestBase } from "./BundlerTestBase.sol";

/// `Bundler.execute` on hand-corrupted ABI encodings: every malformed offset or
/// length is refused as `MalformedCall` before any call runs. Fixture and call
/// builders in `BundlerTestBase`.
contract BundlerRawCalldataTest is BundlerTestBase {
    // --- malformed ABI -----------------------------------------------------

    /// `execute([Call(masp, transfer.selector)])`, whose words sit at fixed
    /// positions: 0x04 array offset, 0x24 length, 0x44 element offset, 0x64
    /// target, 0x84 payload offset, 0xa4 payload length, 0xc4 payload.
    function _oneCallCalldata() internal view returns (bytes memory cd) {
        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = Bundler.Call({ target: address(masp), data: abi.encodePacked(MASP.transfer.selector) });
        cd = abi.encodeCall(Bundler.execute, (calls));
        assertEq(cd.length, 0xe4, "layout");
    }

    function _setWord(bytes memory cd, uint256 pos, uint256 value) internal pure {
        assembly {
            mstore(add(add(cd, 0x20), pos), value)
        }
    }

    function _executeRaw(bytes memory cd) internal returns (bool ok, bytes memory ret) {
        vm.prank(OPERATOR);
        (ok, ret) = address(bundler).call(cd);
    }

    function _assertMalformed(bytes memory cd, uint256 index, string memory label) internal {
        uint64 start = masp.committedCount();
        (bool ok, bytes memory ret) = _executeRaw(cd);
        assertFalse(ok, label);
        assertEq(ret, abi.encodeWithSelector(Bundler.MalformedCall.selector, index), label);
        assertEq(masp.committedCount(), start, "nothing ran");
    }

    /// The unmodified encoding decodes: the call runs and the pool rejects its
    /// 4-byte payload, which `execute` reports rather than reverting.
    function test_rawCalldata_wellFormed_executes() public {
        (bool ok, bytes memory ret) = _executeRaw(_oneCallCalldata());
        assertTrue(ok, "decoded");
        (uint256 executed,) = abi.decode(ret, (uint256, bytes));
        assertEq(executed, 0, "pool refused the empty payload");
    }

    function test_rawCalldata_elementOffsetPastCalldata() public {
        bytes memory cd = _oneCallCalldata();
        _setWord(cd, 0x44, cd.length);
        _assertMalformed(cd, 0, "element head past the end");
        _setWord(cd, 0x44, type(uint256).max - 0x1f);
        _assertMalformed(cd, 0, "element offset wraps");
    }

    function test_rawCalldata_payloadOffsetPastCalldata() public {
        bytes memory cd = _oneCallCalldata();
        _setWord(cd, 0x84, 0x80);
        _assertMalformed(cd, 0, "length word past the end");
        _setWord(cd, 0x84, type(uint256).max);
        _assertMalformed(cd, 0, "payload offset wraps");
    }

    function test_rawCalldata_lengthOverflow() public {
        bytes memory cd = _oneCallCalldata();
        _setWord(cd, 0xa4, type(uint256).max);
        _assertMalformed(cd, 0, "length wraps");
        _setWord(cd, 0xa4, uint256(1) << 64);
        _assertMalformed(cd, 0, "length past any calldata");
        _setWord(cd, 0xa4, 0x21);
        _assertMalformed(cd, 0, "payload one byte past the end");
    }

    function test_rawCalldata_truncatedPayload() public {
        bytes memory cd = _oneCallCalldata();
        // Keep the length word, drop the payload bytes it counts.
        assembly {
            mstore(cd, 0xc4)
        }
        _assertMalformed(cd, 0, "payload cut off");
        // Cut into the element head itself.
        assembly {
            mstore(cd, 0x84)
        }
        _assertMalformed(cd, 0, "element head cut off");
    }

    function test_rawCalldata_dirtyTarget() public {
        bytes memory cd = _oneCallCalldata();
        _setWord(cd, 0x64, uint256(uint160(address(masp))) | (uint256(1) << 160));
        _assertMalformed(cd, 0, "target above 160 bits");
    }

    /// A well-formed first element does not run when a later one is malformed.
    function test_rawCalldata_laterElementMalformed_nothingRuns() public {
        Bundler.Call[] memory calls = new Bundler.Call[](2);
        calls[0] = _transferCall(bundler, 0x100, _root(1), masp.committedCount());
        calls[1] = Bundler.Call({ target: address(masp), data: abi.encodePacked(MASP.transfer.selector) });
        bytes memory cd = abi.encodeCall(Bundler.execute, (calls));
        // calls[1]'s offset, relative to the first head slot at 0x44.
        _setWord(cd, 0x64, cd.length);
        _assertMalformed(cd, 1, "second element past the end");
    }

    /// The array length itself is checked by the ABI decoder before `_decode`.
    function test_rawCalldata_arrayLengthPastCalldata() public {
        bytes memory cd = _oneCallCalldata();
        _setWord(cd, 0x24, 1000);
        (bool ok,) = _executeRaw(cd);
        assertFalse(ok, "decoder rejects the length");
    }

    /// Any payload length the calldata cannot hold is refused, whatever it is.
    function testFuzz_rawCalldata_payloadLengthBeyondCalldata(uint256 len) public {
        bytes memory cd = _oneCallCalldata();
        len = bound(len, 0x21, type(uint256).max);
        _setWord(cd, 0xa4, len);
        _assertMalformed(cd, 0, "length beyond calldata");
    }

    /// Any element offset: either it lands inside the calldata and decodes to
    /// some call the allowlist then judges, or it is refused as malformed. It
    /// never executes anything.
    function testFuzz_rawCalldata_elementOffset(uint256 rel) public {
        bytes memory cd = _oneCallCalldata();
        _setWord(cd, 0x44, rel);
        uint64 start = masp.committedCount();
        (bool ok, bytes memory ret) = _executeRaw(cd);
        if (rel == 0x20) {
            assertTrue(ok, "canonical offset");
        } else {
            assertFalse(ok, "non-canonical offset refused here");
            bytes4 sel = bytes4(ret);
            assertTrue(
                sel == Bundler.MalformedCall.selector || sel == Bundler.CallNotAllowed.selector, "refused by _decode"
            );
        }
        assertEq(masp.committedCount(), start, "nothing landed");
    }
}
