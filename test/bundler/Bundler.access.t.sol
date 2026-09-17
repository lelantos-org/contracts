// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MASP } from "../../src/MASP.sol";
import { Bundler } from "../../src/bundler/Bundler.sol";
import { BundlerFactory } from "../../src/bundler/BundlerFactory.sol";
import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { OwnableInit } from "../../src/OwnableInit.sol";
import { Reenterer } from "../mocks/BundlerAttackers.sol";

import { BundlerTestBase } from "./BundlerTestBase.sol";

/// `Bundler` access control and call validation: operator gating, the target
/// and selector allowlist, operator rotation, stray native, and reentrancy.
/// Fixture and call builders in `BundlerTestBase`.
contract BundlerAccessTest is BundlerTestBase {
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
        address[7] memory targets = [
            address(masp),
            address(masp),
            address(nativeAdapter),
            address(wrapper),
            address(masp),
            address(generic),
            address(generic)
        ];
        bytes4[7] memory selectors = [
            NativeAdapter.withdrawNative.selector,
            SwapWrapper.swap.selector,
            MASP.withdraw.selector,
            MASP.transfer.selector,
            GenericCallWrapper.execute.selector,
            SwapWrapper.swap.selector,
            // Escrow recovery is not a tree-advancing entry point.
            GenericCallWrapper.cancelEscrow.selector
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
        assertEq(bundler.GENERIC_CALL_WRAPPER(), address(generic), "generic call wrapper");
    }

    /// `GenericCallWrapper.execute` passes `_decode`: a malformed payload reaches
    /// the wrapper and fails there, reported as a failed item rather than
    /// refused up front.
    function test_execute_genericCallWrapper_admitted() public {
        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] =
            Bundler.Call({ target: address(generic), data: abi.encodePacked(GenericCallWrapper.execute.selector) });
        vm.prank(OPERATOR);
        (uint256 executed,) = bundler.execute(calls);
        assertEq(executed, 0, "reached the wrapper and failed there");
    }

    /// A chain without the adapters leaves those slots zero. Zero is never a
    /// target, and the deployed adapters are not either.
    function test_absentAdapters_notCallable() public {
        Bundler b = _createBundler(new BundlerFactory(address(masp), address(0), address(0), address(0)), BUNDLER_OWNER);

        Bundler.Call[] memory calls = new Bundler.Call[](1);
        calls[0] = Bundler.Call({ target: address(0), data: abi.encodePacked(NativeAdapter.withdrawNative.selector) });
        vm.expectRevert(abi.encodeWithSelector(Bundler.CallNotAllowed.selector, 0));
        vm.prank(OPERATOR);
        b.execute(calls);

        calls[0] = Bundler.Call({ target: address(wrapper), data: abi.encodePacked(SwapWrapper.swap.selector) });
        vm.expectRevert(abi.encodeWithSelector(Bundler.CallNotAllowed.selector, 0));
        vm.prank(OPERATOR);
        b.execute(calls);

        calls[0] =
            Bundler.Call({ target: address(generic), data: abi.encodePacked(GenericCallWrapper.execute.selector) });
        vm.expectRevert(abi.encodeWithSelector(Bundler.CallNotAllowed.selector, 0));
        vm.prank(OPERATOR);
        b.execute(calls);
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
        Bundler b = _createBundler(new BundlerFactory(address(pool), address(0), address(0), address(0)), BUNDLER_OWNER);
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
}
