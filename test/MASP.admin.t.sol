// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../src/MASP.sol";
import { FeeConfig } from "../src/FeeConfig.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";

import { MASPTestBase } from "./utils/MASPTestBase.sol";

/// Owner-gated fee/treasury setters + constructor invariants.
contract MASPAdminTest is MASPTestBase {
    function testSetFeeBpsOnlyOwner() public {
        address attacker = address(0xa11ce);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        masp.setFeeBps(50);
    }

    function testSetFeeBpsUpdates() public {
        vm.prank(OWNER);
        masp.setFeeBps(50);
        assertEq(masp.feeBps(), 50);
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
            IVerifier(address(verifier)),
            IVerifier(address(tubVerifier)),
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            FEE_BPS,
            address(0),
            OWNER
        );
    }
}
