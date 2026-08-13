// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { AssetRegistry } from "../src/AssetRegistry.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { Groth16Verifier } from "../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract MASPDeployTest is Test {
    string constant REGISTRY_FIXTURE = "test/fixtures/asset_registry.json";

    function test_AssetRegistered_EmittedForEachAsset() public {
        string memory j = vm.readFile(REGISTRY_FIXTURE);
        uint256[] memory rawIds = vm.parseJsonUintArray(j, ".ids");
        uint256[] memory scales = vm.parseJsonUintArray(j, ".scales");
        string[] memory names = vm.parseJsonStringArray(j, ".names");
        string[] memory symbols = vm.parseJsonStringArray(j, ".symbols");
        uint256[] memory decs = vm.parseJsonUintArray(j, ".decimals");

        uint256 n = rawIds.length;
        assertGt(n, 0, "fixture empty");

        Groth16Verifier verifier = new Groth16Verifier();
        TreeUpdateBatchGroth16Verifier tubVerifier = new TreeUpdateBatchGroth16Verifier();
        address permit2 = new DeployPermit2().deployPermit2();

        uint64[] memory ids = new uint64[](n);
        IERC20[] memory tokens = new IERC20[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = uint64(rawIds[i]);
            tokens[i] = IERC20(address(new MockERC20(names[i], symbols[i], uint8(decs[i]))));
        }

        // Predict the MASP address to scope `expectEmit` to its events.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        for (uint256 i; i < n; ++i) {
            vm.expectEmit(true, true, false, true, predicted);
            emit AssetRegistry.AssetRegistered(ids[i], tokens[i], scales[i]);
        }

        MASP masp = new MASP(
            IVerifier(address(verifier)),
            IVerifier(address(tubVerifier)),
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            25,
            address(0xfee),
            address(this)
        );
        assertEq(address(masp), predicted, "address prediction mismatch");

        for (uint256 i; i < n; ++i) {
            AssetRegistry.AssetEntry memory a = masp.asset(ids[i]);
            assertEq(address(a.token), address(tokens[i]));
            assertEq(a.scale, scales[i]);
        }
    }
}
