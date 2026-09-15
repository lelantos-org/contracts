// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { FeeConfig } from "../../src/FeeConfig.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { SpendFixture } from "../utils/SpendFixture.sol";
import { TEST_PROXY_ADMIN } from "../utils/PoolDeployer.sol";
import { PoolFixture } from "./PoolFixture.sol";

/// Symbolic proofs for what a guardian pause does and does not stop.
///
/// A guardian pause halts the entry points that verify a proof or accept new
/// funds while an upgrade is reviewed. `MASP` keeps `cancelDeposit` and `sweep`
/// open, because neither verifies a proof and escrowed funds must stay
/// recoverable; a pause that froze cancellation would let the guardian hold
/// depositors' funds for its full duration.
///
/// Proved over every permitted pause duration and every timestamp, since the
/// property concerns a whole time window rather than individual points in it.
///
/// The pool and its mocks come from `PoolFixture`; `setUp` additionally fixes a
/// start time because every proof here reasons about timestamps.
contract MASPPauseSymbolicTest is PoolFixture {
    uint256 internal constant T0 = 1_000_000;
    uint256 internal constant MAX_PAUSE = 7 days;

    function setUp() public override {
        vm.warp(T0);
        super.setUp();
    }

    function _pause(uint256 duration) internal {
        vm.prank(TEST_PROXY_ADMIN);
        DelayedUpgradeProxy(payable(address(masp))).pauseSpends(duration);
    }

    function _deposit(bytes32 cm) internal returns (bool ok, bytes memory ret) {
        AuxValidation.Output[6] memory aux = _aux();
        (ok, ret) = address(masp).call(abi.encodeCall(MASP.depositAuthorized, (_request(cm), aux[0], aux[1])));
    }

    function _transfer() internal returns (bool ok, bytes memory ret) {
        PubInputs.Transact memory pi;
        pi.merkleRoot = EMPTY_ROOT;
        pi.publicAssetId = ASSET_ID;
        pi.recipient = RECIPIENT;
        pi.payer = address(this);
        pi.relayer = address(this);
        pi.chainId = block.chainid;
        SpendFixture.fillOutputs(pi, 0x100, 0x200);
        PubInputs.SpendTree memory tpi = SpendFixture.spendTree(bytes32(uint256(0xbeef)), 0);

        MASP.Proof memory p;
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        (ok, ret) = address(masp).call(abi.encodeCall(MASP.transfer, (p, pi, p, tpi, aux)));
    }

    // --- what a pause stops -------------------------------------------------

    /// Deposits and spends are halted for exactly the pause window and no longer,
    /// at every timestamp and for every permitted duration.
    ///
    /// The upper bound is part of the property: the guardian is limited to a
    /// single pause, and a pause outliving its duration would be an unbounded halt.
    function check_pause_haltsSpendsForExactlyItsWindow(uint40 duration, uint40 t) public {
        vm.assume(duration > 0 && uint256(duration) <= MAX_PAUSE);
        _pause(duration);

        uint256 pausedUntil = T0 + uint256(duration);
        vm.assume(t >= T0);
        vm.warp(t);

        (bool deposited, bytes memory depositRet) = _deposit(bytes32(uint256(0xdead)));
        (bool transferred, bytes memory transferRet) = _transfer();

        if (uint256(t) < pausedUntil) {
            _assertRejected(deposited, depositRet, MASP.SpendsPaused.selector, "deposit halted");
            _assertRejected(transferred, transferRet, MASP.SpendsPaused.selector, "spend halted");
        } else {
            assertTrue(deposited, "deposit resumes when the window closes");
            // The spend still fails validation (the fixture carries no real
            // proof), but not with `SpendsPaused`.
            assertTrue(bytes4(transferRet) != MASP.SpendsPaused.selector, "spend no longer halted");
        }
    }

    // --- what a pause must not stop -----------------------------------------

    /// An escrowed deposit stays cancellable throughout a pause, for every
    /// duration and every point inside the window.
    ///
    /// Recoverability guarantee: `cancelDeposit` verifies no proof, so halting it
    /// protects nothing and would let a guardian hold depositors' funds for the
    /// pause's full length.
    function check_pause_leavesEscrowRecoverable(bytes32 cm, uint40 duration, uint40 t) public {
        uint256 id = _submit(cm);

        vm.assume(duration > 0 && uint256(duration) <= MAX_PAUSE);
        _pause(duration);

        // Anywhere inside the pause window.
        vm.assume(t >= T0 && uint256(t) < T0 + uint256(duration));
        vm.warp(t);
        vm.roll(block.number + masp.cancelDelay());

        assertTrue(_cancelSubmitted(id, cm), "cancel stays open while spends are paused");
        assertEq(masp.escrowed(id), bytes32(0), "escrow settled");
    }

    /// Sweeping accrued fees to the treasury stays open during a pause: it
    /// verifies no proof and moves only fees already accrued.
    function check_pause_leavesSweepOpen(uint40 duration, uint40 t) public {
        vm.assume(duration > 0 && uint256(duration) <= MAX_PAUSE);
        _pause(duration);

        vm.assume(t >= T0 && uint256(t) < T0 + uint256(duration));
        vm.warp(t);

        (bool ok,) = address(masp).call(abi.encodeCall(FeeConfig.sweep, (IERC20(address(token)))));
        assertTrue(ok, "sweep stays open while spends are paused");
    }
}
