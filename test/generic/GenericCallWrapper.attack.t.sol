// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";

import { GenericCallTestBase } from "./GenericCallTestBase.sol";
import { MockDrainer, MockReentrant, MockDonor } from "./mocks/MockCallTargets.sol";

/// Adversarial calls. Each models a threat from the design review: approvals
/// left behind for a later user (S1), calls reaching the wrapper's own
/// privileges (S2), and balances forced onto the executor or the wrapper (S5).
contract GenericCallWrapperAttackTest is GenericCallTestBase {
    MockDrainer internal drainer;
    MockReentrant internal reentrant;
    MockDonor internal donor;

    function setUp() public override {
        super.setUp();
        drainer = new MockDrainer();
        reentrant = new MockReentrant();
        donor = new MockDonor();
    }

    /// S1. An attacker's execution approves a spender from its executor. A later
    /// execution runs in a new clone, so that approval does not reach its funds:
    /// the drain fails and the victim is refunded in full.
    function test_S1_staleApprovalDoesNotReachNextExecution() public {
        _fundWithdraw();
        address attackerExec = _nextExecutor();
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.calls = _append(
            a.calls, _call(address(tokenB), abi.encodeCall(IERC20.approve, (address(drainer), type(uint256).max)))
        );
        _execute(a);
        assertEq(tokenB.allowance(attackerExec, address(drainer)), type(uint256).max, "approval left behind");

        _fundWithdraw();
        address victimExec = _nextExecutor();
        assertTrue(victimExec != attackerExec, "fresh clone");
        GenericCallWrapper.GenericArgs memory v = _swapArgs(990, _pull(990));
        // Stands in for a hook or callback that hands control to the spender.
        v.calls = _append(
            v.calls, _call(address(drainer), abi.encodeCall(MockDrainer.drain, (IERC20(address(tokenB)), victimExec)))
        );

        bytes4 reason = _executeExpectRefund(v);
        assertEq(reason, IERC20Errors.ERC20InsufficientAllowance.selector, "no allowance on the new clone");
        assertEq(tokenB.balanceOf(address(drainer)), 0, "nothing drained");
    }

    /// S2. A call re-entering `cancelEscrow` through a contract hits the shared
    /// guard, so the calls cannot settle the wrapper's escrows mid-execution.
    function test_S2_reentryIntoCancelEscrow_refunds() public {
        _fundWithdraw();
        uint256[] memory ids = _execute(_swapArgs(990, _pull(990)));

        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _oneCall(_call(address(reentrant), abi.encodeCall(MockReentrant.cancel, (wrapper, ids[0], ASSET_B))));
        a.outputs = _oneOutput(_output(ASSET_B, 1));

        bytes4 reason = _executeExpectRefund(a);
        assertEq(reason, ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector, "guarded");
        (address refundTo,) = wrapper.escrows(ids[0]);
        assertEq(refundTo, REFUND_TO, "escrow untouched");
    }

    /// S2. The pool accepts a contract payer's cancel only from the payer, and
    /// the calls never run as the wrapper.
    function test_S2_cancelOnPoolAsWrapper_refused() public {
        _fundWithdraw();
        uint256[] memory ids = _execute(_swapArgs(990, _pull(990)));

        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _base();
        a.calls = _oneCall(
            _call(
                address(reentrant),
                abi.encodeCall(MockReentrant.cancelOnPool, (pool, address(wrapper), ids[0], ASSET_B))
            )
        );
        a.outputs = _oneOutput(_output(ASSET_B, 1));

        _executeExpectRefund(a);
        assertGt(pool.escrowTotal(ids[0]), 0, "escrow still pending");
    }

    /// S2. The executor holds no Permit2 allowance, so a call through Permit2
    /// cannot move the wrapper's balance either: the wrapper's allowance is
    /// keyed to the wrapper as owner and the pool as spender.
    function test_S2_permit2FromExecutor_cannotMoveWrapperFunds() public {
        tokenB.mint(address(wrapper), 100 * SCALE);
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.calls = _append(
            a.calls,
            _call(
                address(permit2),
                abi.encodeWithSignature(
                    "transferFrom(address,address,uint160,address)",
                    address(wrapper),
                    address(drainer),
                    uint160(100 * SCALE),
                    address(tokenB)
                )
            )
        );

        _executeExpectRefund(a);
        assertEq(tokenB.balanceOf(address(wrapper)), 100 * SCALE, "stuck balance intact");
    }

    /// S5. Tokens and native coin sent to the next clone's address before it
    /// exists cannot force a refund: they are swept to `surplusTo`.
    function test_S5_prefundedExecutor_lands() public {
        _fundWithdraw();
        address next = _nextExecutor();
        tokenB.mint(next, 5);
        vm.deal(next, 1 ether);

        vm.recordLogs();
        _execute(_swapArgs(990, _pull(990)));
        assertEq(_executorOf(vm.getRecordedLogs()), next, "predicted clone");

        assertEq(tokenB.balanceOf(SURPLUS_TO), 5, "donated tokens to surplus");
        assertEq(SURPLUS_TO.balance, 1 ether, "forced native to surplus");
    }

    /// S5. A donation to the wrapper during the calls raises what is delivered
    /// and leaves as surplus; the leftover check still holds.
    function test_S5_donationToWrapperMidExecution() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.calls = _append(
            a.calls, _call(address(donor), abi.encodeCall(MockDonor.donate, (address(tokenB), address(wrapper), 11)))
        );

        _execute(a);
        assertEq(tokenB.balanceOf(SURPLUS_TO), 11, "donation to surplus");
        assertEq(tokenB.balanceOf(address(wrapper)), 0, "nothing left");
    }

    /// A balance stuck on the wrapper is out of reach of an oversized note: the
    /// pool's pull is bounded by what the calls delivered.
    function test_stuckBalance_notEscrowedByOversizedNote() public {
        tokenB.mint(address(wrapper), 500 * SCALE);
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _swapArgs(10, _pull(10));
        // Floor of 10 units, but a note of 400: the pull would exceed delivery.
        a.outputs[0].deposit.publicIn = 400;

        vm.expectPartialRevert(MaspEscrowSatellite.PullExceedsMax.selector);
        _execute(a);
        assertEq(tokenB.balanceOf(address(wrapper)), 500 * SCALE, "stuck balance intact");
    }

    /// A re-entrant `prepareToken` is harmless: it only re-arms approvals the
    /// wrapper already grants to the pool.
    function test_reentrantPrepareToken_harmless() public {
        _fundWithdraw();
        GenericCallWrapper.GenericArgs memory a = _swapArgs(990, _pull(990));
        a.calls = _append(
            a.calls,
            _call(address(reentrant), abi.encodeCall(MockReentrant.prepare, (wrapper, IERC20(address(tokenB)))))
        );

        _execute(a);
        assertEq(tokenB.balanceOf(address(pool)), _pull(990), "landed");
    }
}
