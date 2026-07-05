// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../src/MASP.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";

import { MASPTestBase } from "./utils/MASPTestBase.sol";

/// `withdrawNative` bridge: contract unwraps WETH and forwards raw ETH on the
/// unshield leg. Tests reuse the deposit fixture by re-binding the fixture's
/// asset id to the mock WETH (matching the fixture's gen) so the proof
/// verifies; `withdrawNative` rejects deposit-shape proofs at the
/// `NotAWithdraw` guard before SNARK verify.
///
/// Deposit-side ETH bridging was removed: users wrap ETH→WETH off-pool
/// (canonical WETH9) and shield via the standard `deposit` flow,
/// so there is no `depositEth` entry point to test.
contract MASPEthTest is MASPTestBase {
    /// Boot MASP with WETH at the fixture asset id so `withdrawNative` lookups
    /// resolve. Replaces the previous post-construction re-registration hack.
    function _fixtureAssetToken() internal view override returns (IERC20) {
        return IERC20(address(weth));
    }

    function testReceiveRejectsNonWethSender() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory data) = address(masp).call{ value: 1 }("");
        assertFalse(ok, "raw ETH transfer must revert");
        bytes4 sel;
        assembly {
            sel := mload(add(data, 32))
        }
        assertEq(sel, MASP.UnauthorizedNativeSender.selector);
    }
}
