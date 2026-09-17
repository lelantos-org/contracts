// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Test.sol";

import { Bundler } from "../../src/bundler/Bundler.sol";

import { BundlerTestBase } from "./BundlerTestBase.sol";

/// Gas per bundle item and per bundle in steady state: the root ring is full, so
/// every advance overwrites a slot, and the fee accumulators are non-zero.
/// Proof verification is stubbed, so the figures exclude pairing cost, which is
/// independent of Bundler and calldata shape.
///
/// Run under `--isolate` so each `execute` is its own transaction with cold
/// access; the default profile sets `isolate = false`, under which the warm-up
/// leaves slots warm and the figures are understated:
///
///     forge test --match-contract BundlerGasTest --isolate -vv
///
/// Logs `execGas` (`vm.lastCallGas`, before refund), the refund, and the
/// calldata's own gas at 16/4 per non-zero/zero byte.
contract BundlerGasTest is BundlerTestBase {
    /// Enough advances to fill the ring, and one withdraw per fee token.
    function _steadyState() internal {
        for (uint256 i; i < 64; ++i) {
            _reanchor();
            Bundler.Call[] memory warm = new Bundler.Call[](1);
            uint64 start = masp.committedCount();
            bytes32 next = keccak256(abi.encode("warm", i));
            next = bytes32(uint256(next) % 2 ** 250);
            if (i == 0) warm[0] = _withdrawCall(bundler, 0x10_0000, 5, next, start);
            else if (i == 1) warm[0] = _withdrawNativeCall(NATIVE_RECIPIENT, 0x10_0100, 7, next, start);
            else warm[0] = _transferCall(bundler, 0x10_0000 + i * 0x100, next, start);
            vm.prank(OPERATOR);
            (uint256 executed,) = bundler.execute(warm);
            require(executed == 1, "warm-up item failed");
        }
        _reanchor();
    }

    /// Anchors subsequent spends at the current root.
    function _reanchor() internal {
        anchor = masp.currentRoot();
        anchorIndex = uint8(masp.rootIndex());
    }

    function _report(string memory label, Bundler.Call[] memory calls) internal {
        bytes memory cd = abi.encodeCall(Bundler.execute, (calls));
        uint256 zeros;
        for (uint256 i; i < cd.length; ++i) {
            if (cd[i] == 0) zeros++;
        }
        vm.prank(OPERATOR);
        (uint256 executed,) = bundler.execute(calls);
        Vm.Gas memory g = vm.lastCallGas();
        require(executed == calls.length, "not all executed");
        emit log_named_uint(string.concat(label, " execGas"), g.gasTotalUsed);
        emit log_named_int(string.concat(label, " refund"), g.gasRefunded);
        emit log_named_uint(string.concat(label, " cdBytes"), cd.length);
        emit log_named_uint(string.concat(label, " cdGas"), zeros * 4 + (cd.length - zeros) * 16);
    }

    function _one(Bundler.Call memory c) internal pure returns (Bundler.Call[] memory calls) {
        calls = new Bundler.Call[](1);
        calls[0] = c;
    }

    function test_gas_item_flush() public {
        _steadyState();
        uint256 id = _escrowDeposit();
        _report("flush", _one(_flushCall(id, masp.currentRoot(), _root(1), masp.committedCount())));
    }

    function test_gas_item_transfer() public {
        _steadyState();
        _report("transfer", _one(_transferCall(bundler, 0x100, _root(1), masp.committedCount())));
    }

    function test_gas_item_withdraw() public {
        _steadyState();
        _report("withdraw", _one(_withdrawCall(bundler, 0x200, 5, _root(1), masp.committedCount())));
    }

    function test_gas_item_withdrawNative() public {
        _steadyState();
        _report(
            "withdrawNative", _one(_withdrawNativeCall(NATIVE_RECIPIENT, 0x300, 7, _root(1), masp.committedCount()))
        );
    }

    function test_gas_item_swap() public {
        _steadyState();
        _report("swap", _one(_swapCall(bundler, 0x400, _root(1), masp.committedCount())));
    }

    function _transfers(uint256 k) internal {
        _steadyState();
        uint64 start = masp.committedCount();
        Bundler.Call[] memory calls = new Bundler.Call[](k);
        for (uint256 i; i < k; ++i) {
            calls[i] = _transferCall(bundler, 0x1000 * (i + 1), _root(i + 1), start + uint64(6 * i));
        }
        _report(string.concat("transfers K=", vm.toString(k)), calls);
    }

    function test_gas_bundle_transfers8() public {
        _transfers(8);
    }

    function test_gas_bundle_transfers21() public {
        _transfers(21);
    }

    function test_gas_bundle_mixed5() public {
        _steadyState();
        (Bundler.Call[] memory calls,,) = _mixedBundle();
        _report("mixed K=5", calls);
    }
}
