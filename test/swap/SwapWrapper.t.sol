// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { IMASPSwap } from "../../src/swap/IMASPSwap.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockSwapAdapter } from "./mocks/MockSwapAdapter.sol";
import { MockMASPSwap } from "./mocks/MockMASPSwap.sol";

/// Unit tests for `SwapWrapper`. Uses a stub MASP and stub adapter so
/// the orchestration logic can be exercised without real Groth16 proofs.
/// Real-MASP integration is covered by an upcoming end-to-end test
/// against deployed contracts on a fork.
contract SwapWrapperTest is Test {
    uint64 internal constant ASSET_A = 1;
    uint64 internal constant ASSET_B = 2;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant OWNER = address(0xC0FFEE);
    address internal constant TREASURY = address(0xFEE);

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    IAllowanceTransfer internal permit2;
    MockMASPSwap internal pool;
    MockSwapAdapter internal adapter;
    SwapWrapper internal wrapper;

    function setUp() public {
        permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        pool = new MockMASPSwap(permit2);
        pool.registerAsset(ASSET_A, address(tokenA), SCALE);
        pool.registerAsset(ASSET_B, address(tokenB), SCALE);
        pool.setFeeBps(FEE_BPS);

        adapter = new MockSwapAdapter();
        wrapper = new SwapWrapper(pool, permit2, OWNER, TREASURY);

        vm.prank(OWNER);
        wrapper.setAdapterAllowed(address(adapter), true);

        wrapper.prepareToken(IERC20(address(tokenB)));
    }

    // -------- helpers ---------------------------------------------------

    function _mintToPool(uint256 amt) internal {
        tokenA.mint(address(pool), amt);
    }

    function _fundAdapter(uint256 amt) internal {
        tokenB.mint(address(adapter), amt);
    }

    function _emptyProof() internal pure returns (IMASPSwap.Proof memory) {
        return IMASPSwap.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    function _emptyTpi() internal pure returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = bytes32(0);
        tpi.newRoot = bytes32(0);
    }

    function _emptyAux() internal pure returns (AuxValidation.Output[2] memory aux) {
        // Default-zero AuxValidation.Output. ciphertext bytes default to empty.
    }

    function _piWithdraw(uint64 publicOut, address recipient) internal view returns (PubInputs.Transact memory pi) {
        pi.publicAssetId = ASSET_A;
        pi.publicOut = publicOut;
        pi.recipient = recipient;
        pi.relayer = recipient;
        // Names the address authorized to drive the swap (see
        // SwapWrapper.UnauthorizedSwapCaller). Tests call as themselves.
        pi.payer = address(this);
    }

    function _intent(uint64 publicIn, address payer) internal view returns (PubInputs.DepositIntent memory d) {
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_B;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = address(0xBEEF);
        d.outCm[0] = bytes32(uint256(1));
        d.outCm[1] = bytes32(uint256(2));
    }

    function _args(
        uint256 amountIn,
        uint256 minOut,
        uint64 piOut,
        uint64 intentIn,
        address adapter_,
        address recipient,
        address payer
    ) internal view returns (SwapWrapper.SwapArgs memory a) {
        a.p_w = _emptyProof();
        a.tp_w = _emptyProof();
        a.pi_w = _piWithdraw(piOut, recipient);
        a.tpi_w = _emptyTpi();
        a.aux_w = _emptyAux();
        a.intent_d = _intent(intentIn, payer);
        a.aux_d = _emptyAux();
        a.adapter = adapter_;
        a.route = abi.encode(uint24(500), uint160(0));
        a.deadline = type(uint256).max;
        a.tokenIn = address(tokenA);
        a.tokenOut = address(tokenB);
        a.amountIn = amountIn;
        a.minOut = minOut;
    }

    // -------- happy path -----------------------------------------------

    function testHappyPathForwardsDustToTreasury() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 feeOnA = (grossIn * FEE_BPS) / 10_000;
        uint256 netIn = grossIn - feeOnA; // what MASP.withdraw actually delivers
        uint64 minPublicIn = 990; // minOut = 990 * SCALE
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 expectedFeeOnB = (minOut * FEE_BPS) / 10_000;
        // Real venues deliver gross output; wrapper computes the dust
        // (gross - MASP pull) on its own via balance delta. Size venue
        // output to cover MASP's fee-on-publicIn pull plus a 7-unit
        // surplus that ends up in the treasury.
        uint256 expectedDust = 7 * SCALE;
        uint256 actualOut = minOut + expectedFeeOnB + expectedDust;

        _mintToPool(grossIn);
        _fundAdapter(actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            intentIn: minPublicIn,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });

        (uint256 ret, uint256 intentId) = wrapper.swap(a);
        assertEq(ret, actualOut, "actualOut mismatch");
        assertEq(intentId, 0, "intent id");

        assertEq(tokenB.balanceOf(TREASURY), expectedDust, "dust to treasury");
        assertEq(tokenB.balanceOf(address(wrapper)), 0, "wrapper holds no B");
        assertEq(tokenA.balanceOf(address(wrapper)), 0, "wrapper holds no A");
        // Wrapper swapped the net receipt; pool kept the withdraw fee and the
        // adapter received exactly the net (not the gross `publicOut*scale`).
        assertEq(tokenA.balanceOf(address(pool)), feeOnA, "pool retained withdraw fee");
        assertEq(tokenA.balanceOf(address(adapter)), netIn, "adapter got net input");
        assertEq(tokenB.balanceOf(address(pool)), minOut + expectedFeeOnB, "pool received minOut + fee");
    }

    /// The wrapper must swap the *measured* receipt from MASP.withdraw, not the
    /// caller-supplied `amountIn` (which is only a floor). Sets the floor below
    /// the net receipt and asserts the full net reached the adapter.
    function testSwapUsesMeasuredReceiptNotAmountIn() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint256 floorIn = netIn - 3 * SCALE; // deliberately below the net receipt
        uint64 minPublicIn = 900;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 expectedFeeOnB = (minOut * FEE_BPS) / 10_000;
        uint256 actualOut = minOut + expectedFeeOnB;

        _mintToPool(grossIn);
        _fundAdapter(actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: floorIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            intentIn: minPublicIn,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });

        wrapper.swap(a);
        assertEq(tokenA.balanceOf(address(adapter)), netIn, "adapter got full net receipt");
    }

    /// Reverts `InsufficientWithdraw` when MASP delivers less than the floor
    /// (e.g. a fee bump between quote and execution).
    function testRevertWhenWithdrawBelowFloor() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint256 floorIn = netIn + 1; // demand more than MASP will deliver

        _mintToPool(grossIn);
        pool.setNextWithdrawAmount(grossIn);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: floorIn,
            minOut: 900 * SCALE,
            piOut: uint64(grossIn / SCALE),
            intentIn: 900,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });

        vm.expectRevert(abi.encodeWithSelector(SwapWrapper.InsufficientWithdraw.selector, netIn, floorIn));
        wrapper.swap(a);
    }

    /// Pre-existing token dust must not brick a swap (donation-tolerant
    /// leftover invariant). Donations remain in the wrapper afterwards.
    function testDonationDoesNotBrickSwap() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 expectedFeeOnB = (minOut * FEE_BPS) / 10_000;
        uint256 expectedDust = 4 * SCALE;
        uint256 actualOut = minOut + expectedFeeOnB + expectedDust;

        _mintToPool(grossIn);
        _fundAdapter(actualOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        // Griefer donations sitting in the wrapper before the swap.
        tokenA.mint(address(wrapper), 3);
        tokenB.mint(address(wrapper), 5);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            intentIn: minPublicIn,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });

        wrapper.swap(a);

        // Swap succeeded; only the donated dust remains (untouched).
        assertEq(tokenA.balanceOf(address(wrapper)), 3, "tokenA donation preserved");
        assertEq(tokenB.balanceOf(address(wrapper)), 5, "tokenB donation preserved");
        assertEq(tokenB.balanceOf(TREASURY), expectedDust, "dust to treasury");
    }

    // -------- revert paths ---------------------------------------------

    function testRevertWhenAdapterNotAllowed() public {
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE,
            minOut: 990 * SCALE,
            piOut: 1_000,
            intentIn: 990,
            adapter_: address(0xDEAD),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
        vm.expectRevert(SwapWrapper.AdapterNotAllowed.selector);
        wrapper.swap(a);
    }

    function testRevertWhenRecipientNotWrapper() public {
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE,
            minOut: 990 * SCALE,
            piOut: 1_000,
            intentIn: 990,
            adapter_: address(adapter),
            recipient: address(0xBAD),
            payer: address(wrapper)
        });
        vm.expectRevert(SwapWrapper.WrapperNotRecipient.selector);
        wrapper.swap(a);
    }

    function testRevertWhenPayerNotWrapper() public {
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE,
            minOut: 990 * SCALE,
            piOut: 1_000,
            intentIn: 990,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(0xBAD)
        });
        vm.expectRevert(SwapWrapper.WrapperNotPayer.selector);
        wrapper.swap(a);
    }

    function testRevertWhenZeroAmounts() public {
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 0,
            minOut: 990 * SCALE,
            piOut: 0,
            intentIn: 990,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
        vm.expectRevert(SwapWrapper.AmountInZero.selector);
        wrapper.swap(a);

        a.amountIn = 1_000 * SCALE;
        a.minOut = 0;
        vm.expectRevert(SwapWrapper.MinOutZero.selector);
        wrapper.swap(a);
    }

    function testRevertWhenAdapterReturnsLessThanMin() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint256 minOut = 990 * SCALE;
        _mintToPool(grossIn);
        _fundAdapter(minOut);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(minOut - 1); // triggers MockSwapAdapter's own revert

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            intentIn: 990,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
        vm.expectRevert(bytes("MockSwapAdapter: insufficient out"));
        wrapper.swap(a);
    }

    /// MASP fee can push the pulled total above what the venue delivered.
    /// Before the balance-delta refactor this would silently leave the
    /// wrapper short of `dust` to forward; the explicit guard fails fast
    /// instead. Pre-mints exactly `fee` extra B to the wrapper so the
    /// Permit2 pull itself does not run out of balance — only the wrapper-
    /// level invariant `pulled <= actualOut` is being exercised here.
    function testRevertWhenMaspPullExceedsActualOut() public {
        uint256 grossIn = 1_000 * SCALE;
        uint256 netIn = grossIn - (grossIn * FEE_BPS) / 10_000;
        uint64 minPublicIn = 990;
        uint256 minOut = uint256(minPublicIn) * SCALE;
        uint256 expectedFeeOnB = (minOut * FEE_BPS) / 10_000;
        // Venue delivered exactly minOut.
        uint256 actualOut = minOut;

        _mintToPool(grossIn);
        _fundAdapter(actualOut);
        // Make sure Permit2 has the balance to satisfy `minOut + fee` so
        // we exercise the wrapper guard rather than a Permit2 underflow.
        tokenB.mint(address(wrapper), expectedFeeOnB);
        pool.setNextWithdrawAmount(grossIn);
        adapter.setNextActualOut(actualOut);

        SwapWrapper.SwapArgs memory a = _args({
            amountIn: netIn,
            minOut: minOut,
            piOut: uint64(grossIn / SCALE),
            intentIn: minPublicIn,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
        vm.expectRevert(
            abi.encodeWithSelector(SwapWrapper.MaspPullExceedsActualOut.selector, actualOut, minOut + expectedFeeOnB)
        );
        wrapper.swap(a);
    }

    // -------- admin -----------------------------------------------------

    function testOnlyOwnerCanAllowAdapter() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        wrapper.setAdapterAllowed(address(adapter), false);
    }

    function testOwnerCanFlipAllowlist() public {
        assertTrue(wrapper.adapterAllowed(address(adapter)));
        vm.prank(OWNER);
        wrapper.setAdapterAllowed(address(adapter), false);
        assertFalse(wrapper.adapterAllowed(address(adapter)));
    }

    function testRevertWhenSameToken() public {
        SwapWrapper.SwapArgs memory a = _args({
            amountIn: 1_000 * SCALE,
            minOut: 990 * SCALE,
            piOut: 1_000,
            intentIn: 990,
            adapter_: address(adapter),
            recipient: address(wrapper),
            payer: address(wrapper)
        });
        a.tokenOut = a.tokenIn;
        vm.expectRevert(SwapWrapper.SameToken.selector);
        wrapper.swap(a);
    }

    function testConstructorRejectsZeroPool() public {
        vm.expectRevert(SwapWrapper.ZeroAddress.selector);
        new SwapWrapper(IMASPSwap(address(0)), permit2, OWNER, TREASURY);
    }

    function testConstructorRejectsZeroPermit2() public {
        vm.expectRevert(SwapWrapper.ZeroAddress.selector);
        new SwapWrapper(pool, IAllowanceTransfer(address(0)), OWNER, TREASURY);
    }

    function testConstructorRejectsZeroTreasury() public {
        vm.expectRevert(SwapWrapper.ZeroAddress.selector);
        new SwapWrapper(pool, permit2, OWNER, address(0));
    }

    function testSetTreasuryRejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(SwapWrapper.ZeroAddress.selector);
        wrapper.setTreasury(address(0));
    }

    function testSetAdapterAllowedRejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(SwapWrapper.ZeroAddress.selector);
        wrapper.setAdapterAllowed(address(0), true);
    }

    function testPrepareTokenSetsBothAllowances() public {
        // tokenA has no Permit2 allowance until prepareToken runs.
        wrapper.prepareToken(IERC20(address(tokenA)));
        assertEq(tokenA.allowance(address(wrapper), address(permit2)), type(uint256).max);
        (uint160 cap,,) = permit2.allowance(address(wrapper), address(tokenA), address(pool));
        assertEq(cap, type(uint160).max, "permit2 to pool allowance");
    }
}
