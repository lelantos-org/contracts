// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { DepositFixture } from "../utils/DepositFixture.sol";
import { MASPTestBase } from "../utils/MASPTestBase.sol";

/// The registry is add-only with a per-asset `disabled` flag. No entry can be
/// removed, so the owner cannot strand funds by removing an asset the pool
/// still holds notes for.
contract MASPAssetsTest is MASPTestBase {
    /// Submits a fixture deposit of `assetId`. The registry is consulted
    /// before any token moves, so the payer is unfunded and the signature a
    /// placeholder. `masp.deposit` is the only external call, so an expectation
    /// set just before applies to the deposit itself.
    function _deposit(uint64 assetId) internal {
        PubInputs.DepositRequest memory d =
            DepositFixture.request(assetId, 100, payer, address(0xb0b), bytes32(uint256(0x1)));
        AuxValidation.Output[6] memory aux = _emptyAux();
        masp.deposit(d, DepositFixture.sig(0), aux[0], aux[1]);
    }

    function test_addAssetRegistersEntry() public {
        MockERC20 newTok = new MockERC20("New", "NEW", 18);

        vm.prank(OWNER);
        masp.addAsset(2, IERC20(address(newTok)), 7, 11, 13);

        AssetRegistry.AssetEntry memory a = masp.asset(2);
        assertEq(address(a.token), address(newTok));
        assertEq(a.scale, 7);
        assertFalse(a.disabled);
    }

    function test_addAssetOnlyOwner() public {
        MockERC20 newTok = new MockERC20("New", "NEW", 18);
        address attacker = address(0xa11ce);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        masp.addAsset(2, IERC20(address(newTok)), 1, 0, 0);
    }

    function test_addAssetRevertsDuplicate() public {
        MockERC20 newTok = new MockERC20("New", "NEW", 18);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.DuplicateAsset.selector, ASSET_ID));
        masp.addAsset(ASSET_ID, IERC20(address(newTok)), 1, 0, 0);
    }

    function test_addAssetRevertsZeroToken() public {
        vm.prank(OWNER);
        vm.expectRevert(AssetRegistry.ZeroToken.selector);
        masp.addAsset(3, IERC20(address(0)), 1, 0, 0);
    }

    function test_addAssetRevertsZeroScale() public {
        MockERC20 newTok = new MockERC20("X", "X", 18);
        vm.prank(OWNER);
        vm.expectRevert(AssetRegistry.ZeroScale.selector);
        masp.addAsset(3, IERC20(address(newTok)), 0, 0, 0);
    }

    /// Asset id 0 is reserved: it means "no asset" to the circuits, which is
    /// what a transfer's `publicAssetId` and a zero-value fee note carry, and
    /// they refuse value under it. An otherwise valid registration of it is
    /// refused, and the id stays unregistered.
    function test_addAssetRevertsZeroAssetId() public {
        MockERC20 newTok = new MockERC20("X", "X", 18);
        vm.prank(OWNER);
        vm.expectRevert(AssetRegistry.ZeroAssetId.selector);
        masp.addAsset(0, IERC20(address(newTok)), 1, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(0)));
        masp.asset(0);
    }

    /// The yield registration goes through the same check, before any venue
    /// binding is attempted.
    function test_addYieldAssetRevertsZeroAssetId() public {
        MockERC20 newTok = new MockERC20("X", "X", 18);
        vm.prank(OWNER);
        vm.expectRevert(AssetRegistry.ZeroAssetId.selector);
        masp.addYieldAsset(0, IERC20(address(newTok)), 1, 0, 0, address(0xbeef), 0, 0);
    }

    /// Because asset 0 cannot be registered, a deposit naming it is always a
    /// deposit of an unknown asset.
    function test_depositOfAssetZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(0)));
        _deposit(0);
    }

    function test_addAssetEmitsRegistered() public {
        MockERC20 newTok = new MockERC20("New", "NEW", 18);
        vm.expectEmit(true, true, false, true, address(masp));
        emit AssetRegistry.AssetRegistered(7, IERC20(address(newTok)), 42);
        vm.prank(OWNER);
        masp.addAsset(7, IERC20(address(newTok)), 42, 0, 0);
    }

    function test_setAssetDisabledOnlyOwner() public {
        address attacker = address(0xa11ce);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        masp.setAssetDisabled(ASSET_ID, true);
    }

    function test_setAssetDisabledRevertsUnknown() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(99)));
        masp.setAssetDisabled(99, true);
    }

    function test_setAssetDisabledTogglesFlag() public {
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

    function test_disabledAssetBlocksSubmit() public {
        vm.prank(OWNER);
        masp.setAssetDisabled(ASSET_ID, true);

        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetDisabled.selector, ASSET_ID));
        _deposit(ASSET_ID);
    }

    function test_unknownAssetSubmitReverts() public {
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, uint64(99)));
        _deposit(99);
    }
}
