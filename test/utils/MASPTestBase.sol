// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { Groth16Verifier } from "../../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { MockERC1271 } from "../mocks/MockERC1271.sol";

import { FixtureLoader } from "./FixtureLoader.sol";

/// Shared deployment + setup harness for MASP unit tests. Wires up real
/// Groth16 verifiers, a real Uniswap Permit2, and a `MockERC20` registered
/// against the fixture asset id so the bundled proof verifies end-to-end.
///
/// The fixture payer is a hard-coded address (`0xface`) with no associated
/// private key. Permit2 signatures from that payer are produced by etching a
/// permissive ERC-1271 stub at the payer address via `vm.etch`; Permit2's
/// `SignatureVerification` routes verification through `IERC1271` when the
/// signer has code, so the stub causes any signature bytes to be accepted.
/// Tests that need to reject signatures (bad sig / bad witness) deploy
/// without the stub and pin a real ECDSA signer instead.
contract MASPTestBase is Test {
    /// SCALE picked so `publicIn * SCALE * FEE_BPS / 10_000 != 0` — fixture
    /// publicIn=100 → fee=2.5e9 wei, exercises the FeeCollected branch.
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);

    Groth16Verifier internal verifier;
    TreeUpdateBatchGroth16Verifier internal tubVerifier;
    address internal permit2;
    MockERC20 internal token;
    MockWETH9 internal weth;
    MASP internal masp;

    address internal relayer;
    address internal payer;

    function setUp() public virtual {
        verifier = new Groth16Verifier();
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("Test Token", "TST", 18);
        weth = new MockWETH9();

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            _singleAssetArrays(ASSET_ID, _fixtureAssetToken(), SCALE);

        masp = new MASP(
            IVerifier(address(verifier)),
            IVerifier(address(tubVerifier)),
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

    /// Etch the permissive ERC-1271 stub bytecode at `target`. Idempotent:
    /// re-etching at the same address has no effect.
    function _installPermissiveERC1271(address target) internal {
        MockERC1271 stub = new MockERC1271();
        vm.etch(target, address(stub).code);
    }

    function _singleAssetArrays(uint64 id, IERC20 tok, uint256 scale)
        internal
        pure
        returns (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales)
    {
        ids = new uint64[](1);
        tokens = new IERC20[](1);
        scales = new uint256[](1);
        ids[0] = id;
        tokens[0] = tok;
        scales[0] = scale;
    }

    /// Build a single-entry registry payload.
    function _buildSingleAsset(uint64 id, address tok, uint256 scale)
        internal
        pure
        returns (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales)
    {
        return _singleAssetArrays(id, IERC20(tok), scale);
    }

    function _emptyAssets() internal pure returns (uint64[] memory, IERC20[] memory, uint256[] memory) {
        return (new uint64[](0), new IERC20[](0), new uint256[](0));
    }

    /// Override to seat WETH (or any other token) at `ASSET_ID` at deploy time.
    /// Default = the plain MockERC20 created in `setUp`.
    function _fixtureAssetToken() internal view virtual returns (IERC20) {
        return IERC20(address(token));
    }

    function _emptyAux() internal pure returns (AuxValidation.Output[3] memory) {
        return FixtureLoader.emptyAux();
    }
}
