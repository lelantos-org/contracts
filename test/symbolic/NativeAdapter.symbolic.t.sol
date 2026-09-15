// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { GuardAsserts } from "./GuardAsserts.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { MockAllowanceTransfer } from "./mocks/MockAllowanceTransfer.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { deployMockedPool, PoolConstants } from "./PoolFixture.sol";

/// Symbolic proofs for the native adapter's authorization boundary.
///
/// The adapter is ownerless and permissionless: its authority comes from SNARK
/// public inputs or its own escrow bookkeeping. Its identity checks are therefore
/// its entire access control:
///
/// - `d.payer` must be the adapter, since the pool pulls against the adapter's
///   Permit2 allowance rather than the caller's;
/// - `pi.recipient` and `pi.relayer` must be the adapter on the withdraw leg,
///   or the pool would send proceeds where the adapter cannot unwrap them;
/// - only the wrapped-native contract may send raw coin in.
///
/// Every proof is a rejection pinned to its selector, and each reverts before
/// the adapter calls the pool, so no spend path is reached.
///
/// This does not extend `PoolFixture`: the pool is denominated in wrapped native
/// rather than a plain ERC-20, and the escrow helpers do not apply. Pool wiring
/// and constants are shared through `deployMockedPool`.
contract NativeAdapterSymbolicTest is GuardAsserts {
    uint64 internal constant ASSET_ID = PoolConstants.ASSET_ID;
    address internal constant TREASURY = PoolConstants.TREASURY;
    address internal constant OWNER = PoolConstants.OWNER;

    MASP internal masp;
    MockWETH9 internal weth;
    NativeAdapter internal adapter;

    function setUp() public {
        weth = new MockWETH9();
        MockAllowanceTransfer permit2 = new MockAllowanceTransfer();
        masp = deployMockedPool(IERC20(address(weth)), 0, address(permit2), TREASURY, OWNER);
        adapter = new NativeAdapter(
            IMASPPool(address(masp)), IWrappedNative(address(weth)), IAllowanceTransfer(address(permit2))
        );
    }

    function _request(address payer) internal view returns (PubInputs.DepositRequest memory d) {
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = 1;
        d.payer = payer;
        d.recipient = address(0xb0b);
        d.outCm = bytes32(uint256(0xdead));
        d.cvDep = [uint256(0x11), uint256(0x22)];
        d.feeIn = 0;
        d.feeCm = bytes32(uint256(0xfee5));
        d.feeCvDep = [uint256(0x33), uint256(0x44)];
    }

    function _depositNative(address payer, uint256 value) internal returns (bool ok, bytes memory ret) {
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        (ok, ret) = address(adapter).call{ value: value }(
            abi.encodeCall(NativeAdapter.depositNative, (_request(payer), aux[0], aux[1]))
        );
    }

    function _withdrawNative(address recipient, address relayer) internal returns (bool ok, bytes memory ret) {
        PubInputs.Transact memory pi;
        pi.publicAssetId = ASSET_ID;
        pi.recipient = recipient;
        pi.relayer = relayer;
        pi.payer = address(0xb0b);
        pi.chainId = block.chainid;
        pi.publicOut = 1;
        SpendFixture.fillOutputs(pi, 0x100, 0x200);
        PubInputs.SpendTree memory tpi = SpendFixture.spendTree(bytes32(uint256(0xbeef)), 0);

        IMASPPool.Proof memory p;
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        (ok, ret) = address(adapter).call(abi.encodeCall(NativeAdapter.withdrawNative, (p, pi, p, tpi, aux)));
    }

    // --- deposit leg --------------------------------------------------------

    /// The escrow is opened in the adapter's name, so a request naming any other
    /// payer is refused.
    ///
    /// The pool pulls against the adapter's Permit2 allowance, which covers the
    /// adapter's whole balance. A request naming a different payer while spending
    /// that allowance would escrow coin held for other depositors' refunds.
    function check_depositNative_rejectsAnyPayerButTheAdapter(address payer) public {
        vm.assume(payer != address(adapter));
        vm.deal(address(this), 1 ether);

        (bool ok, bytes memory ret) = _depositNative(payer, 1);

        _assertRejected(ok, ret, NativeAdapter.AdapterNotPayer.selector);
    }

    /// A deposit carrying no coin is refused, so no unfunded escrow is opened.
    function check_depositNative_rejectsZeroValue() public {
        (bool ok, bytes memory ret) = _depositNative(address(adapter), 0);

        _assertRejected(ok, ret, NativeAdapter.ZeroValue.selector);
    }

    // --- withdraw leg -------------------------------------------------------

    /// The proof must name the adapter as recipient: the pool sends wrapped coin
    /// to `pi.recipient`, and the adapter can only unwrap what it receives.
    function check_withdrawNative_rejectsAnyRecipientButTheAdapter(address recipient) public {
        vm.assume(recipient != address(adapter));

        (bool ok, bytes memory ret) = _withdrawNative(recipient, address(adapter));

        _assertRejected(ok, ret, NativeAdapter.AdapterNotRecipient.selector);
    }

    /// The proof must name the adapter as relayer, since the pool requires
    /// `relayer == msg.sender` and the adapter is the caller. The local check
    /// reports `AdapterNotRelayer` instead of the pool's `BadRelayer`.
    function check_withdrawNative_rejectsAnyRelayerButTheAdapter(address relayer) public {
        vm.assume(relayer != address(adapter));

        (bool ok, bytes memory ret) = _withdrawNative(address(adapter), relayer);

        _assertRejected(ok, ret, NativeAdapter.AdapterNotRelayer.selector);
    }

    // --- raw coin -----------------------------------------------------------

    /// Raw coin from every sender other than the wrapped-native contract is
    /// refused.
    ///
    /// Refund accounting uses wrapped balance deltas, and native coin is held only
    /// transiently between an unwrap and a forward. Coin arriving by any other
    /// route would not be attributed to any escrow.
    function check_receive_rejectsEverySenderButWrappedNative(address sender, uint256 amount) public {
        vm.assume(sender != address(weth));
        vm.assume(amount > 0 && amount <= 1 ether);
        vm.deal(sender, amount);

        // Compared as a delta, not against zero: halmos initialises balances
        // symbolically, and coin can always be forced in (e.g. selfdestruct).
        // The property is that a refused transfer leaves the balance unchanged.
        uint256 balanceBefore = address(adapter).balance;

        vm.prank(sender);
        (bool ok, bytes memory ret) = address(adapter).call{ value: amount }("");

        _assertRejected(ok, ret, NativeAdapter.UnauthorizedNativeSender.selector);
        assertEq(address(adapter).balance, balanceBefore, "refused coin is not retained");
    }
}
