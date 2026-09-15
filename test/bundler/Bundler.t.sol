// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { CommitmentTree } from "../../src/CommitmentTree.sol";
import { Bundler } from "../../src/bundler/Bundler.sol";
import { BundlerFactory } from "../../src/bundler/BundlerFactory.sol";
import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { SwapIntent } from "../swap/SwapIntent.sol";
import { OwnableInit } from "../../src/OwnableInit.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { GasBurner } from "../mocks/GasBurner.sol";
import { MockSwapAdapter } from "../swap/mocks/MockSwapAdapter.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { deployPoolUniform } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// Re-enters `Bundler.execute` whenever it is called or paid, recording why the
/// nested call reverted: as a bundled pool target, or as a native payout
/// recipient. The tests make it an operator, so only the guard can stop it.
contract Reenterer {
    Bundler internal bundler;
    bytes public lastError;

    function setBundler(Bundler b) external {
        bundler = b;
    }

    receive() external payable {
        _reenter();
    }

    fallback() external {
        _reenter();
    }

    function _reenter() private {
        try bundler.execute(new Bundler.Call[](0)) { }
        catch (bytes memory err) {
            lastError = err;
        }
    }
}

/// Stands in for a pool whose calls fail as late as possible: it spends gas
/// until what is left is at most the word after the selector, then reverts
/// with a payload longer than `Bundler.MAX_REASON_BYTES`, or runs out of gas
/// trying to.
contract GreedyPool {
    fallback() external {
        uint256 leave = uint256(bytes32(msg.data[4:36]));
        while (gasleft() > leave) { }
        bytes memory payload = new bytes(2048);
        assembly {
            revert(add(payload, 0x20), mload(payload))
        }
    }
}

/// `Bundler` against a real pool and real adapters. Proof verification is
/// mocked to accept, as in the other pool suites: what is under test is that
/// chained tree positions land in one transaction, that each call's submitter
/// binding holds through the Bundler, and that execution stops at the first
/// failure.
contract BundlerTest is Test {
    uint64 internal constant ASSET_A = 1; // plain ERC-20, spent and swapped from
    uint64 internal constant ASSET_WETH = 2; // wrapped native, withdrawn natively
    uint64 internal constant ASSET_B = 3; // plain ERC-20, swapped into
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant TREASURY = TestConstants.TREASURY;
    address internal constant RECIPIENT = TestConstants.RECIPIENT;

    address internal constant BUNDLER_OWNER = address(0xB0551);
    address internal constant OTHER_OWNER = address(0x0712E7);
    address internal constant OPERATOR = address(0x0FE7A70);
    address internal constant SPEND_PAYER = address(0x9A7E7);
    address internal constant NATIVE_RECIPIENT = address(0xE7E7);
    /// Escrow payer for flushed deposits; carries a permissive ERC-1271 stub.
    address internal constant DEPOSIT_PAYER = address(0xface);
    uint64 internal constant DEPOSIT_UNITS = 100;
    bytes32 internal constant DEPOSIT_CM = bytes32(uint256(0xd0));
    bytes32 internal constant FEE_CM = bytes32(uint256(0xfee));
    address internal constant SWAP_REFUND_TO = TestConstants.SWAP_REFUND_TO;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockWETH9 internal weth;
    address internal permit2;
    MockBatchVerifier internal bv;
    MASP internal masp;
    NativeAdapter internal nativeAdapter;
    SwapWrapper internal wrapper;
    MockSwapAdapter internal swapAdapter;
    BundlerFactory internal factory;
    Bundler internal bundler;

    /// A root every spend in these tests proves membership against, and its
    /// ring slot.
    bytes32 internal anchor;
    uint8 internal anchorIndex;

    function setUp() public {
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        weth = new MockWETH9();
        permit2 = new DeployPermit2().deployPermit2();

        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        bv = new MockBatchVerifier();

        uint64[] memory ids = new uint64[](3);
        IERC20[] memory tokens = new IERC20[](3);
        uint256[] memory scales = new uint256[](3);
        (ids[0], tokens[0], scales[0]) = (ASSET_A, IERC20(address(tokenA)), SCALE);
        (ids[1], tokens[1], scales[1]) = (ASSET_WETH, IERC20(address(weth)), SCALE);
        (ids[2], tokens[2], scales[2]) = (ASSET_B, IERC20(address(tokenB)), SCALE);

        masp = deployPoolUniform(
            tub, bv, ISignatureTransfer(permit2), ids, tokens, scales, FEE_BPS, TREASURY, address(this)
        );
        Stubs.acceptAllProofs(masp.TREE_UPDATE_BATCH_VERIFIER(), bv);

        nativeAdapter =
            new NativeAdapter(IMASPPool(address(masp)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));
        wrapper = new SwapWrapper(IMASPPool(address(masp)), IAllowanceTransfer(permit2), address(this), TREASURY);
        swapAdapter = new MockSwapAdapter();
        wrapper.setAdapterAllowed(address(swapAdapter), true);
        wrapper.prepareToken(IERC20(address(tokenB)));
        wrapper.prepareToken(IERC20(address(tokenA)));

        factory = new BundlerFactory(address(masp), address(nativeAdapter), address(wrapper));
        bundler = _createBundler(BUNDLER_OWNER);

        Stubs.installPermissiveERC1271(DEPOSIT_PAYER);
        anchor = masp.currentRoot();
        anchorIndex = uint8(masp.rootIndex());
    }

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
        Bundler b = _createBundler(new BundlerFactory(address(pool), address(0), address(0)), BUNDLER_OWNER);

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

    // --- submitter binding across Bundlers ---------------------------------

    function test_spendBoundToAnotherBundler_fails() public {
        Bundler other = _createBundler(OTHER_OWNER);

        Bundler.Call[] memory calls = new Bundler.Call[](1);
        // Bound to `bundler`, submitted through `other`.
        calls[0] = _transferCall(bundler, 0x100, _root(1), masp.committedCount());

        vm.prank(OPERATOR);
        (uint256 executed, bytes memory reason) = other.execute(calls);

        assertEq(executed, 0, "rejected");
        assertEq(reason, abi.encodeWithSelector(MASP.BadRelayer.selector), "pool binding holds");
    }

    function test_swapBoundToAnotherBundler_fails() public {
        Bundler other = _createBundler(OTHER_OWNER);

        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = _swapCall(bundler, 0x400, _root(1), masp.committedCount());

        vm.prank(OPERATOR);
        (uint256 executed, bytes memory reason) = other.execute(calls);

        assertEq(executed, 0, "rejected");
        assertEq(
            reason,
            abi.encodeWithSelector(SwapWrapper.UnauthorizedSwapCaller.selector, address(other), address(bundler)),
            "wrapper binding holds"
        );
    }

    /// A swap whose venue leg fails still lands, as a refund, so the items
    /// behind it land too.
    function test_execute_refundedSwap_doesNotStopTheBundle() public {
        uint64 start = masp.committedCount();
        SwapWrapper.SwapArgs memory a = _swapArgs(bundler, 0x400, _root(1), start);
        a.deadline = block.timestamp - 1;
        Bundler.Call[] memory calls = new Bundler.Call[](2);
        calls[0] = _wrapperCall(SwapIntent.bind(a));
        calls[1] = _transferCall(bundler, 0x100, _root(2), start + 6);

        vm.expectEmit(true, true, false, false, address(wrapper));
        emit SwapWrapper.SwapRefunded(address(swapAdapter), address(tokenA), 0, 0, 0, SwapWrapper.SwapExpired.selector);
        vm.prank(OPERATOR);
        (uint256 executed,) = bundler.execute(calls);

        assertEq(executed, 2, "both landed");
        assertEq(masp.committedCount(), start + 12, "tree advanced past both");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "nothing stranded in the wrapper");
    }

    /// A bundled swap names the Bundler as `pi_w.payer`. A cancelled output
    /// escrow refunds the intent-bound `refundTo`, not the Bundler, which cannot
    /// move tokens out.
    function test_swapEscrowCancel_refundsRefundTo_notBundler() public {
        uint256 depositId = masp.nextDepositId();
        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = _swapCall(bundler, 0x400, _root(1), masp.committedCount());
        // `vm.getBlockNumber`, not `block.number`: via-IR may re-read the latter
        // after the `vm.roll` below.
        uint32 submittedAt = uint32(vm.getBlockNumber());

        vm.prank(OPERATOR);
        (uint256 executed,) = bundler.execute(calls);
        assertEq(executed, 1, "swap landed");

        (address refundTo, uint256 amount) = wrapper.escrows(depositId);
        assertEq(refundTo, SWAP_REFUND_TO, "escrow owned by refundTo");
        assertGt(amount, 0, "escrow recorded");

        vm.roll(uint256(submittedAt) + masp.cancelDelay());
        wrapper.cancelEscrow(
            depositId,
            990,
            bytes32(uint256(0x400) + 0x100),
            [uint256(0), 0],
            ASSET_B,
            FEE_BPS,
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: FEE_CM, feeCvDep: [uint256(0), 0] })
        );

        assertEq(tokenB.balanceOf(SWAP_REFUND_TO), amount, "refund reached refundTo");
        assertEq(tokenB.balanceOf(address(bundler)), 0, "nothing stranded in the Bundler");
        assertEq(tokenB.balanceOf(address(wrapper)), 0, "nothing stranded in the wrapper");
    }

    /// A Bundler operator submits as the swap's `payer` but cannot rewrite the
    /// swap's intent. Substituting its own output note and a floor of 1 into a
    /// user's bound payload fails the item instead of redirecting the proceeds.
    function test_operatorCannotRedirectSwapOutput() public {
        uint256 depositId = masp.nextDepositId();
        SwapWrapper.SwapArgs memory a = SwapIntent.bind(_swapArgs(bundler, 0x400, _root(1), masp.committedCount()));
        a.deposit_d.recipient = OPERATOR;
        a.deposit_d.outCm = bytes32(uint256(0x0BAD));
        a.minOut = 1;
        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = _wrapperCall(a);

        vm.prank(OPERATOR);
        (uint256 executed, bytes memory reason) = bundler.execute(calls);

        assertEq(executed, 0, "tampered swap rejected");
        assertEq(reason, abi.encodeWithSelector(SwapWrapper.IntentMismatch.selector), "intent binding holds");
        assertEq(masp.escrowed(depositId), bytes32(0), "nothing escrowed");
    }

    // --- access control and call validation --------------------------------

    function test_execute_revert_NotOperator() public {
        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = _transferCall(bundler, 0x100, _root(1), masp.committedCount());

        vm.expectRevert(abi.encodeWithSelector(Bundler.NotOperator.selector, address(this)));
        bundler.execute(calls);
    }

    function test_execute_revert_EmptyBundle() public {
        vm.expectRevert(Bundler.EmptyBundle.selector);
        vm.prank(OPERATOR);
        bundler.execute(new Bundler.Call[](0));
    }

    function test_execute_revert_unregisteredTarget_beforeAnyCall() public {
        uint64 start = masp.committedCount();
        Bundler.Call[] memory calls = new Bundler.Call[](2);
        calls[0] = _transferCall(bundler, 0x100, _root(1), start);
        calls[1] = Bundler.Call({ target: address(tokenA), data: calls[0].data });

        vm.expectRevert(abi.encodeWithSelector(Bundler.CallNotAllowed.selector, 1));
        vm.prank(OPERATOR);
        bundler.execute(calls);
        assertEq(masp.committedCount(), start, "valid first call did not run");
    }

    function test_execute_revert_disallowedSelector() public {
        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = Bundler.Call({
            target: address(masp), data: abi.encodeWithSelector(MASP.cancelDeposit.selector, uint256(0))
        });

        vm.expectRevert(abi.encodeWithSelector(Bundler.CallNotAllowed.selector, 0));
        vm.prank(OPERATOR);
        bundler.execute(calls);
    }

    function test_execute_revert_shortCalldata() public {
        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = Bundler.Call({ target: address(masp), data: hex"a9059c" });

        vm.expectRevert(abi.encodeWithSelector(Bundler.CallNotAllowed.selector, 0));
        vm.prank(OPERATOR);
        bundler.execute(calls);
    }

    /// Each target admits only its own entry points: a selector valid on one
    /// allowed contract is refused on another.
    function test_execute_revert_selectorOfAnotherTarget() public {
        address[4] memory targets = [address(masp), address(masp), address(nativeAdapter), address(wrapper)];
        bytes4[4] memory selectors = [
            NativeAdapter.withdrawNative.selector,
            SwapWrapper.swap.selector,
            MASP.withdraw.selector,
            MASP.transfer.selector
        ];
        for (uint256 i; i < targets.length; ++i) {
            Bundler.Call[] memory calls = new Bundler.Call[](1);
            calls[0] = Bundler.Call({ target: targets[i], data: abi.encodePacked(selectors[i]) });
            vm.expectRevert(abi.encodeWithSelector(Bundler.CallNotAllowed.selector, 0));
            vm.prank(OPERATOR);
            bundler.execute(calls);
        }
    }

    function test_targetsAreTheFactorys() public view {
        assertEq(bundler.POOL(), address(masp), "pool");
        assertEq(bundler.NATIVE_ADAPTER(), address(nativeAdapter), "native adapter");
        assertEq(bundler.SWAP_WRAPPER(), address(wrapper), "swap wrapper");
    }

    /// A chain without the adapters leaves those slots zero. Zero is never a
    /// target, and the deployed adapters are not either.
    function test_absentAdapters_notCallable() public {
        Bundler b = _createBundler(new BundlerFactory(address(masp), address(0), address(0)), BUNDLER_OWNER);

        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = Bundler.Call({ target: address(0), data: abi.encodePacked(NativeAdapter.withdrawNative.selector) });
        vm.expectRevert(abi.encodeWithSelector(Bundler.CallNotAllowed.selector, 0));
        vm.prank(OPERATOR);
        b.execute(calls);

        calls[0] = Bundler.Call({ target: address(wrapper), data: abi.encodePacked(SwapWrapper.swap.selector) });
        vm.expectRevert(abi.encodeWithSelector(Bundler.CallNotAllowed.selector, 0));
        vm.prank(OPERATOR);
        b.execute(calls);
    }

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

    function test_setOperator_onlyOwner_andRotates() public {
        address next = address(0x0E47);

        vm.expectRevert(abi.encodeWithSelector(OwnableInit.OwnableUnauthorizedAccount.selector, address(this)));
        bundler.setOperator(next, true);

        vm.startPrank(BUNDLER_OWNER);
        bundler.setOperator(next, true);
        bundler.setOperator(OPERATOR, false);
        vm.stopPrank();

        assertTrue(bundler.isOperator(next), "new key enabled");
        assertFalse(bundler.isOperator(OPERATOR), "old key disabled");
    }

    function test_setOperator_rejectsZero() public {
        vm.expectRevert(Bundler.ZeroAddress.selector);
        vm.prank(BUNDLER_OWNER);
        bundler.setOperator(address(0), true);
    }

    function test_strayNativeTransfer_reverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(bundler).call{ value: 1 }("");
        assertFalse(ok, "bundler accepts no native coin");
    }

    /// A target that re-enters `execute` mid-bundle is stopped by the guard, not
    /// by the operator check: it is made an operator here.
    function test_execute_reentrancyBlocked() public {
        Reenterer pool = new Reenterer();
        Bundler b = _createBundler(new BundlerFactory(address(pool), address(0), address(0)), BUNDLER_OWNER);
        pool.setBundler(b);
        vm.prank(BUNDLER_OWNER);
        b.setOperator(address(pool), true);

        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = Bundler.Call({ target: address(pool), data: abi.encodePacked(MASP.transfer.selector) });

        vm.prank(OPERATOR);
        (uint256 executed,) = b.execute(calls);

        assertEq(executed, 1, "the call itself succeeds");
        // Empty calls would revert `EmptyBundle` past the guard; seeing the
        // guard's error proves the nested call never got that far.
        assertEq(
            pool.lastError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "nested execute stopped by the guard"
        );
    }

    /// A payout recipient never gets to run code that could re-enter: it is paid
    /// on the stipend or force-sent.
    function test_execute_payoutRecipientCannotReenter() public {
        Reenterer attacker = new Reenterer();
        attacker.setBundler(bundler);
        vm.prank(BUNDLER_OWNER);
        bundler.setOperator(address(attacker), true);

        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = _withdrawNativeCall(address(attacker), 0x300, 7, _root(1), masp.committedCount());

        vm.prank(OPERATOR);
        (uint256 executed,) = bundler.execute(calls);

        assertEq(executed, 1, "payout succeeds");
        assertGt(address(attacker).balance, 0, "recipient paid");
        assertEq(attacker.lastError().length, 0, "recipient code never ran");
    }

    // --- helpers -----------------------------------------------------------

    /// A Bundler owned by `owner_` and operated by `OPERATOR`.
    function _createBundler(address owner_) internal returns (Bundler) {
        return _createBundler(factory, owner_);
    }

    /// `_createBundler` from another factory.
    function _createBundler(BundlerFactory from, address owner_) internal returns (Bundler) {
        address[] memory operators = new address[](1);
        operators[0] = OPERATOR;
        vm.prank(owner_);
        return from.create(operators);
    }

    /// Gas `execute` uses for `calls`, rolled back.
    function _gasFor(Bundler.Call[] memory calls) internal returns (uint256 used) {
        uint256 snap = vm.snapshotState();
        vm.prank(OPERATOR);
        bundler.execute(calls);
        used = vm.lastCallGas().gasTotalUsed;
        vm.revertToState(snap);
    }

    /// `_gasFor` the first of `calls` alone.
    function _gasForFirst(Bundler.Call[] memory calls) internal returns (uint256) {
        Bundler.Call[] memory first = new Bundler.Call[](1);
        first[0] = calls[0];
        return _gasFor(first);
    }

    /// `execute` from `OPERATOR` with `gasLimit`; `ok` is false if it reverted.
    function _executeWithGas(Bundler b, Bundler.Call[] memory calls, uint256 gasLimit)
        internal
        returns (bool ok, uint256 executed, bytes memory reason)
    {
        vm.prank(OPERATOR);
        bytes memory ret;
        (ok, ret) = address(b).call{ gas: gasLimit }(abi.encodeCall(Bundler.execute, (calls)));
        if (ok) (executed, reason) = abi.decode(ret, (uint256, bytes));
    }

    /// One of each item kind, chained from the live root: flush (2 leaves), then
    /// transfer, withdraw, withdrawNative and swap (6 leaves each).
    function _mixedBundle() internal returns (Bundler.Call[] memory calls, uint256 depositId, uint64 start) {
        depositId = _escrowDeposit();
        start = masp.committedCount();

        calls = new Bundler.Call[](5);
        calls[0] = _flushCall(depositId, masp.currentRoot(), _root(1), start);
        calls[1] = _transferCall(bundler, 0x100, _root(2), start + 2);
        calls[2] = _withdrawCall(bundler, 0x200, 5, _root(3), start + 8);
        calls[3] = _withdrawNativeCall(NATIVE_RECIPIENT, 0x300, 7, _root(4), start + 14);
        calls[4] = _swapCall(bundler, 0x400, _root(5), start + 20);
    }

    function _eventTag(Vm.Log memory l) internal view returns (bytes1) {
        bytes32 sig = l.topics.length == 0 ? bytes32(0) : l.topics[0];
        if (l.emitter == address(masp)) {
            if (sig == MASP.DepositFlushed.selector) return "F";
            if (sig == CommitmentTree.RootAdvanced.selector) return "R";
            if (sig == keccak256("NullifierConsumed(bytes32)")) return "N";
            if (sig == MASP.AssetMoved.selector) return "A";
            if (sig == MASP.NotePayload.selector) return "P";
            if (sig == MASP.DepositEscrowed.selector) return "E";
        } else if (l.emitter == address(nativeAdapter)) {
            if (sig == NativeAdapter.NativeWithdrawn.selector) return "W";
        } else if (l.emitter == address(wrapper)) {
            if (sig == SwapWrapper.SwapExecuted.selector) return "S";
        }
        return 0;
    }

    /// Roots must stay inside the scalar field: `PubInputs.compress` rejects an
    /// out-of-field coefficient.
    function _root(uint256 k) internal pure returns (bytes32) {
        return bytes32(uint256(0xabc000) + k);
    }

    function _emptyProof() internal pure returns (IMASPPool.Proof memory) {
        return IMASPPool.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    /// Spend inputs proving membership against `anchor`, with outputs derived
    /// from `seed`.
    function _transact(
        uint64 assetId,
        uint64 publicOut,
        address recipient,
        address relayer,
        address payer,
        uint256 seed
    ) internal view returns (PubInputs.Transact memory pi) {
        pi.chainId = block.chainid;
        pi.publicAssetId = assetId;
        pi.publicOut = publicOut;
        pi.recipient = recipient;
        pi.relayer = relayer;
        pi.payer = payer;
        SpendFixture.fillOutputs(pi, seed, seed + 0x10);
        pi.merkleRoot = anchor;
    }

    function _transferCall(Bundler boundTo, uint256 seed, bytes32 newRoot, uint64 start)
        internal
        view
        returns (Bundler.Call memory)
    {
        PubInputs.Transact memory pi = _transact(ASSET_A, 0, RECIPIENT, address(boundTo), SPEND_PAYER, seed);
        PubInputs.SpendTree memory tpi = SpendFixture.spendTree(newRoot, start, anchorIndex);
        MASP.Proof memory p = FixtureLoader.emptyProof();
        return Bundler.Call({
            target: address(masp), data: abi.encodeCall(MASP.transfer, (p, pi, p, tpi, SpendFixture.validAux()))
        });
    }

    /// Mints the pool the tokens `publicOut` pays out.
    function _withdrawCall(Bundler boundTo, uint256 seed, uint64 publicOut, bytes32 newRoot, uint64 start)
        internal
        returns (Bundler.Call memory)
    {
        tokenA.mint(address(masp), uint256(publicOut) * SCALE);
        PubInputs.Transact memory pi = _transact(ASSET_A, publicOut, RECIPIENT, address(boundTo), SPEND_PAYER, seed);
        PubInputs.SpendTree memory tpi = SpendFixture.spendTree(newRoot, start, anchorIndex);
        MASP.Proof memory p = FixtureLoader.emptyProof();
        return Bundler.Call({
            target: address(masp), data: abi.encodeCall(MASP.withdraw, (p, pi, p, tpi, SpendFixture.validAux()))
        });
    }

    /// Funds the pool with the wrapped native `publicOut` pays out, unwrapped by
    /// the adapter to `payer`.
    function _withdrawNativeCall(address payer, uint256 seed, uint64 publicOut, bytes32 newRoot, uint64 start)
        internal
        returns (Bundler.Call memory)
    {
        uint256 gross = uint256(publicOut) * SCALE;
        vm.deal(address(this), gross);
        weth.deposit{ value: gross }();
        weth.transfer(address(masp), gross);

        PubInputs.Transact memory pi =
            _transact(ASSET_WETH, publicOut, address(nativeAdapter), address(nativeAdapter), payer, seed);
        PubInputs.SpendTree memory tpi = SpendFixture.spendTree(newRoot, start, anchorIndex);
        IMASPPool.Proof memory p = _emptyProof();
        return Bundler.Call({
            target: address(nativeAdapter),
            data: abi.encodeCall(NativeAdapter.withdrawNative, (p, pi, p, tpi, SpendFixture.validAux()))
        });
    }

    /// A swap of 1000 A for at least 990 B, bound to `boundTo`.
    function _swapCall(Bundler boundTo, uint256 seed, bytes32 newRoot, uint64 start)
        internal
        returns (Bundler.Call memory)
    {
        return _wrapperCall(SwapIntent.bind(_swapArgs(boundTo, seed, newRoot, start)));
    }

    function _wrapperCall(SwapWrapper.SwapArgs memory a) internal view returns (Bundler.Call memory) {
        return Bundler.Call({ target: address(wrapper), data: abi.encodeCall(SwapWrapper.swap, (a)) });
    }

    /// `_swapCall`'s unbound payload, with its venue funded.
    function _swapArgs(Bundler boundTo, uint256 seed, bytes32 newRoot, uint64 start)
        internal
        returns (SwapWrapper.SwapArgs memory a)
    {
        uint64 grossUnits = 1000;
        uint64 minUnits = 990;
        uint256 grossIn = uint256(grossUnits) * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint256 minOut = uint256(minUnits) * SCALE;
        uint256 actualOut = minOut + (minOut * FEE_BPS) / 10_000 + 3 * SCALE;

        tokenA.mint(address(masp), grossIn);
        tokenB.mint(address(swapAdapter), actualOut);
        swapAdapter.setNextActualOut(actualOut);

        a.tokenIn = address(tokenA);
        a.tokenOut = address(tokenB);
        a.amountIn = netIn;
        a.minOut = minOut;
        a.adapter = address(swapAdapter);
        a.route = abi.encode(uint24(500), uint160(0));
        a.deadline = type(uint256).max;

        a.p_w = _emptyProof();
        a.tp_w = _emptyProof();
        a.pi_w = _transact(ASSET_A, grossUnits, address(wrapper), address(wrapper), address(boundTo), seed);
        a.refundTo = SWAP_REFUND_TO;
        a.tpi_w = SpendFixture.spendTree(newRoot, start, anchorIndex);
        a.aux_w = SpendFixture.validAux();

        a.deposit_d.chainId = block.chainid;
        a.deposit_d.publicAssetId = ASSET_B;
        a.deposit_d.publicIn = minUnits;
        a.deposit_d.payer = address(wrapper);
        a.deposit_d.recipient = RECIPIENT;
        a.deposit_d.outCm = bytes32(seed + 0x100);
        a.deposit_d.feeCm = FEE_CM;
        a.aux_d = SpendFixture.validAux()[0];
        a.fee_aux_d = SpendFixture.validAux()[1];

        a.refund_d.chainId = block.chainid;
        a.refund_d.publicAssetId = ASSET_A;
        a.refund_d.publicIn = uint64((uint256(grossUnits) * (10_000 - 2 * uint256(FEE_BPS))) / 10_000);
        a.refund_d.payer = address(wrapper);
        a.refund_d.recipient = RECIPIENT;
        a.refund_d.outCm = bytes32(seed + 0x200);
        a.refund_d.feeCm = FEE_CM;
        a.refund_aux_d = SpendFixture.validAux()[2];
        a.refund_fee_aux_d = SpendFixture.validAux()[3];
    }

    /// Escrows a `DEPOSIT_UNITS` deposit of `DEPOSIT_CM` through Permit2 from the
    /// ERC-1271 payer.
    function _escrowDeposit() internal returns (uint256 id) {
        uint256 inAmt = uint256(DEPOSIT_UNITS) * SCALE;
        tokenA.mint(DEPOSIT_PAYER, inAmt + (inAmt * FEE_BPS) / 10_000);
        vm.prank(DEPOSIT_PAYER);
        tokenA.approve(permit2, type(uint256).max);

        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_A;
        d.publicIn = DEPOSIT_UNITS;
        d.payer = DEPOSIT_PAYER;
        d.recipient = RECIPIENT;
        d.outCm = DEPOSIT_CM;
        d.feeCm = FEE_CM;

        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: 0, deadline: type(uint256).max, maxTotal: type(uint256).max, maxFee: 0, signature: hex"00"
        });
        id = masp.deposit(d, sig, aux[0], aux[1]);
    }

    /// Flushes the deposit `_escrowDeposit` made.
    function _flushCall(uint256 id, bytes32 oldRoot, bytes32 newRoot, uint64 start)
        internal
        view
        returns (Bundler.Call memory)
    {
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = oldRoot;
        tpi.newRoot = newRoot;
        tpi.startIndex = start;
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        tpi.cms[0] = DEPOSIT_CM;
        tpi.cms[1] = FEE_CM;
        tpi.leafAsset[0] = ASSET_A;
        tpi.leafPublicIn[0] = DEPOSIT_UNITS;
        tpi.isDeposit[0] = 1;
        tpi.isDeposit[1] = 1;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: DEPOSIT_PAYER, submittedAt: uint32(block.number), fbps: FEE_BPS });
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        return Bundler.Call({
            target: address(masp), data: abi.encodeCall(MASP.flushBatch, (ids, meta, FixtureLoader.emptyProof(), tpi))
        });
    }
}
