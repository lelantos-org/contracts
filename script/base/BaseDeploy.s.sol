// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";
import { Groth16Verifier } from "../../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";

/// Shared MASP-core deploy + KEY=value logging for `Deploy.s.sol` and
/// `DeployTest.s.sol`. Abstract `Script` (not library) — helpers call
/// `vm.*` cheatcodes which libraries cannot access.
abstract contract BaseDeploy is Script {
    struct MaspParams {
        address permit2;
        /// Wrapped native coin (WETH/WBNB/etc). Pass address(0) to disable native flows.
        address wrappedNative;
        uint64[] ids;
        IERC20[] tokens;
        uint256[] scales;
        uint16 feeBps;
        address treasury;
        address owner;
    }

    function _requireCode(address a, string memory label) internal view {
        require(a.code.length != 0, label);
    }

    function _deployMaspCore(MaspParams memory p)
        internal
        returns (Groth16Verifier verifier, TreeUpdateBatchGroth16Verifier tubVerifier, MASP masp)
    {
        verifier = new Groth16Verifier();
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        masp = new MASP(
            IVerifier(address(verifier)),
            IVerifier(address(tubVerifier)),
            ISignatureTransfer(p.permit2),
            IWrappedNative(p.wrappedNative),
            p.ids,
            p.tokens,
            p.scales,
            p.feeBps,
            p.treasury,
            p.owner
        );
    }

    /// KEY=value log block consumed by `e2e/deploy/extract-addresses.sh`.
    function _logCoreKv(
        address verifier,
        address tubVerifier,
        address masp,
        address permit2,
        address wrappedNative,
        uint64[] memory ids,
        address[] memory tokenAddrs
    ) internal pure {
        console2.log(string.concat("VERIFIER=", vm.toString(verifier)));
        console2.log(string.concat("TREE_UPDATE_BATCH_VERIFIER=", vm.toString(tubVerifier)));
        console2.log(string.concat("MASP=", vm.toString(masp)));
        console2.log(string.concat("PERMIT2=", vm.toString(permit2)));
        for (uint256 i; i < ids.length; ++i) {
            console2.log(string.concat("TOKEN_", vm.toString(uint256(ids[i])), "=", vm.toString(tokenAddrs[i])));
        }
        if (wrappedNative != address(0)) {
            console2.log(string.concat("WRAPPED_NATIVE=", vm.toString(wrappedNative)));
        }
    }
}
