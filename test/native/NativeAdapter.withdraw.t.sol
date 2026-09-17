// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { GasBurner } from "../mocks/GasBurner.sol";
import { NativeRejector, NativeStateWriter, NativeAcceptor } from "../mocks/NativeReceivers.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";

import { NativeAdapterTestBase } from "./NativeAdapterTestBase.sol";

/// `NativeAdapter` unwrap-on-withdraw: payout to the proof's payer, recipient
/// and relayer binding, and force-send to payers that cannot take the push.
/// Fixture and helpers in `NativeAdapterTestBase`.
contract NativeAdapterWithdrawTest is NativeAdapterTestBase {
    // --- withdraw ----------------------------------------------------------

    /// Funds the pool with WETH so an unshield has backing.
    function _armWithdraw(uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{ value: amount }();
        weth.transfer(address(masp), amount);
        _mockVerifiers();
    }

    function test_withdrawNative_unwrapsToProofPayer() public {
        uint64 publicOut = 7;
        uint256 gross = uint256(publicOut) * SCALE;
        uint256 fee = (gross * FEE_BPS) / 10_000;
        uint256 net = gross - fee;
        _armWithdraw(gross);

        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, publicOut);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit NativeAdapter.NativeWithdrawn(DEPOSITOR, net);

        // Permissionless: a relayer that is not the payer may submit.
        vm.prank(address(0xCA11));
        uint256 paid = adapter.withdrawNative(
            FixtureLoader.emptyPoolProof(), pi, FixtureLoader.emptyPoolProof(), _tpi(pi), SpendFixture.validAux()
        );

        assertEq(paid, net, "returned net matches");
        assertEq(DEPOSITOR.balance, net, "payer paid in raw native");
        assertEq(weth.balanceOf(DEPOSITOR), 0, "payer holds no wrapped coin");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter keeps nothing");
        assertEq(address(adapter).balance, 0, "adapter holds no native");
        assertEq(masp.accruedFee(IERC20(address(weth))), fee, "fee stays wrapped in the pool");
    }

    /// Wrapped coin already held by the adapter is neither counted in the
    /// unshield measurement nor spent by it, because the payout is measured by
    /// balance delta.
    function test_withdrawNative_ignoresPreExistingBalance() public {
        uint256 parked = 4 ether;
        weth.mint(address(adapter), parked);

        uint64 publicOut = 7;
        uint256 gross = uint256(publicOut) * SCALE;
        uint256 net = gross - (gross * FEE_BPS) / 10_000;
        _armWithdraw(gross);

        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, publicOut);
        adapter.withdrawNative(
            FixtureLoader.emptyPoolProof(), pi, FixtureLoader.emptyPoolProof(), _tpi(pi), SpendFixture.validAux()
        );

        assertEq(DEPOSITOR.balance, net, "only the unshield net was forwarded");
        assertEq(weth.balanceOf(address(adapter)), parked, "pre-existing balance untouched");
    }

    /// The pool call forwards this call's argument bytes, so a pool revert
    /// surfaces unchanged; here, a wrong anchor slot.
    function test_withdrawNative_bubblesPoolRevert() public {
        _armWithdraw(7 * SCALE);
        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, 7);
        PubInputs.SpendTree memory tpi = _tpi(pi);
        tpi.anchorIndex = 9;
        vm.expectRevert(MASP.UnknownRoot.selector);
        adapter.withdrawNative(
            FixtureLoader.emptyPoolProof(), pi, FixtureLoader.emptyPoolProof(), tpi, SpendFixture.validAux()
        );
    }

    /// Bytes past the ABI encoding are forwarded to the pool, whose decoder
    /// ignores them as the adapter's does.
    function test_withdrawNative_trailingCalldata_forwarded() public {
        uint64 publicOut = 7;
        uint256 gross = uint256(publicOut) * SCALE;
        _armWithdraw(gross);
        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, publicOut);
        bytes memory cd = bytes.concat(
            abi.encodeCall(
                NativeAdapter.withdrawNative,
                (FixtureLoader.emptyPoolProof(), pi, FixtureLoader.emptyPoolProof(), _tpi(pi), SpendFixture.validAux())
            ),
            hex"deadbeef"
        );
        (bool ok,) = address(adapter).call(cd);
        assertTrue(ok, "withdraw landed");
        assertEq(DEPOSITOR.balance, gross - (gross * FEE_BPS) / 10_000, "payer paid");
    }

    function test_withdrawNative_revert_AdapterNotRecipient() public {
        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, 1);
        pi.recipient = DEPOSITOR;
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.expectRevert(NativeAdapter.AdapterNotRecipient.selector);
        adapter.withdrawNative(
            FixtureLoader.emptyPoolProof(), pi, FixtureLoader.emptyPoolProof(), tpi, SpendFixture.validAux()
        );
    }

    function test_withdrawNative_revert_AdapterNotRelayer() public {
        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, 1);
        pi.relayer = address(0xCA11);
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.expectRevert(NativeAdapter.AdapterNotRelayer.selector);
        adapter.withdrawNative(
            FixtureLoader.emptyPoolProof(), pi, FixtureLoader.emptyPoolProof(), tpi, SpendFixture.validAux()
        );
    }

    /// An unshield of a non-wrapped-native asset would strand an ERC-20 here;
    /// the zero wrapped-delta check reverts the whole spend instead.
    function test_withdrawNative_revert_NothingUnshielded() public {
        uint64 publicOut = 7;
        token.mint(address(masp), uint256(publicOut) * SCALE);
        _mockVerifiers();

        PubInputs.Transact memory pi = _transactPi(ASSET_ERC20, publicOut);
        PubInputs.SpendTree memory tpi = _tpi(pi);
        vm.expectRevert(NativeAdapter.NothingUnshielded.selector);
        adapter.withdrawNative(
            FixtureLoader.emptyPoolProof(), pi, FixtureLoader.emptyPoolProof(), tpi, SpendFixture.validAux()
        );
    }

    /// A payer that rejects the push, burns gas, or writes state in `receive`
    /// is paid in full, without its code running and without failing the spend.
    /// Inside a bundle, a failing payout would otherwise fail the items after it.
    function test_withdrawNative_rejectingPayer_forceSent() public {
        _assertForceSent(address(new NativeRejector()));
    }

    function test_withdrawNative_gasBurningPayer_forceSent() public {
        _assertForceSent(address(new GasBurner()));
    }

    function test_withdrawNative_stateWritingPayer_forceSent() public {
        NativeStateWriter payer = new NativeStateWriter();
        _assertForceSent(address(payer));
        assertEq(payer.received(), 0, "payer code never wrote state");
    }

    function _assertForceSent(address payer) internal {
        uint64 publicOut = 7;
        uint256 gross = uint256(publicOut) * SCALE;
        uint256 net = gross - (gross * FEE_BPS) / 10_000;
        _armWithdraw(gross);

        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, publicOut);
        pi.payer = payer;

        vm.expectEmit(true, true, true, true, address(adapter));
        emit NativeAdapter.NativeForceSent(payer, net);
        uint256 paid = adapter.withdrawNative(
            FixtureLoader.emptyPoolProof(), pi, FixtureLoader.emptyPoolProof(), _tpi(pi), SpendFixture.validAux()
        );

        assertEq(paid, net, "returned net matches");
        assertEq(payer.balance, net, "payer paid in raw native");
        assertEq(address(adapter).balance, 0, "adapter holds no native");
    }

    /// A payer that takes the push on the stipend is paid directly, with no
    /// force-send.
    function test_withdrawNative_stipendPayer_notForceSent() public {
        uint64 publicOut = 7;
        _armWithdraw(uint256(publicOut) * SCALE);
        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, publicOut);
        pi.payer = address(new NativeAcceptor());

        vm.recordLogs();
        adapter.withdrawNative(
            FixtureLoader.emptyPoolProof(), pi, FixtureLoader.emptyPoolProof(), _tpi(pi), SpendFixture.validAux()
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != NativeAdapter.NativeForceSent.selector, "no force-send");
        }
        assertGt(pi.payer.balance, 0, "payer paid");
    }
}
