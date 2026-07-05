// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../src/interfaces/IWrappedNative.sol";
import { Groth16Verifier } from "../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// `submitIntentAuthorized` — Permit2 AllowanceTransfer-based deposit.
/// Tests use `IAllowanceTransfer.approve` from the payer to set up the
/// allowance window directly (production uses a pre-signed PermitSingle,
/// equivalent on-chain state).
contract MASPSubmitIntentAuthorizedTest is Test {
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);

    Groth16Verifier verifier;
    TreeUpdateBatchGroth16Verifier tubVerifier;
    address permit2;
    MockERC20 token;
    MASP masp;

    address payer = address(0xa11ce);
    address recipient = address(0xb0b);

    function setUp() public {
        verifier = new Groth16Verifier();
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("M", "M", 18);

        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = ASSET_ID;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;

        masp = new MASP(
            IVerifier(address(verifier)),
            IVerifier(address(tubVerifier)),
            ISignatureTransfer(address(permit2)),
            IWrappedNative(address(0)),
            ids,
            tokens,
            scales,
            FEE_BPS,
            TREASURY,
            OWNER
        );

        // Real EOA payer: needs ERC20 → Permit2 max approve once.
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);
    }

    function _intent(uint64 publicIn, address payerAddr, bytes32 salt)
        internal
        view
        returns (PubInputs.DepositIntent memory d)
    {
        d.chainId = uint64(block.chainid);
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = payerAddr;
        d.recipient = recipient;
        d.outCm[0] = keccak256(abi.encode(salt, "cm0"));
        d.outCm[1] = keccak256(abi.encode(salt, "cm1"));
    }

    function _aux() internal pure returns (AuxValidation.Output[2] memory aux) {
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
    }

    function _total(uint64 publicIn) internal pure returns (uint256) {
        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;
        return inAmt + fee;
    }

    function _setupAllowance(uint160 cap, uint48 expiration) internal {
        vm.prank(payer);
        IAllowanceTransfer(address(permit2)).approve(address(token), address(masp), cap, expiration);
    }

    function testHappyPathPullsViaAllowance() public {
        uint64 amt = 100;
        uint256 total = _total(amt);
        token.mint(payer, total * 5);
        _setupAllowance(uint160(total * 5), uint48(block.timestamp + 1 days));

        uint256 poolBefore = token.balanceOf(address(masp));

        PubInputs.DepositIntent memory d = _intent(amt, payer, bytes32(uint256(1)));
        AuxValidation.Output[2] memory aux = _aux();

        vm.prank(payer);
        uint256 id = masp.submitIntentAuthorized(d, aux);

        assertEq(id, 0);
        assertEq(token.balanceOf(address(masp)) - poolBefore, total, "MASP credited");
        (uint160 remaining,,) = IAllowanceTransfer(address(permit2)).allowance(payer, address(token), address(masp));
        assertEq(remaining, uint160(total * 5) - uint160(total), "allowance decremented");
    }

    function testRepeatDepositsConsumeSameAllowance() public {
        uint64 amt = 50;
        uint256 total = _total(amt);
        token.mint(payer, total * 4);
        _setupAllowance(uint160(total * 3), uint48(block.timestamp + 1 days));

        AuxValidation.Output[2] memory aux = _aux();
        for (uint256 i; i < 3; i++) {
            PubInputs.DepositIntent memory d = _intent(amt, payer, bytes32(i + 1));
            vm.prank(payer);
            masp.submitIntentAuthorized(d, aux);
        }
        // Fourth deposit must fail: allowance exhausted.
        PubInputs.DepositIntent memory d4 = _intent(amt, payer, bytes32(uint256(4)));
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.InsufficientAllowance.selector, uint160(0)));
        masp.submitIntentAuthorized(d4, aux);
    }

    function testRevertsOnExpiredAllowance() public {
        uint64 amt = 100;
        uint256 total = _total(amt);
        token.mint(payer, total);
        uint48 exp = uint48(block.timestamp + 1 hours);
        _setupAllowance(uint160(total), exp);

        vm.warp(uint256(exp) + 1);

        PubInputs.DepositIntent memory d = _intent(amt, payer, bytes32(uint256(1)));
        AuxValidation.Output[2] memory aux = _aux();

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, uint256(exp)));
        masp.submitIntentAuthorized(d, aux);
    }

    function testRevertsOnSenderNotPayer() public {
        uint64 amt = 100;
        uint256 total = _total(amt);
        token.mint(payer, total);
        _setupAllowance(uint160(total), uint48(block.timestamp + 1 days));

        PubInputs.DepositIntent memory d = _intent(amt, payer, bytes32(uint256(1)));
        AuxValidation.Output[2] memory aux = _aux();

        address other = address(0xdead);
        vm.prank(other);
        vm.expectRevert(MASP.PayerNotSender.selector);
        masp.submitIntentAuthorized(d, aux);
    }

    function testRevertsOnNoAllowance() public {
        uint64 amt = 100;
        token.mint(payer, _total(amt));
        // No allowance set up.

        PubInputs.DepositIntent memory d = _intent(amt, payer, bytes32(uint256(1)));
        AuxValidation.Output[2] memory aux = _aux();

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, uint256(0)));
        masp.submitIntentAuthorized(d, aux);
    }
}
