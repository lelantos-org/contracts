// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Test.sol";
import { MASP } from "../../src/MASP.sol";
import { Bundler } from "../../src/bundler/Bundler.sol";
import { BundlerFactory } from "../../src/bundler/BundlerFactory.sol";
import { GasBurner } from "../mocks/GasBurner.sol";
import { GreedyPool } from "../mocks/BundlerAttackers.sol";

import { BundlerTestBase } from "./BundlerTestBase.sol";

/// Behaviour of `Bundler.execute`: mixed bundles, stopping at the first failure,
/// and running out of gas. Fixture and call builders in `BundlerTestBase`;
/// binding, access control and raw calldata in the `Bundler.*.t.sol` suites.
contract BundlerTest is BundlerTestBase {
    // --- mixed bundle ------------------------------------------------------

    function test_execute_mixedBundle_allFiveLand() public {
        (Bundler.Call[] memory calls, uint256 depositId, uint64 start) = _mixedBundle();

        vm.expectEmit(address(bundler));
        emit Bundler.BundleExecuted(5, 5);
        vm.prank(OPERATOR);
        (uint256 executed, bytes memory reason) = bundler.execute(calls);

        assertEq(executed, 5, "all five executed");
        assertEq(reason.length, 0, "no failure reason");
        assertEq(masp.committedCount(), start + 26, "tree advanced by 2 + 4 * 6 leaves");
        assertEq(masp.currentRoot(), _root(5), "final root");
        for (uint256 k = 1; k <= 5; ++k) {
            assertTrue(masp.isKnownRoot(_root(k)), "every intermediate root registered");
        }
        assertEq(masp.escrowed(depositId), bytes32(0), "deposit flushed");
        assertGt(tokenA.balanceOf(RECIPIENT), 0, "ERC-20 withdraw paid");
        assertGt(NATIVE_RECIPIENT.balance, 0, "native withdraw paid");
        assertTrue(masp.escrowed(depositId + 1) != bytes32(0), "swap output escrowed");
    }

    /// The log layout of a mixed bundle, from which indexers reconstruct leaf
    /// indices. One transaction carries several `RootAdvanced`, and the two
    /// paths order their leaves differently around it: a flush emits
    /// `DepositFlushed` before its root, a spend emits `NotePayload` after. The
    /// adapters' own events follow the pool events of their item.
    ///
    /// Encoded as one character per event (`_eventTag`) so the whole sequence is
    /// a single assertion: F DepositFlushed, R RootAdvanced, N NullifierConsumed,
    /// A AssetMoved, P NotePayload, E DepositEscrowed, W NativeWithdrawn,
    /// S SwapExecuted. Other events (token transfers, fee accrual) are skipped.
    function test_execute_mixedBundle_logLayout() public {
        (Bundler.Call[] memory calls,, uint64 start) = _mixedBundle();

        vm.recordLogs();
        vm.prank(OPERATOR);
        bundler.execute(calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes memory tape;
        uint64[] memory starts = new uint64[](5);
        uint64[] memory inserted = new uint64[](5);
        bytes32[] memory newRoots = new bytes32[](5);
        uint256 roots;
        for (uint256 i; i < logs.length; ++i) {
            bytes1 tag = _eventTag(logs[i]);
            if (tag == 0) continue;
            tape = bytes.concat(tape, tag);
            if (tag == "R") {
                starts[roots] = uint64(uint256(logs[i].topics[1]));
                (inserted[roots],, newRoots[roots]) = abi.decode(logs[i].data, (uint64, bytes32, bytes32));
                roots++;
            }
        }

        assertEq(
            string(tape),
            string.concat(
                "FR", // flush: leaves lead their root
                "NNNNRPPPPPP", // transfer: root leads its leaves
                "NNNNRAPPPPPP", // withdraw
                "NNNNRAPPPPPPW", // withdrawNative, then the adapter's payout
                "NNNNRAPPPPPPEAS" // swap: withdraw leg, output escrow, then the wrapper
            ),
            "event layout"
        );
        assertEq(roots, 5, "one RootAdvanced per item");
        uint64 expectedStart = start;
        for (uint256 k = 0; k < 5; ++k) {
            assertEq(starts[k], expectedStart, "startIndex chains");
            assertEq(newRoots[k], _root(k + 1), "newRoot per item");
            expectedStart += inserted[k];
        }
    }

    /// Calldata per item kind, as the relayer packs bundles against a per-chain
    /// transaction size limit. Pinned so a struct change that grows an item is
    /// noticed where `max_tx_bytes` is sized.
    ///
    /// The aux ciphertexts here are the 2-byte minimum; production notes carry
    /// 130 bytes each, adding 128 bytes of payload (padded to 160) per output.
    function test_itemCalldataSizes() public {
        uint256 depositId = _escrowDeposit();
        bytes32 r = masp.currentRoot();
        uint64 s = masp.committedCount();

        uint256 flushLen = _flushCall(depositId, r, _root(1), s).data.length;
        uint256 transferLen = _transferCall(bundler, 0x100, _root(1), s).data.length;
        uint256 withdrawLen = _withdrawCall(bundler, 0x200, 5, _root(1), s).data.length;
        uint256 nativeLen = _withdrawNativeCall(NATIVE_RECIPIENT, 0x300, 7, _root(1), s).data.length;
        uint256 swapLen = _swapCall(bundler, 0x400, _root(1), s).data.length;

        emit log_named_uint("flushBatch (1 deposit)", flushLen);
        emit log_named_uint("transfer", transferLen);
        emit log_named_uint("withdraw", withdrawLen);
        emit log_named_uint("withdrawNative", nativeLen);
        emit log_named_uint("swap", swapLen);

        assertEq(transferLen, withdrawLen, "transfer and withdraw share a shape");
        assertEq(nativeLen, withdrawLen, "withdrawNative carries the withdraw shape");
        assertGt(swapLen, withdrawLen, "swap adds the escrow leg and route");
    }

    // --- stop at first failure ---------------------------------------------

    function test_execute_stopsAtFirstFailure_keepsPrefix() public {
        uint64 start = masp.committedCount();

        Bundler.Call[] memory calls = new Bundler.Call[](3);
        calls[0] = _transferCall(bundler, 0x100, _root(1), start);
        // Wrong start index: the chain position check rejects it.
        calls[1] = _transferCall(bundler, 0x200, _root(2), start + 7);
        calls[2] = _transferCall(bundler, 0x300, _root(3), start + 12);

        bytes memory expected = abi.encodeWithSelector(MASP.BatchMisaligned.selector);
        vm.expectEmit(address(bundler));
        emit Bundler.BundleItemFailed(1, expected);
        vm.expectEmit(address(bundler));
        emit Bundler.BundleExecuted(1, 3);
        vm.prank(OPERATOR);
        (uint256 executed, bytes memory reason) = bundler.execute(calls);

        assertEq(executed, 1, "stopped after the first call");
        assertEq(reason, expected, "reason is the inner revert");
        assertEq(masp.committedCount(), start + 6, "only the first call landed");
        assertEq(masp.currentRoot(), _root(1), "root from the first call");
        assertFalse(masp.isKnownRoot(_root(3)), "third call never ran");
    }

    // --- running out of gas -----------------------------------------------

    /// At any gas limit that reaches the second call, the first stays landed:
    /// the second either lands too or is reported as `ItemOutOfGas`.
    function testFuzz_execute_itemOutOfGas_keepsPrefix(uint256 gasLimit) public {
        uint64 start = masp.committedCount();
        Bundler.Call[] memory calls = new Bundler.Call[](2);
        calls[0] = _transferCall(bundler, 0x100, _root(1), start);
        calls[1] = _transferCall(bundler, 0x200, _root(2), start + 6);
        gasLimit = bound(gasLimit, _gasForFirst(calls) + 40_000, _gasFor(calls) + 100_000);

        (bool ok, uint256 executed, bytes memory reason) = _executeWithGas(bundler, calls, gasLimit);

        assertTrue(ok, "execute returned");
        assertGe(executed, 1, "first call landed");
        if (executed == 1) {
            assertEq(reason, abi.encodeWithSelector(Bundler.ItemOutOfGas.selector), "reported as out of gas");
        }
        assertEq(masp.committedCount(), start + 6 * executed, "tree matches what executed");
    }

    /// A native payout to a recipient that burns all its gas cannot fail its
    /// item: the push gets only the stipend and the coin is force-sent. Short of
    /// gas, the payout is reported as `ItemOutOfGas` and the transfer stays.
    function testFuzz_execute_gasBurningPayout_keepsPrefix(uint256 gasLimit) public {
        uint64 start = masp.committedCount();
        Bundler.Call[] memory calls = new Bundler.Call[](2);
        calls[0] = _transferCall(bundler, 0x100, _root(1), start);
        calls[1] = _withdrawNativeCall(address(new GasBurner()), 0x300, 7, _root(2), start + 6);
        gasLimit = bound(gasLimit, _gasForFirst(calls) + 40_000, 5_000_000);

        (bool ok, uint256 executed, bytes memory reason) = _executeWithGas(bundler, calls, gasLimit);

        assertTrue(ok, "execute returned");
        assertGe(executed, 1, "transfer landed");
        if (executed == 1) {
            assertEq(reason, abi.encodeWithSelector(Bundler.ItemOutOfGas.selector), "only ever short of gas");
        }
        assertEq(masp.committedCount(), start + 6 * executed, "tree matches what executed");
    }

    /// With enough gas, a gas-burning payout lands like any other item.
    function test_execute_gasBurningPayout_lands() public {
        uint64 start = masp.committedCount();
        Bundler.Call[] memory calls = new Bundler.Call[](2);
        calls[0] = _withdrawNativeCall(address(new GasBurner()), 0x300, 7, _root(1), start);
        calls[1] = _transferCall(bundler, 0x100, _root(2), start + 6);

        (bool ok, uint256 executed,) = _executeWithGas(bundler, calls, 5_000_000);

        assertTrue(ok, "execute returned");
        assertEq(executed, 2, "payout did not stop the bundle");
        assertEq(masp.committedCount(), start + 12, "both landed");
    }

    /// However late a call fails and however long its revert payload, `execute`
    /// has the gas to report it.
    function testFuzz_execute_lateFailure_alwaysReported(uint256 gasLimit, uint256 leave) public {
        GreedyPool pool = new GreedyPool();
        Bundler b = _createBundler(new BundlerFactory(address(pool), address(0), address(0), address(0)), BUNDLER_OWNER);

        gasLimit = bound(gasLimit, 60_000, 3_000_000);
        leave = bound(leave, 0, gasLimit);
        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = Bundler.Call({ target: address(pool), data: abi.encodePacked(MASP.transfer.selector, leave) });

        (bool ok, uint256 executed, bytes memory reason) = _executeWithGas(b, calls, gasLimit);

        assertTrue(ok, "execute returned");
        assertEq(executed, 0, "call failed");
        if (bytes4(reason) != Bundler.ItemOutOfGas.selector) {
            assertEq(reason.length, 1024, "long payload truncated");
        }
    }

    /// A bundle built on a tree position another submitter already advanced
    /// fails at its first item and executes nothing.
    function test_execute_staleStartAtFirstItem_executesNothing() public {
        uint64 start = masp.committedCount();
        Bundler other = _createBundler(OTHER_OWNER);
        Bundler.Call[] memory first = new Bundler.Call[](1);
        first[0] = _transferCall(other, 0x900, _root(98), start);
        vm.prank(OPERATOR);
        other.execute(first);

        Bundler.Call[] memory calls = new Bundler.Call[](2);
        calls[0] = _transferCall(bundler, 0x100, _root(1), start);
        calls[1] = _transferCall(bundler, 0x200, _root(2), start + 6);

        vm.prank(OPERATOR);
        (uint256 executed, bytes memory reason) = bundler.execute(calls);

        assertEq(executed, 0, "nothing executed");
        assertEq(reason, abi.encodeWithSelector(MASP.BatchMisaligned.selector), "stale position reported");
        assertEq(masp.committedCount(), start + 6, "only the other submitter's spend landed");
    }
}
