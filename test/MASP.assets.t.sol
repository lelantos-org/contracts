// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../src/MASP.sol";
import { AssetRegistry } from "../src/AssetRegistry.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

import { MASPTestBase } from "./utils/MASPTestBase.sol";

/// Registry is add-only with a per-asset `disabled` flag. There is no
/// destructive `setAssets`; the owner can never strand funds by removing
/// an asset the pool still holds notes for.
contract MASPAssetsTest is MASPTestBase {
    function testAddAssetRegistersEntry() public {
        MockERC20 newTok = new MockERC20("New", "NEW", 18);

        vm.prank(OWNER);
        masp.addAsset(2, IERC20(address(newTok)), 7);

        AssetRegistry.AssetEntry memory a = masp.asset(2);
        assertEq(address(a.token), address(newTok));
        assertEq(a.scale, 7);
        assertFalse(a.disabled);
    }

    function testAddAssetOnlyOwner() public {
        MockERC20 newTok = new MockERC20("New", "NEW", 18);
        address attacker = address(0xa11ce);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        masp.addAsset(2, IERC20(address(newTok)), 1);
    }

    function testAddAssetRevertsDuplicate() public {
        MockERC20 newTok = new MockERC20("New", "NEW", 18);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.DuplicateAsset.selector, ASSET_ID));
        masp.addAsset(ASSET_ID, IERC20(address(newTok)), 1);
    }

    function testAddAssetRevertsZeroToken() public {
        vm.prank(OWNER);
        vm.expectRevert(AssetRegistry.ZeroToken.selector);
        masp.addAsset(3, IERC20(address(0)), 1);
    }

    function testAddAssetRevertsZeroScale() public {
        MockERC20 newTok = new MockERC20("X", "X", 18);
        vm.prank(OWNER);
        vm.expectRevert(AssetRegistry.ZeroScale.selector);
        masp.addAsset(3, IERC20(address(newTok)), 0);
    }

    function testAddAssetEmitsRegistered() public {
        MockERC20 newTok = new MockERC20("New", "NEW", 18);
        vm.expectEmit(true, true, false, true, address(masp));
        emit AssetRegistry.AssetRegistered(7, IERC20(address(newTok)), 42);
        vm.prank(OWNER);
        masp.addAsset(7, IERC20(address(newTok)), 42);
    }

    function testSetAssetDisabledOnlyOwner() public {
        address attacker = address(0xa11ce);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        masp.setAssetDisabled(ASSET_ID, true);
    }

    function testSetAssetDisabledRevertsUnknown() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(99)));
        masp.setAssetDisabled(99, true);
    }

    function testSetAssetDisabledTogglesFlag() public {
        vm.expectEmit(true, false, false, true, address(masp));
        emit AssetRegistry.AssetDisabledSet(ASSET_ID, true);
        vm.prank(OWNER);
        masp.setAssetDisabled(ASSET_ID, true);

        AssetRegistry.AssetEntry memory a = masp.asset(ASSET_ID);
        assertTrue(a.disabled);

        vm.prank(OWNER);
        masp.setAssetDisabled(ASSET_ID, false);
        a = masp.asset(ASSET_ID);
        assertFalse(a.disabled);
    }

    function testDisabledAssetBlocksSubmit() public {
        vm.prank(OWNER);
        masp.setAssetDisabled(ASSET_ID, true);

        PubInputs.DepositIntent memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = 100;
        d.payer = address(0xface);
        d.recipient = address(0xb0b);
        d.outCm[0] = bytes32(uint256(0x1));
        d.outCm[1] = bytes32(uint256(0x2));

        AuxValidation.Output[2] memory aux = _emptyAux();
        MASP.Permit2Sig memory sig =
            MASP.Permit2Sig({ nonce: 0, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00" });

        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetDisabled.selector, ASSET_ID));
        masp.submitIntent(d, sig, aux);
    }

    function testUnknownAssetSubmitReverts() public {
        PubInputs.DepositIntent memory d;
        d.chainId = block.chainid;
        d.publicAssetId = 99;
        d.publicIn = 100;
        d.payer = address(0xface);
        d.recipient = address(0xb0b);
        d.outCm[0] = bytes32(uint256(0x1));
        d.outCm[1] = bytes32(uint256(0x2));

        AuxValidation.Output[2] memory aux = _emptyAux();
        MASP.Permit2Sig memory sig =
            MASP.Permit2Sig({ nonce: 0, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00" });
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(99)));
        masp.submitIntent(d, sig, aux);
    }
}
