// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";

import { NativeAdapterTestBase } from "./NativeAdapterTestBase.sol";

/// `NativeAdapter` wrap-on-deposit, native receipt and Permit2 arming. Fixture
/// and helpers in `NativeAdapterTestBase`; cancel and withdraw in
/// `NativeAdapter.cancel.t.sol` and `NativeAdapter.withdraw.t.sol`.
contract NativeAdapterTest is NativeAdapterTestBase {
    // --- deposit -----------------------------------------------------------

    function test_depositNative_wrapsAndEscrows() public {
        uint64 publicIn = 3;
        uint256 total = _total(publicIn);

        uint256 id = _deposit(DEPOSITOR, publicIn, total);

        assertEq(id, 0, "first deposit id");
        assertEq(weth.balanceOf(address(masp)), total, "pool holds the wrapped escrow");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter keeps no wrapped dust");
        assertEq(address(adapter).balance, 0, "adapter keeps no native dust");
        assertEq(DEPOSITOR.balance, 0, "depositor paid exactly the escrow total");
        (address refundTo, uint256 amount) = adapter.escrows(id);
        assertEq(refundTo, DEPOSITOR, "refund bound to the funder");
        assertEq(amount, total, "record holds the pulled amount");
    }

    /// The caller may overpay instead of replicating MASP's fee math; the
    /// surplus is returned as native coin, not WETH.
    function test_depositNative_returnsExcess() public {
        uint64 publicIn = 3;
        uint256 total = _total(publicIn);
        uint256 excess = 1 ether;

        uint256 id = _deposit(DEPOSITOR, publicIn, total + excess);

        assertEq(DEPOSITOR.balance, excess, "excess refunded as native");
        assertEq(weth.balanceOf(DEPOSITOR), 0, "no wrapped coin left with the depositor");
        assertEq(weth.balanceOf(address(masp)), total, "pool pulled only the escrow total");
        (, uint256 amount) = adapter.escrows(id);
        assertEq(amount, total, "record excludes the refunded excess");
    }

    function test_depositNative_emitsNativeDeposited() public {
        uint64 publicIn = 3;
        uint256 total = _total(publicIn);
        vm.deal(DEPOSITOR, total + 5);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit NativeAdapter.NativeDeposited(0, DEPOSITOR, total, 5);

        vm.prank(DEPOSITOR);
        adapter.depositNative{ value: total + 5 }(
            _request(ASSET_WETH, publicIn), SpendFixture.validAuxOutput(), SpendFixture.validAuxOutput()
        );
    }

    function test_depositNative_revert_ZeroValue() public {
        vm.prank(DEPOSITOR);
        vm.expectRevert(NativeAdapter.ZeroValue.selector);
        adapter.depositNative{ value: 0 }(
            _request(ASSET_WETH, 1), SpendFixture.validAuxOutput(), SpendFixture.validAuxOutput()
        );
    }

    /// The adapter must be `payer`: it is the only address whose Permit2
    /// allowance the pool can pull against.
    function test_depositNative_revert_AdapterNotPayer() public {
        PubInputs.DepositRequest memory d = _request(ASSET_WETH, 1);
        d.payer = DEPOSITOR;
        vm.deal(DEPOSITOR, 1 ether);
        vm.prank(DEPOSITOR);
        vm.expectRevert(NativeAdapter.AdapterNotPayer.selector);
        adapter.depositNative{ value: 1 ether }(d, SpendFixture.validAuxOutput(), SpendFixture.validAuxOutput());
    }

    /// A non-wrapped-native asset id cannot spend the wrapped coin: the adapter
    /// holds no such token, so the pool's Permit2 pull reverts.
    function test_depositNative_revert_wrongAsset() public {
        vm.deal(DEPOSITOR, 1 ether);
        vm.prank(DEPOSITOR);
        vm.expectRevert();
        adapter.depositNative{ value: 1 ether }(
            _request(ASSET_ERC20, 1), SpendFixture.validAuxOutput(), SpendFixture.validAuxOutput()
        );
    }

    // --- misc --------------------------------------------------------------

    /// Raw native is accepted only from the wrapped-native contract (the unwrap leg).
    function test_receive_rejectsNonWrappedNativeSender() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory data) = address(adapter).call{ value: 1 }("");
        assertFalse(ok, "raw native transfer must revert");
        bytes4 sel;
        assembly {
            sel := mload(add(data, 32))
        }
        assertEq(sel, NativeAdapter.UnauthorizedNativeSender.selector);
    }

    function test_arm_isIdempotent() public {
        adapter.arm();
        (uint160 amount, uint48 expiration,) =
            IAllowanceTransfer(permit2).allowance(address(adapter), address(weth), address(masp));
        assertEq(amount, type(uint160).max, "permit2 allowance re-armed");
        assertEq(expiration, type(uint48).max, "allowance never expires");
    }

    /// MASP does not accept raw native.
    function test_pool_rejectsRawNative() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(masp).call{ value: 1 }("");
        assertFalse(ok, "pool must not accept native");
    }
}
