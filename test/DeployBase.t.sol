// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { NativeAdapter } from "../src/native/NativeAdapter.sol";
import { Groth16Verifier } from "../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";
import { BaseDeploy } from "../script/base/BaseDeploy.s.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockWETH9 } from "./mocks/MockWETH9.sol";

/// Exposes the shared deploy helper both deploy scripts route through.
contract BaseDeployHarness is BaseDeploy {
    function deployCore(MaspParams memory p)
        external
        returns (Groth16Verifier v, TreeUpdateBatchGroth16Verifier tub, MASP masp, NativeAdapter na)
    {
        return _deployMaspCore(p);
    }
}

/// `BaseDeploy._deployMaspCore` wiring: the pool takes no wrapped-native
/// argument at all, and the `NativeAdapter` is deployed — and pre-armed —
/// only when the chain config names a wrapped-native token.
contract DeployBaseTest is Test {
    uint64 internal constant ASSET_WETH = 1;
    uint256 internal constant SCALE = 1e10;

    BaseDeployHarness internal harness;
    MockWETH9 internal weth;
    address internal permit2;

    function setUp() public {
        harness = new BaseDeployHarness();
        weth = new MockWETH9();
        permit2 = new DeployPermit2().deployPermit2();
    }

    function _params(address wrappedNative) internal view returns (BaseDeploy.MaspParams memory p) {
        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = ASSET_WETH;
        tokens[0] = IERC20(address(weth));
        scales[0] = SCALE;

        p.permit2 = permit2;
        p.wrappedNative = wrappedNative;
        p.ids = ids;
        p.tokens = tokens;
        p.scales = scales;
        p.feeBps = 25;
        p.treasury = address(0xfee);
        p.owner = address(this);
    }

    function test_deploysAdapterWiredToPoolAndWrappedNative() public {
        (,, MASP masp, NativeAdapter na) = harness.deployCore(_params(address(weth)));

        assertTrue(address(na) != address(0), "adapter deployed");
        assertEq(address(na.POOL()), address(masp), "adapter points at the pool");
        assertEq(address(na.WRAPPED_NATIVE()), address(weth), "adapter points at the wrapped native");
        assertEq(address(na.PERMIT2()), permit2, "adapter points at permit2");
    }

    /// The constructor arms ERC20 → Permit2 → MASP, so the first
    /// `depositNative` needs no bootstrap transaction.
    function test_deployedAdapterIsArmed() public {
        (,, MASP masp, NativeAdapter na) = harness.deployCore(_params(address(weth)));

        assertEq(weth.allowance(address(na), permit2), type(uint256).max, "erc20 allowance to permit2");
        (uint160 amount, uint48 expiration,) =
            IAllowanceTransfer(permit2).allowance(address(na), address(weth), address(masp));
        assertEq(amount, type(uint160).max, "permit2 allowance to the pool");
        assertEq(expiration, type(uint48).max, "allowance never expires");
    }

    /// Chains with no wrapped-native token skip the adapter; the pool itself
    /// is unaffected either way.
    function test_skipsAdapterWhenNoWrappedNative() public {
        (,, MASP masp, NativeAdapter na) = harness.deployCore(_params(address(0)));

        assertEq(address(na), address(0), "no adapter deployed");
        assertEq(address(masp.asset(ASSET_WETH).token), address(weth), "registry still written");
    }

    /// The pool never holds native coin, whether or not an adapter exists.
    function test_deployedPoolRejectsNative() public {
        (,, MASP masp,) = harness.deployCore(_params(address(weth)));
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(masp).call{ value: 1 }("");
        assertFalse(ok, "pool must not accept native");
    }
}
