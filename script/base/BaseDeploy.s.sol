// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";
import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { IMASPNative } from "../../src/native/IMASPNative.sol";
import { Groth16Verifier } from "../../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";
import { BatchedGroth16Verifier } from "../../src/verifiers/BatchedGroth16Verifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";

/// Shared MASP-core deploy + KEY=value logging for `Deploy.s.sol` and
/// `DeployTest.s.sol`. Abstract `Script` (not library) — helpers call
/// `vm.*` cheatcodes which libraries cannot access.
abstract contract BaseDeploy is Script {
    struct MaspParams {
        address permit2;
        /// Wrapped native coin (WETH/WBNB/etc). Pass address(0) to skip the
        /// `NativeAdapter` deploy; the pool itself is ERC-20 only either way.
        address wrappedNative;
        uint64[] ids;
        IERC20[] tokens;
        uint256[] scales;
        uint16 feeBps;
        address treasury;
        address owner;
    }

    /// The contracts one core deploy produces. A struct rather than a return
    /// tuple: every member is a plain address at the log boundary, where a
    /// positional list would be mis-orderable without a compiler error.
    struct MaspCore {
        TreeUpdateBatchGroth16Verifier tubVerifier;
        BatchedGroth16Verifier spendVerifier;
        MASP masp;
        /// address(0) when the chain configures no wrapped-native token.
        NativeAdapter nativeAdapter;
    }

    function _requireCode(address a, string memory label) internal view {
        require(a.code.length != 0, label);
    }

    function _deployMaspCore(MaspParams memory p) internal returns (MaspCore memory core) {
        core.tubVerifier = new TreeUpdateBatchGroth16Verifier();
        core.spendVerifier = new BatchedGroth16Verifier();
        core.masp = new MASP(
            IVerifier(address(core.tubVerifier)),
            IBatchVerifier(address(core.spendVerifier)),
            ISignatureTransfer(p.permit2),
            p.ids,
            p.tokens,
            p.scales,
            p.feeBps,
            p.treasury,
            p.owner
        );
        // Native coin never touches the pool: the adapter wraps on the way in
        // and unwraps on the way out. Skipped when no wrapped-native token is
        // configured for the chain.
        if (p.wrappedNative != address(0)) {
            core.nativeAdapter = new NativeAdapter(
                IMASPNative(address(core.masp)), IWrappedNative(p.wrappedNative), IAllowanceTransfer(p.permit2)
            );
        }
    }

    /// KEY=value log block scraped by `e2e/src/stack.ts` and
    /// `backend/stack/scripts/deploy-contracts.sh`.
    function _logCoreKv(MaspCore memory core, MaspParams memory p, address[] memory tokenAddrs) internal pure {
        console2.log(string.concat("TREE_UPDATE_BATCH_VERIFIER=", vm.toString(address(core.tubVerifier))));
        console2.log(string.concat("SPEND_VERIFIER=", vm.toString(address(core.spendVerifier))));
        console2.log(string.concat("MASP=", vm.toString(address(core.masp))));
        console2.log(string.concat("PERMIT2=", vm.toString(p.permit2)));
        for (uint256 i; i < p.ids.length; ++i) {
            console2.log(string.concat("TOKEN_", vm.toString(uint256(p.ids[i])), "=", vm.toString(tokenAddrs[i])));
        }
        if (p.wrappedNative != address(0)) {
            console2.log(string.concat("WRAPPED_NATIVE=", vm.toString(p.wrappedNative)));
            console2.log(string.concat("NATIVE_ADAPTER=", vm.toString(address(core.nativeAdapter))));
        }
    }
}
