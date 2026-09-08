// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { uniformBps } from "../utils/FeeArrays.sol";
import {
    deployBehindProxy,
    deployPool,
    deployPoolUniform,
    newPoolImplementation,
    noAssets,
    poolInitCalldata,
    realVerifierStack,
    singleAsset
} from "../utils/PoolDeployer.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// The fee ceiling is the anti-rug bound and there is no path around it.
///
/// Without it the unshield path underflow-reverts on `outAmt - fee` (DoS) and
/// the shield path overcharges the payer beyond principal (silent economic
/// loss). `MAX_FEE_BPS` (20%) bounds both, and every write goes through
/// `_addAsset` or `setAssetFee` — there is no pool-wide rate to set.
contract MASPFeeBoundTest is Test {
    uint16 internal constant BPS = 2_000;
    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;

    IVerifier tubVerifier;
    IBatchVerifier batchVerifier;
    address permit2;
    MockERC20 token;
    MASP masp;

    function setUp() public {
        ISignatureTransfer p2;
        (tubVerifier, batchVerifier, p2) = realVerifierStack();
        permit2 = address(p2);
        token = new MockERC20("M", "M", 18);
        masp = _deployWithAsset(0);
    }

    /// Init calldata for a genesis set of one at `fee` on both legs, paired
    /// with a freshly-deployed implementation. Split out so a test can put
    /// `vm.expectRevert` immediately before the proxy construction — validation
    /// runs in `initialize`, and the implementation's own CREATE would
    /// otherwise consume the expectation.
    function _pendingAssetDeploy(uint16 fee) internal returns (MASP impl, bytes memory initData) {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, 1);
        impl = newPoolImplementation();
        initData = poolInitCalldata(
            tubVerifier,
            batchVerifier,
            ISignatureTransfer(permit2),
            ids,
            tokens,
            scales,
            uniformBps(ids.length, fee),
            uniformBps(ids.length, fee),
            address(0xfee),
            address(this)
        );
    }

    /// Genesis set of one, registered at `fee` on both legs.
    function _deployWithAsset(uint16 fee) internal returns (MASP) {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, 1);
        return deployPoolUniform(
            tubVerifier,
            batchVerifier,
            ISignatureTransfer(permit2),
            ids,
            tokens,
            scales,
            fee,
            address(0xfee),
            address(this)
        );
    }

    function _deployEmpty(uint16 fee) internal returns (MASP) {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = noAssets();
        return deployPoolUniform(
            tubVerifier,
            batchVerifier,
            ISignatureTransfer(permit2),
            ids,
            tokens,
            scales,
            fee,
            address(0xfee),
            address(this)
        );
    }

    // --- the ceiling -------------------------------------------------------

    function test_setAssetFee_acceptsAtBound() public {
        masp.setAssetFee(ASSET_ID, BPS, BPS);
        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, BPS);
        assertEq(wit, BPS);
    }

    function test_setAssetFee_rejectsAboveBound() public {
        vm.expectRevert(AssetRegistry.AssetFeeTooHigh.selector);
        masp.setAssetFee(ASSET_ID, BPS + 1, 0);
    }

    function test_setAssetFee_rejectsUint16Max() public {
        vm.expectRevert(AssetRegistry.AssetFeeTooHigh.selector);
        masp.setAssetFee(ASSET_ID, type(uint16).max, type(uint16).max);
    }

    function testFuzz_setAssetFee_bounds(uint16 dep, uint16 wit) public {
        if (dep > BPS || wit > BPS) {
            vm.expectRevert(AssetRegistry.AssetFeeTooHigh.selector);
            masp.setAssetFee(ASSET_ID, dep, wit);
        } else {
            masp.setAssetFee(ASSET_ID, dep, wit);
            (uint16 gotDep, uint16 gotWit) = masp.assetFees(ASSET_ID);
            assertEq(gotDep, dep);
            assertEq(gotWit, wit);
        }
    }

    // --- the genesis rate --------------------------------------------------

    function test_constructorWritesGenesisRateToBothLegs() public {
        MASP m = _deployWithAsset(BPS);
        (uint16 dep, uint16 wit) = m.assetFees(ASSET_ID);
        assertEq(dep, BPS, "genesis rate stored, not inherited");
        assertEq(wit, BPS);
    }

    function test_constructorRejectsGenesisRateAboveBound() public {
        (MASP impl, bytes memory initData) = _pendingAssetDeploy(BPS + 1);
        vm.expectRevert(AssetRegistry.AssetFeeTooHigh.selector);
        deployBehindProxy(address(impl), initData);
    }

    /// With no genesis assets there is nothing to register, so the rate arrays
    /// are never read and an out-of-range value is inert. Documented rather
    /// than guarded: nothing can later consult it.
    function test_emptyGenesisSetIgnoresTheRates() public {
        MASP m = _deployEmpty(type(uint16).max);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, ASSET_ID));
        m.assetFees(ASSET_ID);
    }

    // --- per-leg, per-asset registration -----------------------------------

    /// The shape the fee policy wants, applied at deploy: free to enter,
    /// charged on exit, and different per asset. This is what the config
    /// arrays exist to express.
    function test_constructorAppliesAsymmetricPerAssetRates() public {
        MockERC20 second = new MockERC20("N", "N", 18);

        uint64[] memory ids = new uint64[](2);
        IERC20[] memory tokens = new IERC20[](2);
        uint256[] memory scales = new uint256[](2);
        uint16[] memory dep = new uint16[](2);
        uint16[] memory wit = new uint16[](2);
        ids[0] = 1;
        tokens[0] = IERC20(address(token));
        scales[0] = 1;
        dep[0] = 0;
        wit[0] = 20;
        ids[1] = 2;
        tokens[1] = IERC20(address(second));
        scales[1] = 1;
        dep[1] = 0;
        wit[1] = 0;

        MASP m = deployPool(
            tubVerifier,
            batchVerifier,
            ISignatureTransfer(permit2),
            ids,
            tokens,
            scales,
            dep,
            wit,
            address(0xfee),
            address(this)
        );

        (uint16 d0, uint16 w0) = m.assetFees(1);
        assertEq(d0, 0, "asset 1 free to enter");
        assertEq(w0, 20, "asset 1 charged on exit");

        (uint16 d1, uint16 w1) = m.assetFees(2);
        assertEq(d1, 0, "asset 2 free on both legs");
        assertEq(w1, 0);
    }

    /// A short rate array would otherwise register the tail at whatever the
    /// arrays happened to hold, so the length check is load-bearing: a config
    /// that forgets an asset must fail the deploy, not ship a zero-rate one.
    function test_constructorRejectsRateArrayLengthMismatch() public {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), 1, 1);

        MASP impl = newPoolImplementation();
        bytes memory initData = poolInitCalldata(
            IVerifier(address(tubVerifier)),
            IBatchVerifier(address(batchVerifier)),
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            new uint16[](0), // depositBps short
            uniformBps(1, 20),
            address(0xfee),
            address(this)
        );

        vm.expectRevert(AssetRegistry.LengthMismatch.selector);
        deployBehindProxy(address(impl), initData);
    }
}
