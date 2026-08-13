// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { NativeAdapter } from "../src/native/NativeAdapter.sol";
import { IMASPNative } from "../src/native/IMASPNative.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockWETH9 } from "./mocks/MockWETH9.sol";

/// `NativeAdapter` end-to-end: wrap-on-deposit, unwrap-on-withdraw, and the
/// refund path for adapter-owned escrows. MASP itself is ERC-20 only, so every
/// native leg here is the adapter's.
///
/// Both Groth16 verifiers are mocked to `true`: the proofs are not the subject,
/// the wrapping bookkeeping is.
contract NativeAdapterTest is Test {
    uint64 internal constant ASSET_ERC20 = 1; // plain ERC-20 (not WETH)
    uint64 internal constant ASSET_WETH = 2; // WETH-backed asset
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;

    address internal constant DEPOSITOR = address(0xBEEF);
    address internal constant RECIPIENT = address(0xF00D);

    MockERC20 token;
    MockWETH9 weth;
    MASP masp;
    NativeAdapter adapter;
    address permit2;

    function setUp() public {
        token = new MockERC20("T", "T", 18);
        weth = new MockWETH9();
        permit2 = new DeployPermit2().deployPermit2();

        IVerifier v = IVerifier(address(new MockERC20("v", "v", 18)));
        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));

        uint64[] memory ids = new uint64[](2);
        IERC20[] memory tokens = new IERC20[](2);
        uint256[] memory scales = new uint256[](2);
        ids[0] = ASSET_ERC20;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;
        ids[1] = ASSET_WETH;
        tokens[1] = IERC20(address(weth));
        scales[1] = SCALE;

        masp = new MASP(
            v, tub, ISignatureTransfer(permit2), ids, tokens, scales, FEE_BPS, address(0xfee), address(this)
        );
        adapter =
            new NativeAdapter(IMASPNative(address(masp)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));
    }

    // --- helpers -----------------------------------------------------------

    function _mockVerifiers() internal {
        vm.mockCall(address(masp.VERIFIER()), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
        vm.mockCall(
            address(masp.TREE_UPDATE_BATCH_VERIFIER()),
            abi.encodeWithSelector(IVerifier.verifyProof.selector),
            abi.encode(true)
        );
    }

    function _emptyProof() internal pure returns (IMASPNative.Proof memory) {
        return IMASPNative.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    function _aux1() internal pure returns (AuxValidation.Output memory a) {
        a.clueRx = BabyJubJub.BASE8_X;
        a.clueRy = BabyJubJub.BASE8_Y;
        a.ephPubX = BabyJubJub.BASE8_X;
        a.ephPubY = BabyJubJub.BASE8_Y;
        a.ciphertext = hex"0001";
    }

    function _aux3() internal pure returns (AuxValidation.Output[3] memory aux) {
        aux[0] = _aux1();
        aux[1] = _aux1();
        aux[2] = _aux1();
    }

    function _request(uint64 assetId, uint64 publicIn) internal view returns (PubInputs.DepositRequest memory d) {
        d.chainId = block.chainid;
        d.publicAssetId = assetId;
        d.publicIn = publicIn;
        d.payer = address(adapter);
        d.recipient = RECIPIENT;
        d.outCm = bytes32(uint256(0x1));
    }

    function _total(uint64 publicIn) internal pure returns (uint256) {
        uint256 inAmt = uint256(publicIn) * SCALE;
        return inAmt + (inAmt * FEE_BPS) / 10_000;
    }

    function _transactPi(uint64 assetId, uint64 publicOut) internal view returns (PubInputs.Transact memory pi) {
        pi.chainId = block.chainid;
        pi.publicAssetId = assetId;
        pi.publicIn = 0;
        pi.publicOut = publicOut;
        pi.recipient = address(adapter);
        pi.payer = DEPOSITOR;
        pi.relayer = address(adapter);
        pi.nullifier[0] = bytes32(uint256(0x1111));
        pi.nullifier[1] = bytes32(uint256(0x2222));
        pi.nullifier[2] = bytes32(uint256(0x2223));
        pi.outCm[0] = bytes32(uint256(0x3333));
        pi.outCm[1] = bytes32(uint256(0x4444));
        pi.outCm[2] = bytes32(uint256(0x4445));
        pi.merkleRoot = masp.currentRoot();
    }

    function _tpi(PubInputs.Transact memory pi) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = 3;
        tpi.cms[0] = pi.outCm[0];
        tpi.cms[1] = pi.outCm[1];
        tpi.cms[2] = pi.outCm[2];
    }

    /// Cancel straight at the pool, naming the adapter as payer. Kept out of
    /// the test body so the 8-argument call does not blow the stack under the
    /// coverage build.
    function _poolCancel(uint256 id, uint64 publicIn, uint32 submittedAt) internal {
        masp.cancelDeposit(
            id,
            uint48(publicIn),
            bytes32(uint256(0x1)),
            [uint256(0), 0],
            ASSET_WETH,
            FEE_BPS,
            address(adapter),
            submittedAt
        );
    }

    /// Deposit `publicIn` units of the WETH asset through the adapter.
    function _deposit(address from, uint64 publicIn, uint256 value) internal returns (uint256 id) {
        vm.deal(from, value);
        vm.prank(from);
        id = adapter.depositNative{ value: value }(_request(ASSET_WETH, publicIn), _aux1());
    }

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

    /// The caller may overshoot instead of mirroring MASP's fee math; the
    /// surplus comes back as native coin, not WETH.
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
        adapter.depositNative{ value: total + 5 }(_request(ASSET_WETH, publicIn), _aux1());
    }

    function test_depositNative_revert_ZeroValue() public {
        vm.prank(DEPOSITOR);
        vm.expectRevert(NativeAdapter.ZeroValue.selector);
        adapter.depositNative{ value: 0 }(_request(ASSET_WETH, 1), _aux1());
    }

    /// The adapter must be `payer`: it is the only address whose Permit2
    /// allowance the pool can pull against here.
    function test_depositNative_revert_AdapterNotPayer() public {
        PubInputs.DepositRequest memory d = _request(ASSET_WETH, 1);
        d.payer = DEPOSITOR;
        vm.deal(DEPOSITOR, 1 ether);
        vm.prank(DEPOSITOR);
        vm.expectRevert(NativeAdapter.AdapterNotPayer.selector);
        adapter.depositNative{ value: 1 ether }(d, _aux1());
    }

    /// A non-wrapped-native asset id cannot drain the wrap: the adapter holds
    /// no such token, so the pool's Permit2 pull reverts.
    function test_depositNative_revert_wrongAsset() public {
        vm.deal(DEPOSITOR, 1 ether);
        vm.prank(DEPOSITOR);
        vm.expectRevert();
        adapter.depositNative{ value: 1 ether }(_request(ASSET_ERC20, 1), _aux1());
    }

    // --- cancel ------------------------------------------------------------

    function test_cancelNative_refundsFunderInNative() public {
        uint64 publicIn = 3;
        uint256 total = _total(publicIn);
        uint256 id = _deposit(DEPOSITOR, publicIn, total);
        uint32 submittedAt = uint32(vm.getBlockNumber());

        vm.roll(block.number + masp.cancelDelay());

        vm.expectEmit(true, true, true, true, address(adapter));
        emit NativeAdapter.NativeRefunded(id, DEPOSITOR, total);

        adapter.cancelNative(
            id, uint48(publicIn), bytes32(uint256(0x1)), [uint256(0), 0], ASSET_WETH, FEE_BPS, submittedAt
        );

        assertEq(DEPOSITOR.balance, total, "funder made whole in native");
        assertEq(weth.balanceOf(DEPOSITOR), 0, "refund is unwrapped");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter drained");
        (address refundTo,) = adapter.escrows(id);
        assertEq(refundTo, address(0), "record cleared");
    }

    function test_cancelNative_revert_NoEscrowRecord() public {
        vm.expectRevert(abi.encodeWithSelector(NativeAdapter.NoEscrowRecord.selector, uint256(7)));
        adapter.cancelNative(
            7, 1, bytes32(uint256(0x1)), [uint256(0), 0], ASSET_WETH, FEE_BPS, uint32(vm.getBlockNumber())
        );
    }

    /// The pool refuses a cancel of a contract payer's deposit from anyone but
    /// that contract. Without it, a third party could settle the pool leg
    /// directly and park the refund here with nothing on-chain left to tell it
    /// apart from a flushed deposit — stranding the funder's claim.
    function test_pool_rejectsThirdPartyCancelOfAdapterDeposit() public {
        uint64 publicIn = 3;
        uint256 total = _total(publicIn);
        uint256 id = _deposit(DEPOSITOR, publicIn, total);
        uint32 submittedAt = uint32(vm.getBlockNumber());

        vm.roll(block.number + masp.cancelDelay());
        vm.expectRevert(MASP.PayerNotSender.selector);
        _poolCancel(id, publicIn, submittedAt);

        // The adapter-driven path still settles it.
        adapter.cancelNative(
            id, uint48(publicIn), bytes32(uint256(0x1)), [uint256(0), 0], ASSET_WETH, FEE_BPS, submittedAt
        );
        assertEq(DEPOSITOR.balance, total, "funder paid out");
    }

    /// A flushed deposit zeroes `escrowed[id]` and returns nothing. Its record
    /// is stale, and paying it out would spend some other escrow's coin, so the
    /// settled-deposit check rejects it before any refund is attempted.
    function test_cancelNative_revert_DepositAlreadySettled_afterFlush() public {
        uint64 publicIn = 3;
        uint256 total = _total(publicIn);
        uint256 flushedId = _deposit(DEPOSITOR, publicIn, total);
        // A second, still-pending escrow whose funds would be the ones at risk.
        _deposit(address(0xCAFE), publicIn, total);

        _flush(flushedId, publicIn, masp.committedCount());

        vm.expectRevert(abi.encodeWithSelector(NativeAdapter.DepositAlreadySettled.selector, flushedId));
        adapter.cancelNative(
            flushedId,
            uint48(publicIn),
            bytes32(uint256(0x1)),
            [uint256(0), 0],
            ASSET_WETH,
            FEE_BPS,
            uint32(vm.getBlockNumber())
        );
        // Flush moves no coin out of the pool, so both deposits are still there.
        assertEq(weth.balanceOf(address(masp)), 2 * total, "the surviving escrow is untouched");
    }

    /// Flush an adapter-owned deposit, leaving its record behind unfunded.
    function _flush(uint256 id, uint64 publicIn, uint64 startIndex) internal {
        _mockVerifiers();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: address(adapter), submittedAt: uint32(vm.getBlockNumber()), fbps: FEE_BPS });

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = startIndex;
        tpi.actualCount = 1;
        tpi.cms[0] = bytes32(uint256(0x1));
        tpi.leafAsset[0] = ASSET_WETH;
        tpi.leafPublicIn[0] = publicIn;
        tpi.isDeposit[0] = 1;
        masp.flushBatch(
            ids,
            meta,
            MASP.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] }),
            tpi
        );
    }

    /// A stale record left by a flushed deposit must not hold up an ordinary
    /// cancel: that path proves funding by delta across its own pool call and
    /// consults no shared state.
    function test_cancelNative_unaffectedByStaleFlushedRecord() public {
        uint64 publicIn = 3;
        uint256 total = _total(publicIn);
        uint256 flushedId = _deposit(DEPOSITOR, publicIn, total);
        uint256 liveId = _deposit(address(0xCAFE), publicIn, total);
        uint32 submittedAt = uint32(vm.getBlockNumber());

        _flush(flushedId, publicIn, masp.committedCount());
        vm.roll(vm.getBlockNumber() + masp.cancelDelay());

        adapter.cancelNative(
            liveId, uint48(publicIn), bytes32(uint256(0x1)), [uint256(0), 0], ASSET_WETH, FEE_BPS, submittedAt
        );

        assertEq(address(0xCAFE).balance, total, "live escrow refunded");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter holds nothing after the payout");
    }

    // --- withdraw ----------------------------------------------------------

    /// Fund the pool with WETH so an unshield has backing.
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
        uint256 paid = adapter.withdrawNative(_emptyProof(), pi, _emptyProof(), _tpi(pi), _aux3());

        assertEq(paid, net, "returned net matches");
        assertEq(DEPOSITOR.balance, net, "payer paid in raw native");
        assertEq(weth.balanceOf(DEPOSITOR), 0, "payer holds no wrapped coin");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter keeps nothing");
        assertEq(address(adapter).balance, 0, "adapter holds no native");
        assertEq(masp.accruedFee(IERC20(address(weth))), fee, "fee stays wrapped in the pool");
    }

    /// Wrapped coin sitting on the adapter for any reason must not leak into
    /// the unshield measurement, nor be spent by it. The delta is what makes
    /// that hold.
    function test_withdrawNative_ignoresPreExistingBalance() public {
        uint256 parked = 4 ether;
        weth.mint(address(adapter), parked);

        uint64 publicOut = 7;
        uint256 gross = uint256(publicOut) * SCALE;
        uint256 net = gross - (gross * FEE_BPS) / 10_000;
        _armWithdraw(gross);

        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, publicOut);
        adapter.withdrawNative(_emptyProof(), pi, _emptyProof(), _tpi(pi), _aux3());

        assertEq(DEPOSITOR.balance, net, "only the unshield net was forwarded");
        assertEq(weth.balanceOf(address(adapter)), parked, "pre-existing balance untouched");
    }

    function test_withdrawNative_revert_AdapterNotRecipient() public {
        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, 1);
        pi.recipient = DEPOSITOR;
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.expectRevert(NativeAdapter.AdapterNotRecipient.selector);
        adapter.withdrawNative(_emptyProof(), pi, _emptyProof(), tpi, _aux3());
    }

    function test_withdrawNative_revert_AdapterNotRelayer() public {
        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, 1);
        pi.relayer = address(0xCA11);
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.expectRevert(NativeAdapter.AdapterNotRelayer.selector);
        adapter.withdrawNative(_emptyProof(), pi, _emptyProof(), tpi, _aux3());
    }

    /// An unshield of a non-wrapped-native asset would strand an ERC-20 here;
    /// the zero wrapped-delta check reverts the whole spend instead.
    function test_withdrawNative_revert_NothingUnshielded() public {
        uint64 publicOut = 7;
        token.mint(address(masp), uint256(publicOut) * SCALE);
        _mockVerifiers();

        PubInputs.Transact memory pi = _transactPi(ASSET_ERC20, publicOut);
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.expectRevert(NativeAdapter.NothingUnshielded.selector);
        adapter.withdrawNative(_emptyProof(), pi, _emptyProof(), tpi, _aux3());
    }

    /// The payer is a raw-native destination; one that rejects the push must
    /// surface `NativeTransferFailed` rather than stranding the funds.
    function test_withdrawNative_revert_NativeTransferFailed() public {
        uint64 publicOut = 7;
        _armWithdraw(uint256(publicOut) * SCALE);

        PubInputs.Transact memory pi = _transactPi(ASSET_WETH, publicOut);
        pi.payer = address(new NativeRejector());
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.expectRevert(NativeAdapter.NativeTransferFailed.selector);
        adapter.withdrawNative(_emptyProof(), pi, _emptyProof(), tpi, _aux3());
    }

    // --- misc --------------------------------------------------------------

    /// Raw native is only ever expected from the unwrap leg.
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

    /// MASP no longer accepts raw native at all.
    function test_pool_rejectsRawNative() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(masp).call{ value: 1 }("");
        assertFalse(ok, "pool must not accept native");
    }
}

/// Rejects raw native, forcing the `_sendNative` low-level call to fail.
contract NativeRejector {
    receive() external payable {
        revert("no native");
    }
}
