// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../src/MASP.sol";
import { FeeConfig } from "../src/FeeConfig.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";

import { MASPTestBase } from "./utils/MASPTestBase.sol";
import { IBatchVerifier } from "../src/interfaces/IBatchVerifier.sol";
import { uniformBps } from "./utils/FeeArrays.sol";

/// Owner-gated fee/treasury setters + constructor invariants.
contract MASPAdminTest is MASPTestBase {
    function testSetAssetFeeOnlyOwner() public {
        address attacker = address(0xa11ce);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        masp.setAssetFee(ASSET_ID, 50, 50);
    }

    function testSetAssetFeeUpdates() public {
        vm.prank(OWNER);
        masp.setAssetFee(ASSET_ID, 50, 60);
        (uint16 dep, uint16 wit) = masp.assetFees(ASSET_ID);
        assertEq(dep, 50);
        assertEq(wit, 60);
    }

    function testSetTreasuryZeroReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(FeeConfig.ZeroTreasury.selector);
        masp.setTreasury(address(0));
    }

    function testSetTreasuryUpdates() public {
        address newTreasury = address(0xbeef);
        vm.prank(OWNER);
        masp.setTreasury(newTreasury);
        assertEq(masp.treasury(), newTreasury);
    }

    function testSetTreasuryOnlyOwner() public {
        address attacker = address(0xa11ce);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        masp.setTreasury(address(0xbeef));
    }

    function testConstructorRejectsZeroTreasury() public {
        uint64[] memory ids = new uint64[](0);
        IERC20[] memory tokens = new IERC20[](0);
        uint256[] memory scales = new uint256[](0);

        vm.expectRevert(FeeConfig.ZeroTreasury.selector);
        new MASP(
            IVerifier(address(tubVerifier)),
            IBatchVerifier(address(batchVerifier)),
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            uniformBps(ids.length, FEE_BPS),
            uniformBps(ids.length, FEE_BPS),
            address(0),
            OWNER
        );
    }
}
