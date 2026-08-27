// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { UniV3Adapter } from "../../src/swap/UniV3Adapter.sol";
import { UniV4Adapter } from "../../src/swap/UniV4Adapter.sol";

/// Shared adapter+wrapper deploy + KV log. Used by `DeploySwap.s.sol`
/// (mainnet) and `DeployTestSwap.s.sol` (anvil w/ mock routers).
abstract contract BaseSwapDeploy is Script {
    function _requireCode(address a, string memory label) internal view {
        require(a.code.length != 0, label);
    }

    /// Pins the next-CREATE wrapper address from the broadcaster nonce so each
    /// adapter can take the wrapper address in its constructor before the
    /// wrapper is deployed. Asserts no drift after.
    ///
    /// The nonce offset is the number of adapters deployed ahead of the
    /// wrapper, so it must track `univ4Router` being present or not — a
    /// hardcoded offset silently mispredicts the address as soon as a second
    /// adapter exists.
    ///
    /// `univ4Router == address(0)` deploys the V3-only stack, which is what a
    /// config with no `univ4Router` key gets.
    function _deploySwapStack(
        address masp,
        address permit2,
        address univ3Router,
        address univ4Router,
        address owner,
        address treasury
    ) internal returns (UniV3Adapter v3, UniV4Adapter v4, SwapWrapper wrapper) {
        uint256 adapterCount = univ4Router == address(0) ? 1 : 2;
        address predictedWrapper = vm.computeCreateAddress(tx.origin, vm.getNonce(tx.origin) + adapterCount);

        v3 = new UniV3Adapter(univ3Router, predictedWrapper);
        if (univ4Router != address(0)) v4 = new UniV4Adapter(univ4Router, predictedWrapper);

        // Constructed under the broadcaster so the `onlyOwner` adapter wiring
        // below succeeds when the deployer is not the configured owner, then
        // handed over in the same broadcast. `Ownable` is single-step, so the
        // owner needs no acceptance tx (and no gas) to take custody.
        wrapper = new SwapWrapper(IMASPPool(masp), IAllowanceTransfer(permit2), tx.origin, treasury);
        require(address(wrapper) == predictedWrapper, "wrapper address drift");

        wrapper.setAdapterAllowed(address(v3), true);
        if (address(v4) != address(0)) wrapper.setAdapterAllowed(address(v4), true);
        if (owner != tx.origin) wrapper.transferOwnership(owner);
    }

    function _prepareTokens(SwapWrapper wrapper, address[] memory tokens) internal {
        for (uint256 i; i < tokens.length; ++i) {
            _requireCode(tokens[i], "prepare token has no code");
            wrapper.prepareToken(IERC20(tokens[i]));
            console2.log("prepared token", tokens[i]);
        }
    }

    /// `univ4Adapter` is logged as the zero address on a V3-only deploy, so the
    /// key is always present and downstream parsers need no conditional.
    function _logSwapKv(address univ3Adapter, address univ4Adapter, address wrapper) internal pure {
        console2.log(string.concat("UNIV3_ADAPTER=", vm.toString(univ3Adapter)));
        console2.log(string.concat("UNIV4_ADAPTER=", vm.toString(univ4Adapter)));
        console2.log(string.concat("SWAP_WRAPPER=", vm.toString(wrapper)));
    }
}
