// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockWETH9 } from "../mocks/MockWETH9.sol";

import { FixtureLoader } from "./FixtureLoader.sol";
import { BatchedGroth16Verifier } from "../../src/verifiers/BatchedGroth16Verifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { deployPoolUniform, singleAsset } from "./PoolDeployer.sol";
import { TestConstants } from "./TestConstants.sol";

/// Shared deployment + setup harness for MASP unit tests. Wires up real
/// Groth16 verifiers, a real Uniswap Permit2, and a `MockERC20` registered
/// against the fixture asset id so the bundled proof verifies end-to-end.
///
/// The fixture payer is a hard-coded address (`0xface`) with no associated
/// private key, so Permit2 signatures from it are made acceptable by etching a
/// permissive ERC-1271 stub — `Stubs.installPermissiveERC1271`. Suites call it
/// themselves rather than inheriting it here: which address gets the stub, and
/// whether one is installed at all, is part of what a suite is testing.
contract MASPTestBase is Test {
    /// SCALE picked so `publicIn * SCALE * FEE_BPS / 10_000 != 0` — fixture
    /// publicIn=100 → fee=2.5e9 wei, exercises the FeeCollected branch.
    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant TREASURY = TestConstants.TREASURY;
    address internal constant OWNER = TestConstants.OWNER;
    TreeUpdateBatchGroth16Verifier internal tubVerifier;
    BatchedGroth16Verifier internal batchVerifier;
    address internal permit2;
    MockERC20 internal token;
    MockWETH9 internal weth;
    MASP internal masp;

    address internal relayer;
    address internal payer;

    function setUp() public virtual {
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        batchVerifier = new BatchedGroth16Verifier();
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("Test Token", "TST", 18);
        weth = new MockWETH9();

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(_fixtureAssetToken(), ASSET_ID, SCALE);

        masp = deployPoolUniform(
            IVerifier(address(tubVerifier)),
            IBatchVerifier(address(batchVerifier)),
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            FEE_BPS,
            TREASURY,
            OWNER
        );

        // Default test addresses; subclasses override to supply fixture-bound
        // payer/relayer addresses for the legacy Transact PI shape.
        payer = address(0xface);
        relayer = address(0xcafe);
    }

    /// Override to seat WETH (or any other token) at `ASSET_ID` at deploy time.
    /// Default = the plain MockERC20 created in `setUp`.
    function _fixtureAssetToken() internal view virtual returns (IERC20) {
        return IERC20(address(token));
    }

    function _emptyAux() internal pure returns (AuxValidation.Output[6] memory) {
        return FixtureLoader.emptyAux();
    }
}
