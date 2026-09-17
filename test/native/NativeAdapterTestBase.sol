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
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { deployPoolUniform, twoAssets } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";

/// `NativeAdapter` end-to-end: wrap-on-deposit, unwrap-on-withdraw, and the
/// refund path for adapter-owned escrows. MASP is ERC-20 only, so every native
/// leg here belongs to the adapter.
///
/// Both Groth16 verifiers are mocked to accept; the subject is the wrapping
/// bookkeeping, not the proofs.
///
/// Fixture and helpers shared by the `NativeAdapter.*.t.sol` suites.
abstract contract NativeAdapterTestBase is Test {
    uint64 internal constant ASSET_ERC20 = 1; // plain ERC-20 (not WETH)
    uint64 internal constant ASSET_WETH = 2; // WETH-backed asset
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;

    address internal constant DEPOSITOR = address(0xBEEF);
    address internal constant RECIPIENT = TestConstants.RECIPIENT;

    MockERC20 token;
    MockWETH9 weth;
    MASP masp;
    MockBatchVerifier bv;
    NativeAdapter adapter;
    address permit2;

    function setUp() public virtual {
        token = new MockERC20("T", "T", 18);
        weth = new MockWETH9();
        permit2 = new DeployPermit2().deployPermit2();

        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        bv = new MockBatchVerifier();

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            twoAssets(IERC20(address(token)), ASSET_ERC20, IERC20(address(weth)), ASSET_WETH, SCALE);

        masp = deployPoolUniform(
            tub, bv, ISignatureTransfer(permit2), ids, tokens, scales, FEE_BPS, address(0xfee), address(this)
        );
        adapter =
            new NativeAdapter(IMASPPool(address(masp)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));
    }

    // --- helpers -----------------------------------------------------------

    function _mockVerifiers() internal {
        // Spends route through `SPEND_VERIFIER`; the tree-update mock serves
        // `flushBatch`.
        Stubs.acceptAllProofs(masp.TREE_UPDATE_BATCH_VERIFIER(), bv);
    }

    function _request(uint64 assetId, uint64 publicIn) internal view returns (PubInputs.DepositRequest memory d) {
        return DepositFixture.request(assetId, publicIn, address(adapter), RECIPIENT, bytes32(uint256(0x1)));
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
        SpendFixture.fillOutputs(pi, 0x1111, 0x3333);
        pi.merkleRoot = masp.currentRoot();
    }

    /// Anchored at `pi.merkleRoot`'s slot; an unknown root gets slot 0.
    function _tpi(PubInputs.Transact memory pi) internal view returns (PubInputs.SpendTree memory) {
        (, uint256 anchorIndex) = masp.rootIndexOf(pi.merkleRoot);
        return SpendFixture.spendTree(bytes32(uint256(0xdead)), masp.committedCount(), uint8(anchorIndex));
    }

    /// Cancels directly at the pool, naming the adapter as payer. Kept out of
    /// the test body so the 8-argument call does not exceed the stack limit
    /// under the coverage build.
    function _poolCancel(uint256 id, uint64 publicIn, uint32 submittedAt) internal {
        masp.cancelDeposit(
            id,
            uint48(publicIn),
            bytes32(uint256(0x1)),
            [uint256(0), 0],
            ASSET_WETH,
            FEE_BPS,
            address(adapter),
            submittedAt,
            PubInputs.FeeNote({ feeIn: 0, feeAssetId: 0, feeCm: bytes32(uint256(0xfee)), feeCvDep: [uint256(0), 0] })
        );
    }

    /// Deposits `publicIn` units of the WETH asset through the adapter.
    function _deposit(address from, uint64 publicIn, uint256 value) internal returns (uint256 id) {
        vm.deal(from, value);
        vm.prank(from);
        id = adapter.depositNative{ value: value }(
            _request(ASSET_WETH, publicIn), SpendFixture.validAuxOutput(), SpendFixture.validAuxOutput()
        );
    }
}
