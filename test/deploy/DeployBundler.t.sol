// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { BaseDeploy } from "../../script/base/BaseDeploy.s.sol";
import { BaseBundlerDeploy } from "../../script/base/BaseBundlerDeploy.s.sol";
import { Bundler } from "../../src/bundler/Bundler.sol";
import { BundlerFactory } from "../../src/bundler/BundlerFactory.sol";
import { OwnableInit } from "../../src/OwnableInit.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { uniformBps } from "../utils/FeeArrays.sol";
import { singleAsset } from "../utils/PoolDeployer.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { BaseDeployHarness } from "./DeployBase.t.sol";

/// The swap scripts' tail: the wrapper, then the factory over MASP, the native
/// adapter and the wrapper, then the deployer's Bundler.
contract BundlerDeployHarness is BaseBundlerDeploy {
    /// The wrapper is deployed plainly: `_deploySwapStack` predicts its address
    /// from `tx.origin`'s nonce, which only holds under a broadcast.
    function deployBundler(BaseDeploy.MaspCore memory core, address operator, address owner)
        external
        returns (SwapWrapper wrapper, BundlerFactory factory, Bundler bundler)
    {
        wrapper = new SwapWrapper(
            IMASPPool(address(core.masp)), core.nativeAdapter.PERMIT2(), address(this), address(0xfee)
        );
        factory = _deployBundlerFactory(address(core.masp), address(core.nativeAdapter), address(wrapper));
        bundler = _createBundler(factory, operator, owner);
    }

    function createBundlerFromEnv(BundlerFactory factory, bool ownerRequired) external returns (Bundler) {
        return _createBundlerFromEnv(factory, ownerRequired);
    }
}

contract DeployBundlerTest is Test {
    uint64 internal constant ASSET_WETH = 1;
    address internal constant OPERATOR = address(0x0FE7A70);
    address internal constant BUNDLER_OWNER = address(0xB0551);

    BaseDeployHarness internal core_;
    BundlerDeployHarness internal harness;
    MockWETH9 internal weth;
    address internal permit2;

    function setUp() public {
        core_ = new BaseDeployHarness();
        harness = new BundlerDeployHarness();
        weth = new MockWETH9();
        permit2 = new DeployPermit2().deployPermit2();
    }

    function _params() internal view returns (BaseDeploy.MaspParams memory p) {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(weth)), ASSET_WETH, TestConstants.SCALE);
        p.permit2 = permit2;
        p.wrappedNative = address(weth);
        p.ids = ids;
        p.tokens = tokens;
        p.scales = scales;
        p.depositBps = uniformBps(1, 25);
        p.withdrawBps = uniformBps(1, 25);
        p.treasury = address(0xfee);
        p.owner = address(this);
        p.proxyAdmin = address(0x9403);
        p.upgradeDelay = 30 days;
        p.maxPause = 7 days;
    }

    function test_factoryFixesTheDeployedTargets() public {
        BaseDeploy.MaspCore memory core = core_.deployCore(_params());
        (SwapWrapper wrapper, BundlerFactory factory, Bundler bundler) =
            harness.deployBundler(core, OPERATOR, address(harness));

        assertEq(factory.POOL(), address(core.masp), "factory pool");
        assertEq(factory.NATIVE_ADAPTER(), address(core.nativeAdapter), "factory native adapter");
        assertEq(factory.SWAP_WRAPPER(), address(wrapper), "factory wrapper");

        assertEq(address(bundler), factory.predict(address(harness)), "deployer's Bundler");
        assertEq(bundler.owner(), address(harness), "deployer owns it");
        assertTrue(bundler.isOperator(OPERATOR), "operator set");
        assertEq(bundler.POOL(), address(core.masp), "bundler pool");
        assertEq(bundler.NATIVE_ADAPTER(), address(core.nativeAdapter), "bundler native adapter");
        assertEq(bundler.SWAP_WRAPPER(), address(wrapper), "bundler wrapper");
    }

    /// A named owner other than the deployer receives the Bundler, which keeps
    /// the deployer's address.
    function test_bundlerHandedToNamedOwner() public {
        BaseDeploy.MaspCore memory core = core_.deployCore(_params());
        (, BundlerFactory factory, Bundler bundler) = harness.deployBundler(core, OPERATOR, BUNDLER_OWNER);

        assertEq(address(bundler), factory.predict(address(harness)), "address is the deployer's");
        assertEq(bundler.owner(), BUNDLER_OWNER, "named owner owns it");
        assertTrue(bundler.isOperator(OPERATOR), "operator set");

        vm.expectRevert(abi.encodeWithSelector(OwnableInit.OwnableUnauthorizedAccount.selector, address(harness)));
        vm.prank(address(harness));
        bundler.setOperator(address(0xBAD), true);
    }

    /// With the owner required, an operator without an owner is refused rather
    /// than leaving the deploy key in charge.
    function test_createFromEnv_ownerRequired() public {
        BaseDeploy.MaspCore memory core = core_.deployCore(_params());
        (, BundlerFactory factory,) = harness.deployBundler(core, OPERATOR, address(harness));
        BundlerDeployHarness other = new BundlerDeployHarness();

        vm.setEnv("BUNDLER_OPERATOR", vm.toString(OPERATOR));
        vm.setEnv("BUNDLER_OWNER", vm.toString(address(0)));
        vm.expectRevert(bytes("BUNDLER_OWNER unset"));
        other.createBundlerFromEnv(factory, true);

        vm.setEnv("BUNDLER_OWNER", vm.toString(BUNDLER_OWNER));
        Bundler bundler = other.createBundlerFromEnv(factory, true);
        assertEq(bundler.owner(), BUNDLER_OWNER, "env owner owns it");
    }

    /// The factory is deployed after the wrapper it names; a wrapper address
    /// with no code behind it is refused.
    function test_factoryRefusesACodelessWrapper() public {
        BaseDeploy.MaspCore memory core = core_.deployCore(_params());
        assertGt(address(core.masp).code.length, 0, "pool deployed");
        vm.expectRevert(abi.encodeWithSelector(BundlerFactory.NotAContract.selector, address(0xdead)));
        new BundlerFactory(address(core.masp), address(core.nativeAdapter), address(0xdead));
    }
}
