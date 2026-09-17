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
import { ERC4626Venue } from "../../src/yield/ERC4626Venue.sol";
import { YieldIndex } from "../../src/yield/YieldIndex.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { deployPoolUniform, singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";

/// `NativeAdapter` against a yield asset, end to end.
///
/// `MaspEscrowSatellite` checks the refund that arrives against the refund the
/// pool reports, not against the recorded escrow, to support this configuration.
/// `NativeAdapter.guards.t.sol` covers that check against `MockNativePool`, whose
/// refund is set by hand; `NativeAdapter.t.sol` uses a real pool with plain WETH,
/// where the refund always equals the escrow. This suite covers a real index: a
/// yield refund is floored at the current index and capped at the pull, so it
/// equals the recorded escrow after growth and falls below it at a flat index or
/// after a loss.
///
/// WETH is the wrapped native token on all three deployed chains, so a
/// yield-bearing WETH id is on the native ETH path.
contract YieldNativeAdapterTest is Test {
    uint64 internal constant ASSET_ERC20 = 1;
    uint64 internal constant ASSET_WETH = 2; // yield-bearing
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    uint16 internal constant BUFFER_BPS = 500;
    uint16 internal constant PERF_BPS = 1000;

    address internal constant DEPOSITOR = address(0xBEEF);
    /// An earlier holder, so a later escrow prices off a moved index.
    address internal constant HOLDER = address(0xA11CE);
    address internal constant RECIPIENT = TestConstants.RECIPIENT;
    address internal constant OWNER = TestConstants.OWNER;

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

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ERC20, SCALE);

        masp = deployPoolUniform(
            tub, bv, ISignatureTransfer(permit2), ids, tokens, scales, FEE_BPS, address(0xfee), OWNER
        );

        // WETH is registered as a yield asset after pool deployment, since the
        // venue is pinned to the pool.
        vault = new MockERC4626(IERC20(address(weth)));
        venue = new ERC4626Venue(address(masp), address(vault), address(weth));
        vm.prank(OWNER);
        masp.addYieldAsset(
            ASSET_WETH, IERC20(address(weth)), SCALE, FEE_BPS, FEE_BPS, address(venue), BUFFER_BPS, PERF_BPS
        );

        adapter =
            new NativeAdapter(IMASPPool(address(masp)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));

        Stubs.acceptAllProofs(tub, bv);
    }

    // --- helpers ------------------------------------------------------------

    function _request(uint64 publicIn) internal view returns (PubInputs.DepositRequest memory d) {
        d = DepositFixture.request(ASSET_WETH, publicIn, address(adapter), RECIPIENT, bytes32(uint256(0x1)));
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
        id = adapter.depositNative{ value: value }(
            _request(publicIn), SpendFixture.validAuxOutput(), SpendFixture.validAuxOutput()
        );
    }

    /// Deposits from `who`, overshooting the pull: the adapter returns the
    /// excess, so the value need not be computed against a moved index.
    function _depositFrom(address who, uint64 publicIn) internal returns (uint256 id, uint256 recorded) {
        uint256 value = uint256(publicIn) * SCALE * 2;
        vm.deal(who, value);
        vm.prank(who);
        id = adapter.depositNative{ value: value }(
            _request(publicIn), SpendFixture.validAuxOutput(), SpendFixture.validAuxOutput()
        );
        (, recorded) = adapter.escrows(id);
    }

    /// What `YieldOps.cancel` values an escrow of `publicIn` at before the cap:
    /// its units at the current index, floored. Exact when the cancel accrues
    /// no performance fee.
    function _floorValue(uint64 publicIn) internal view returns (uint256) {
        YieldIndex.YieldState memory st = masp.yieldState(ASSET_WETH);
        uint256 nTotal = uint256(publicIn) + Math.ceilDiv(uint256(publicIn) * FEE_BPS, 10_000);
        uint256 g = vault.convertToAssets(vault.balanceOf(address(venue))) + st.idle;
        return Math.mulDiv(nTotal, g, st.totalNormalized + st.accruedFeeNormalized);
    }

    /// Cancels `id` after the delay and returns the native coin it paid out.
    function _cancelAndMeasure(uint256 id, uint64 publicIn, uint32 submittedAt) internal returns (uint256 refund) {
        vm.roll(block.number + masp.cancelDelay());
        uint256 before = DEPOSITOR.balance;
        _cancel(id, publicIn, submittedAt);
        refund = DEPOSITOR.balance - before;
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter holds no wrapped dust");
        assertEq(address(adapter).balance, 0, "adapter holds no native dust");
        (address refundTo,) = adapter.escrows(id);
        assertEq(refundTo, address(0), "escrow record cleared");
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
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0x2)), feeCvDep: [uint256(0), 0] })
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

    /// After growth the native cancel refunds exactly the recorded pull.
    ///
    /// The escrow's units share the index while pending, but the refund is capped
    /// at the pull, so a deposit left unflushed earns nothing. The pool reports
    /// that capped refund, and the adapter forwards it.
    function test_cancelNative_afterYield_refundsExactlyThePull() public {
        uint64 publicIn = 1_000_000;
        uint32 submittedAt = uint32(vm.getBlockNumber());
        uint256 id = _deposit(publicIn);

        (, uint256 recorded) = adapter.escrows(id);
        assertEq(recorded, _firstPull(publicIn), "adapter recorded the submit-time pull");

        _earn(2 ether);
        uint256 refund = _cancelAndMeasure(id, publicIn, submittedAt);

        assertEq(refund, recorded, "refund is the pull, not the grown value");
    }

    /// The refund never exceeds the recorded pull, whatever the venue does in
    /// between.
    function test_cancelNative_refundIsBoundedByTheRecordedPull() public {
        uint64 publicIn = 1_000_000;
        uint256[3] memory growths = [uint256(0), 7, 2 ether];
        for (uint256 i = 0; i < growths.length; ++i) {
            uint32 submittedAt = uint32(vm.getBlockNumber());
            (uint256 id, uint256 recorded) = _depositFrom(DEPOSITOR, publicIn);
            if (growths[i] != 0) _earn(growths[i]);

            uint256 refund = _cancelAndMeasure(id, publicIn, submittedAt);
            assertLe(refund, recorded, "refund exceeded the recorded pull");
        }
    }

    /// At a flat index the ceilinged pull and the floored refund differ by a wei.
    ///
    /// The adapter used to require at least the recorded amount back, so this
    /// cancel reverted, and the pool accepts a contract payer's cancel only from
    /// the payer: the escrow had no refund path. The adapter now forwards what
    /// the pool reports.
    function test_cancelNative_atFlatIndex_refundsTheFloor() public {
        _depositFrom(HOLDER, 1_000_000);
        // Odd growth, so a unit is no longer worth a whole number of base units.
        _earn(7);

        uint64 publicIn = 333_333;
        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id, uint256 recorded) = _depositFrom(DEPOSITOR, publicIn);
        uint256 expected = _floorValue(publicIn);

        uint256 refund = _cancelAndMeasure(id, publicIn, submittedAt);

        assertEq(refund, expected, "refund is the floored value at the current index");
        assertLt(refund, recorded, "short of the ceilinged pull");
        assertLe(recorded - refund, 1, "by rounding alone");
    }

    /// The same after an emergency unwind, which leaves the asset as zero-yield
    /// custody: the index stops moving, and the rounding gap remains.
    function test_cancelNative_afterEmergencyUnwind_refundsTheFloor() public {
        _depositFrom(HOLDER, 1_000_000);
        _earn(3);
        vm.prank(OWNER);
        masp.emergencyUnwind(ASSET_WETH);

        uint64 publicIn = 333;
        uint32 submittedAt = uint32(vm.getBlockNumber());
        (uint256 id, uint256 recorded) = _depositFrom(DEPOSITOR, publicIn);
        uint256 expected = _floorValue(publicIn);

        uint256 refund = _cancelAndMeasure(id, publicIn, submittedAt);

        assertEq(refund, expected, "refund is the floored value at the frozen index");
        assertLe(refund, recorded, "never above the pull");
        assertLe(recorded - refund, 1, "by rounding alone");
    }

    /// A venue loss is shared by the escrow: the refund is what its units are
    /// still worth, below the recorded pull, and the cancel still settles.
    function test_cancelNative_afterVenueLoss_refundsWhatIsLeft() public {
        uint64 publicIn = 1_000_000;
        uint32 submittedAt = uint32(vm.getBlockNumber());
        uint256 id = _deposit(publicIn);
        (, uint256 recorded) = adapter.escrows(id);

        vault.lose(vault.totalAssetsHeld() / 4);
        uint256 expected = _floorValue(publicIn);

        uint256 refund = _cancelAndMeasure(id, publicIn, submittedAt);

        assertEq(refund, expected, "refund is the escrow's post-loss value");
        assertLt(refund, recorded, "and carries the loss");
    }

    /// The native unshield leg on a yield asset. `withdrawNative` measures a
    /// wrapped-balance delta rather than recomputing the fee, so it follows the
    /// index without yield-specific logic.
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
        PubInputs.SpendTree memory tpi =
            SpendFixture.spendTree(bytes32(uint256(0xdead)), masp.committedCount(), uint8(masp.rootIndex()));

        uint256 before = DEPOSITOR.balance;
        uint256 net = adapter.withdrawNative(
            FixtureLoader.emptyPoolProof(), pi, FixtureLoader.emptyPoolProof(), tpi, SpendFixture.validAux()
        );

        assertEq(DEPOSITOR.balance - before, net, "native forwarded to the proof's payer");
        // Worth strictly more than the same units at a flat rate, because the
        // index has moved.
        uint256 flat = uint256(publicOut) * SCALE;
        assertGt(net, flat - (flat * FEE_BPS) / 10_000, "payout did not follow the index");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter holds no wrapped dust");
    }
}
