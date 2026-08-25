// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { SwapWrapper } from "../../src/swap/SwapWrapper.sol";
import { UniV3Adapter } from "../../src/swap/UniV3Adapter.sol";

/// Shared adapter+wrapper deploy + KV log. Used by `DeploySwap.s.sol`
/// (mainnet) and `DeployTestSwap.s.sol` (anvil w/ mock router).
abstract contract BaseSwapDeploy is Script {
    function _requireCode(address a, string memory label) internal view {
        require(a.code.length != 0, label);
    }

    /// Pins next-CREATE address from broadcaster nonce so `UniV3Adapter`
    /// can take the wrapper address in its constructor before the wrapper
    /// is deployed. Asserts no drift after.
    function _deploySwapStack(address masp, address permit2, address router, address owner, address treasury)
        internal
        returns (UniV3Adapter adapter, SwapWrapper wrapper)
    {
        address predictedWrapper = vm.computeCreateAddress(tx.origin, vm.getNonce(tx.origin) + 1);
        adapter = new UniV3Adapter(router, predictedWrapper);
        // Constructed under the broadcaster so the `onlyOwner` adapter wiring
        // below succeeds when the deployer is not the configured owner, then
        // handed over in the same broadcast. `Ownable` is single-step, so the
        // owner needs no acceptance tx (and no gas) to take custody.
        wrapper = new SwapWrapper(IMASPPool(masp), IAllowanceTransfer(permit2), tx.origin, treasury);
        require(address(wrapper) == predictedWrapper, "wrapper address drift");
        wrapper.setAdapterAllowed(address(adapter), true);
        if (owner != tx.origin) wrapper.transferOwnership(owner);
    }

    function _prepareTokens(SwapWrapper wrapper, address[] memory tokens) internal {
        for (uint256 i; i < tokens.length; ++i) {
            _requireCode(tokens[i], "prepare token has no code");
            wrapper.prepareToken(IERC20(tokens[i]));
            console2.log("prepared token", tokens[i]);
        }
    }

    function _logSwapKv(address adapter, address wrapper) internal pure {
        console2.log(string.concat("UNIV3_ADAPTER=", vm.toString(adapter)));
        console2.log(string.concat("SWAP_WRAPPER=", vm.toString(wrapper)));
    }
}
