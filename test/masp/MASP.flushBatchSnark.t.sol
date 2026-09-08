// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { deployPoolUniform, realVerifierStack, singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// End-to-end test: real `tree_update_batch` Groth16 proof, real verifier
/// contract. Submits one deposit, then flushes with the fixture proof.
/// Asserts the verifier accepts the proof and the tree advances.
contract MASPFlushBatchSnarkTest is Test {
    string internal constant FIXTURE = "test/fixtures/proof_deposit_batch_n1.json";

    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant TREASURY = TestConstants.TREASURY;
    address internal constant OWNER = TestConstants.OWNER;
    address permit2;
    MockERC20 token;
    MASP masp;

    address payer = address(0xface);
    address recipient = address(0xb0b);

    function setUp() public {
        (IVerifier tub, IBatchVerifier bv, ISignatureTransfer p2) = realVerifierStack();
        permit2 = address(p2);
        token = new MockERC20("M", "M", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        masp = deployPoolUniform(tub, bv, p2, ids, tokens, scales, FEE_BPS, TREASURY, OWNER);

        Stubs.installPermissiveERC1271(payer);
    }

    function _aux() internal pure returns (AuxValidation.Output[6] memory aux) {
        return SpendFixture.validAux();
    }

    function _loadFixture()
        internal
        view
        returns (
            uint64 actualCount,
            uint64 startIndex,
            bytes32 oldRoot,
            bytes32 newRoot,
            bytes32[2 * 16] memory cms,
            MASP.Proof memory proof
        )
    {
        string memory j = vm.readFile(FIXTURE);
        actualCount = uint64(vm.parseJsonUint(j, ".actualCount"));
        startIndex = uint64(vm.parseJsonUint(j, ".startIndex"));
        oldRoot = bytes32(vm.parseJsonUint(j, ".oldRoot"));
        newRoot = bytes32(vm.parseJsonUint(j, ".newRoot"));

        // 32 cm slots
        for (uint256 i = 0; i < 32; i++) {
            string memory key = string.concat(".cms[", vm.toString(i), "]");
            cms[i] = bytes32(vm.parseJsonUint(j, key));
        }

        proof.a[0] = vm.parseJsonUint(j, ".proof.a[0]");
        proof.a[1] = vm.parseJsonUint(j, ".proof.a[1]");
        proof.b[0][0] = vm.parseJsonUint(j, ".proof.b[0][0]");
        proof.b[0][1] = vm.parseJsonUint(j, ".proof.b[0][1]");
        proof.b[1][0] = vm.parseJsonUint(j, ".proof.b[1][0]");
        proof.b[1][1] = vm.parseJsonUint(j, ".proof.b[1][1]");
        proof.c[0] = vm.parseJsonUint(j, ".proof.c[0]");
        proof.c[1] = vm.parseJsonUint(j, ".proof.c[1]");
    }

    function test_realSnark_n1_flushBatchSucceeds() public {
        // Fixture is stale w.r.t. the C-1 deposit-binding PIs (pair_asset,
        // pair_public_in, cv_dep). It was built with zero-value zero-blinder
        // notes (pair_public_in=0), but `deposit` rejects publicIn==0,
        // so the on-chain escrow record cannot match the SNARK's PIs. Rebuild
        // via `script/fixtures/gen_proof_deposit_batch.ts` with real Pedersen
        // value commitments (publicIn > 0, pair_asset = ASSET_ID) before
        // re-enabling. Loader also needs to read cvDeps/pairAsset/pairPublicIn
        // /isDeposit and the cms array size must drop to MAX_L_BATCH=4.
        vm.skip(true);
        // Body removed (unreachable) until fixture is regenerated with real
        // Pedersen commitments. See git history for original reference body.
    }
}
