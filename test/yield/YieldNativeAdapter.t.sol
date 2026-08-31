// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../../src/BabyJubJub.sol";
import { ERC4626Venue } from "../../src/yield/ERC4626Venue.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { uniformBps } from "../utils/FeeArrays.sol";

/// `NativeAdapter` against a **yield** asset, end to end.
///
/// This is the configuration `MaspEscrowSatellite`'s refund check was relaxed
/// for, and until now nothing exercised it. `NativeAdapter.guards.t.sol` drives
/// the relaxation against `MockNativePool`, whose refund is a number set by
/// hand; `NativeAdapter.t.sol` uses a real pool but registers plain WETH, where
/// the refund always equals the escrow exactly. Neither reaches the case that
/// motivated the change: a real index that has moved, so the pool genuinely
/// returns more than the adapter recorded.
///
/// It matters because WETH is the wrapped native token on all three deployed
/// chains, so a yield-bearing WETH id puts this on the live native ETH path.
contract YieldNativeAdapterTest is Test {
    uint64 internal constant ASSET_ERC20 = 1;
    uint64 internal constant ASSET_WETH = 2; // yield-bearing
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    uint16 internal constant BUFFER_BPS = 500;
    uint16 internal constant PERF_BPS = 1000;

    address internal constant DEPOSITOR = address(0xBEEF);
    address internal constant RECIPIENT = address(0xF00D);
    address internal constant OWNER = address(0x0117e7);

    MockERC20 internal token;
    MockWETH9 internal weth;
    MockERC4626 internal vault;
    ERC4626Venue internal venue;
    MASP internal masp;
    MockBatchVerifier internal bv;
    NativeAdapter internal adapter;
    address internal permit2;

    function setUp() public {
        token = new MockERC20("T", "T", 18);
        weth = new MockWETH9();
        permit2 = new DeployPermit2().deployPermit2();

        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        bv = new MockBatchVerifier();

        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = ASSET_ERC20;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;

        masp = new MASP(
            tub,
            bv,
            ISignatureTransfer(permit2),
            ids,
            tokens,
            scales,
            uniformBps(1, FEE_BPS),
            uniformBps(1, FEE_BPS),
            address(0xfee),
            OWNER
        );

        // WETH is registered as a yield asset, which is only possible after the
        // pool exists: the venue is pinned to it.
        vault = new MockERC4626(IERC20(address(weth)));
        venue = new ERC4626Venue(address(masp), address(vault), address(weth));
        vm.prank(OWNER);
        masp.addYieldAsset(
            ASSET_WETH, IERC20(address(weth)), SCALE, FEE_BPS, FEE_BPS, address(venue), BUFFER_BPS, PERF_BPS
        );

        adapter =
            new NativeAdapter(IMASPPool(address(masp)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));

        bv.setResult(true);
        vm.mockCall(address(tub), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
    }

    // --- helpers ------------------------------------------------------------

    function _aux1() internal pure returns (AuxValidation.Output memory a) {
        a.clueRx = BabyJubJub.BASE8_X;
        a.clueRy = BabyJubJub.BASE8_Y;
        a.ephPubX = BabyJubJub.BASE8_X;
        a.ephPubY = BabyJubJub.BASE8_Y;
        a.ciphertext = hex"0001";
    }

    function _aux6() internal pure returns (AuxValidation.Output[6] memory aux) {
        for (uint256 k; k < aux.length; ++k) {
            aux[k] = _aux1();
        }
    }

    function _emptyProof() internal pure returns (IMASPPool.Proof memory) {
        return IMASPPool.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    function _request(uint64 publicIn) internal view returns (PubInputs.DepositRequest memory d) {
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_WETH;
        d.publicIn = publicIn;
        d.payer = address(adapter);
        d.recipient = RECIPIENT;
        d.outCm = bytes32(uint256(0x1));
        d.feeCm = bytes32(uint256(0x2));
    }

    /// At the first deposit the index is `RAY`, so the pull matches the plain
    /// arithmetic exactly and the value to send is known in closed form.
    function _firstPull(uint64 publicIn) internal pure returns (uint256) {
        uint256 inAmt = uint256(publicIn) * SCALE;
        return inAmt + (inAmt * FEE_BPS) / 10_000;
    }

    function _deposit(uint64 publicIn) internal returns (uint256 id) {
        uint256 value = _firstPull(publicIn);
        vm.deal(DEPOSITOR, value);
        vm.prank(DEPOSITOR);
        id = adapter.depositNative{ value: value }(_request(publicIn), _aux1(), _aux1());
    }

    /// Credit interest inside the vault, in wrapped coin.
    function _earn(uint256 amt) internal {
        vm.deal(address(this), amt);
        weth.deposit{ value: amt }();
        weth.approve(address(vault), amt);
        vault.earn(amt);
    }

    function _cancel(uint256 id, uint64 publicIn, uint32 submittedAt) internal {
        adapter.cancelNative(
            id,
            uint48(publicIn),
            bytes32(uint256(0x1)),
            [uint256(0), 0],
            ASSET_WETH,
            FEE_BPS,
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeCm: bytes32(uint256(0x2)), feeCvDep: [uint256(0), 0] })
        );
    }

    // --- tests --------------------------------------------------------------

    /// A native deposit reaches the venue like any other shield: the adapter
    /// wraps, the pool pulls, and everything above the buffer is supplied.
    function test_depositNative_reachesTheVenue() public {
        _deposit(1_000_000);

        YieldIndex.YieldState memory st = masp.yieldState(ASSET_WETH);
        assertGt(vault.balanceOf(address(venue)), 0, "venue funded from a native deposit");
        assertEq(
            st.idle,
            ((vault.convertToAssets(vault.balanceOf(address(venue))) + st.idle) * BUFFER_BPS) / 10_000,
            "idle left at the buffer target"
        );
        assertEq(masp.index(ASSET_WETH), 1e27, "first deposit prices at RAY");
    }

    /// The case the satellite fix exists for.
    ///
    /// Once the venue has earned, a cancellation returns the escrowed units at
    /// today's index — strictly more than the adapter recorded at submit. The
    /// original exact-match check would revert here, taking the native refund
    /// path down with it; the measured check forwards the larger amount.
    function test_cancelNative_afterYield_forwardsTheGrownRefund() public {
        uint64 publicIn = 1_000_000;
        uint32 submittedAt = uint32(vm.getBlockNumber());
        uint256 id = _deposit(publicIn);

        (, uint256 recorded) = adapter.escrows(id);
        assertEq(recorded, _firstPull(publicIn), "adapter recorded the submit-time pull");

        _earn(2 ether);
        vm.roll(block.number + masp.cancelDelay());

        _cancel(id, publicIn, submittedAt);

        // The whole point: more came back than was recorded, and all of it
        // reached the funder as native coin.
        assertGt(DEPOSITOR.balance, recorded, "refund did not grow with the index");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter holds no wrapped dust");
        assertEq(address(adapter).balance, 0, "adapter holds no native dust");
        (address refundTo,) = adapter.escrows(id);
        assertEq(refundTo, address(0), "escrow record cleared");
    }

    /// The refund tracks the index rather than being merely "more": it must not
    /// exceed what the deposit plus its share of the growth is worth.
    function test_cancelNative_refundIsBoundedByDepositPlusGrowth() public {
        uint64 publicIn = 1_000_000;
        uint32 submittedAt = uint32(vm.getBlockNumber());
        uint256 id = _deposit(publicIn);
        (, uint256 recorded) = adapter.escrows(id);

        uint256 growth = 2 ether;
        _earn(growth);
        vm.roll(block.number + masp.cancelDelay());

        _cancel(id, publicIn, submittedAt);
        assertLe(DEPOSITOR.balance, uint256(recorded) + growth, "refund exceeded deposit plus all the growth");
    }

    /// The native unshield leg on a yield asset. `withdrawNative` measures a
    /// wrapped-balance delta rather than recomputing the fee, so it follows the
    /// index with no change of its own — this pins that.
    function test_withdrawNative_onAYieldAssetPaysTheGrownAmount() public {
        uint64 publicIn = 1_000_000;
        _deposit(publicIn);
        _earn(2 ether);

        uint64 publicOut = publicIn / 4;
        PubInputs.Transact memory pi;
        pi.chainId = block.chainid;
        pi.publicAssetId = ASSET_WETH;
        pi.publicOut = publicOut;
        pi.recipient = address(adapter);
        pi.payer = DEPOSITOR;
        pi.relayer = address(adapter);
        SpendFixture.fillOutputs(pi, 0x1111, 0x3333);
        pi.merkleRoot = masp.currentRoot();
        PubInputs.TreeUpdateBatch memory tpi =
            SpendFixture.batchFor(pi, masp.currentRoot(), bytes32(uint256(0xdead)), masp.committedCount());

        uint256 before = DEPOSITOR.balance;
        uint256 net = adapter.withdrawNative(_emptyProof(), pi, _emptyProof(), tpi, _aux6());

        assertEq(DEPOSITOR.balance - before, net, "native forwarded to the proof's payer");
        // Worth strictly more than the same units at a flat rate, because the
        // index has moved.
        uint256 flat = uint256(publicOut) * SCALE;
        assertGt(net, flat - (flat * FEE_BPS) / 10_000, "payout did not follow the index");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter holds no wrapped dust");
    }
}
