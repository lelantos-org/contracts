// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../src/MASP.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";

import { MASPTestBase } from "./utils/MASPTestBase.sol";

/// `submitIntentNative` — payable deposit path that wraps msg.value into
/// WETH inside the contract. Asset must resolve to canonical WETH;
/// msg.sender authorizes the deposit (no Permit2 binding).
contract MASPSubmitIntentNativeTest is MASPTestBase {
    address internal natPayer;
    address internal natRecipient;

    function setUp() public override {
        super.setUp();
        natPayer = address(0xa11ce);
        natRecipient = address(0xb0b);
        vm.deal(natPayer, 100 ether);
    }

    /// Construct MASP with WETH bound to the fixture asset id directly.
    function _fixtureAssetToken() internal view override returns (IERC20) {
        return IERC20(address(weth));
    }

    function _intent(uint64 publicIn) internal view returns (PubInputs.DepositIntent memory d) {
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = natPayer;
        d.recipient = natRecipient;
        d.outCm = bytes32(uint256(0xdead));
    }

    function _aux() internal pure returns (AuxValidation.Output[3] memory aux) {
        aux[0].clueRx = BabyJubJub.BASE8_X;
        aux[0].clueRy = BabyJubJub.BASE8_Y;
        aux[0].ephPubX = BabyJubJub.BASE8_X;
        aux[0].ephPubY = BabyJubJub.BASE8_Y;
        aux[0].ciphertext = hex"0001";
        aux[1].clueRx = BabyJubJub.BASE8_X;
        aux[1].clueRy = BabyJubJub.BASE8_Y;
        aux[1].ephPubX = BabyJubJub.BASE8_X;
        aux[1].ephPubY = BabyJubJub.BASE8_Y;
        aux[1].ciphertext = hex"0001";
        aux[2].clueRx = BabyJubJub.BASE8_X;
        aux[2].clueRy = BabyJubJub.BASE8_Y;
        aux[2].ephPubX = BabyJubJub.BASE8_X;
        aux[2].ephPubY = BabyJubJub.BASE8_Y;
        aux[2].ciphertext = hex"0001";
    }

    function _expectedTotal(uint64 publicIn) internal pure returns (uint256) {
        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;
        return inAmt + fee;
    }

    function testHappyPathDepositsAndWraps() public {
        uint64 amt = 100;
        uint256 total = _expectedTotal(amt);
        PubInputs.DepositIntent memory d = _intent(amt);
        AuxValidation.Output[3] memory aux = _aux();

        uint256 maspWethBefore = weth.balanceOf(address(masp));
        uint256 payerEthBefore = natPayer.balance;

        vm.prank(natPayer);
        uint256 id = masp.submitIntentNative{ value: total }(d, aux[0]);

        assertEq(id, 0);
        assertEq(weth.balanceOf(address(masp)), maspWethBefore + total, "MASP WETH credited");
        assertEq(natPayer.balance, payerEthBefore - total, "payer ETH debited");

        // Escrow slot holds the digest binding payer + asset (and the rest
        // of the preimage); reconstruct and compare.
        bytes32 expectedDigest = keccak256(
            abi.encode(
                address(masp),
                block.chainid,
                id,
                d.outCm,
                d.cvDep,
                uint64(ASSET_ID),
                uint48(amt),
                uint16(FEE_BPS),
                natPayer,
                uint32(block.number)
            )
        );
        assertEq(masp.escrowed(id), expectedDigest, "digest binds payer + asset");
    }

    function testRevertsOnMsgValueTooLow() public {
        PubInputs.DepositIntent memory d = _intent(100);
        AuxValidation.Output[3] memory aux = _aux();
        uint256 total = _expectedTotal(100);

        vm.prank(natPayer);
        vm.expectRevert(MASP.MsgValueMismatch.selector);
        masp.submitIntentNative{ value: total - 1 }(d, aux[0]);
    }

    function testRevertsOnMsgValueTooHigh() public {
        PubInputs.DepositIntent memory d = _intent(100);
        AuxValidation.Output[3] memory aux = _aux();
        uint256 total = _expectedTotal(100);

        vm.prank(natPayer);
        vm.expectRevert(MASP.MsgValueMismatch.selector);
        masp.submitIntentNative{ value: total + 1 }(d, aux[0]);
    }

    function testRevertsOnSenderNotPayer() public {
        PubInputs.DepositIntent memory d = _intent(100);
        AuxValidation.Output[3] memory aux = _aux();
        uint256 total = _expectedTotal(100);

        address other = address(0xdeadbeef);
        vm.deal(other, total);
        vm.prank(other);
        vm.expectRevert(MASP.PayerNotSender.selector);
        masp.submitIntentNative{ value: total }(d, aux[0]);
    }

    function testRevertsOnAssetNotWrappedNative() public {
        // Register a second asset id pointing at a non-wrapped-native token;
        // intent referencing that id must revert AssetNotWrappedNative.
        uint64 nonWethId = ASSET_ID + 1;
        vm.prank(OWNER);
        masp.addAsset(nonWethId, IERC20(address(token)), SCALE);

        PubInputs.DepositIntent memory d = _intent(100);
        d.publicAssetId = nonWethId;
        AuxValidation.Output[3] memory aux = _aux();
        uint256 total = _expectedTotal(100);

        vm.prank(natPayer);
        vm.expectRevert(MASP.AssetNotWrappedNative.selector);
        masp.submitIntentNative{ value: total }(d, aux[0]);
    }

    function testRevertsOnZeroPublicIn() public {
        PubInputs.DepositIntent memory d = _intent(0);
        AuxValidation.Output[3] memory aux = _aux();

        vm.prank(natPayer);
        vm.expectRevert(MASP.MustHaveDeposit.selector);
        masp.submitIntentNative{ value: 0 }(d, aux[0]);
    }
}
