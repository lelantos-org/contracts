// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { AssetRegistry } from "../src/AssetRegistry.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../src/interfaces/IWrappedNative.sol";
import { Groth16Verifier } from "../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC1271 } from "./mocks/MockERC1271.sol";

/// `submitIntent` happy path + revert coverage. Permit2 sig acceptance is
/// faked via an ERC-1271 stub at the payer address (any sig bytes valid),
/// so tests can focus on contract-level invariants.
contract MASPSubmitIntentTest is Test {
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

    address payer = address(0xface);
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

        // Permissive ERC-1271 stub at payer so any sig bytes pass Permit2.
        MockERC1271 stub = new MockERC1271();
        vm.etch(payer, address(stub).code);
    }

    function _intent(uint64 publicIn) internal view returns (PubInputs.DepositIntent memory d) {
        d.chainId = uint64(block.chainid);
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = recipient;
        d.outCm[0] = bytes32(uint256(0xdead));
        d.outCm[1] = bytes32(uint256(0xbeef));
    }

    function _aux() internal pure returns (AuxValidation.Output[2] memory aux) {
        // Baby-Jubjub prime-order generator in both point slots — passes the
        // low-order / identity rejection added to `AuxValidation`.
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

    function _fund(uint64 publicIn) internal returns (uint256 inAmt, uint256 fee) {
        inAmt = uint256(publicIn) * SCALE;
        fee = (inAmt * FEE_BPS) / 10_000;
        token.mint(payer, inAmt + fee);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);
    }

    function _sig(uint256 maxTotal) internal pure returns (MASP.Permit2Sig memory) {
        return MASP.Permit2Sig({ nonce: 0, deadline: type(uint256).max, maxTotal: maxTotal, signature: hex"00" });
    }

    // --- happy path --------------------------------------------------------

    function test_happy_pullsFundsAndEscrows() public {
        uint64 publicIn = 100;
        (uint256 inAmt, uint256 fee) = _fund(publicIn);
        uint256 total = inAmt + fee;

        PubInputs.DepositIntent memory d = _intent(publicIn);
        AuxValidation.Output[2] memory aux = _aux();

        uint256 poolBefore = token.balanceOf(address(masp));
        uint256 payerBefore = token.balanceOf(payer);

        uint256 id = masp.submitIntent(d, _sig(total), aux);

        assertEq(id, 0, "first id");
        assertEq(token.balanceOf(address(masp)) - poolBefore, total, "pool gross");
        assertEq(payerBefore - token.balanceOf(payer), total, "payer debited");
        assertEq(masp.accruedFee(IERC20(address(token))), 0, "no accrual at submit; fee accrues at flush");
        assertEq(masp.nextIntentId(), 1, "nextIntentId bumped");

        // Spot-check escrow slot: a single digest binds the full preimage,
        // payer and submit block included.
        bytes32 expectedDigest = keccak256(
            abi.encode(
                address(masp),
                block.chainid,
                id,
                d.outCm[0],
                d.outCm[1],
                d.cvDep0,
                d.cvDep1,
                uint64(ASSET_ID),
                uint48(publicIn),
                uint16(FEE_BPS),
                payer,
                uint32(block.number)
            )
        );
        assertEq(masp.escrowed(id), expectedDigest, "digest binds full preimage");
    }

    function test_happy_idsMonotonic() public {
        uint64 publicIn = 50;
        _fund(publicIn);
        _fund(publicIn); // second deposit's funds
        PubInputs.DepositIntent memory d = _intent(publicIn);
        AuxValidation.Output[2] memory aux = _aux();
        MASP.Permit2Sig memory s1 =
            MASP.Permit2Sig({ nonce: 0, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00" });
        MASP.Permit2Sig memory s2 =
            MASP.Permit2Sig({ nonce: 1, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00" });

        uint256 a = masp.submitIntent(d, s1, aux);
        uint256 b = masp.submitIntent(d, s2, aux);
        assertEq(a, 0);
        assertEq(b, 1);
    }

    function test_happy_sweep_nothingAccruedAtSubmit() public {
        uint64 publicIn = 100;
        _fund(publicIn);
        masp.submitIntent(_intent(publicIn), _sig(type(uint256).max), _aux());

        // Fees accrue only at flush, so a bare submit leaves nothing to sweep
        // — escrowed principal + fee stay out of `accruedFee` entirely.
        uint256 swept = masp.sweep(IERC20(address(token)));
        assertEq(swept, 0, "nothing accrued");
        assertEq(masp.accruedFee(IERC20(address(token))), 0);
    }

    // --- reverts -----------------------------------------------------------

    function test_revert_BadChainId() public {
        _fund(100);
        PubInputs.DepositIntent memory d = _intent(100);
        d.chainId = uint64(block.chainid + 1);
        vm.expectRevert(MASP.BadChainId.selector);
        masp.submitIntent(d, _sig(type(uint256).max), _aux());
    }

    function test_revert_MustHaveDeposit() public {
        PubInputs.DepositIntent memory d = _intent(0);
        vm.expectRevert(MASP.MustHaveDeposit.selector);
        masp.submitIntent(d, _sig(type(uint256).max), _aux());
    }

    function test_revert_PublicInTooLarge() public {
        // 2^48 exceeds uint48 max
        PubInputs.DepositIntent memory d = _intent(0);
        d.publicIn = uint64(uint256(type(uint48).max) + 1);
        vm.expectRevert(MASP.PublicInTooLarge.selector);
        masp.submitIntent(d, _sig(type(uint256).max), _aux());
    }

    function test_revert_ZeroPayer() public {
        PubInputs.DepositIntent memory d = _intent(100);
        d.payer = address(0);
        vm.expectRevert(MASP.ZeroPayer.selector);
        masp.submitIntent(d, _sig(type(uint256).max), _aux());
    }

    function test_revert_ZeroRecipient() public {
        PubInputs.DepositIntent memory d = _intent(100);
        d.recipient = address(0);
        vm.expectRevert(MASP.ZeroRecipient.selector);
        masp.submitIntent(d, _sig(type(uint256).max), _aux());
    }

    function test_revert_ZeroCm() public {
        PubInputs.DepositIntent memory d = _intent(100);
        d.outCm[0] = bytes32(0);
        vm.expectRevert(MASP.ZeroCm.selector);
        masp.submitIntent(d, _sig(type(uint256).max), _aux());

        d.outCm[0] = bytes32(uint256(1));
        d.outCm[1] = bytes32(0);
        vm.expectRevert(MASP.ZeroCm.selector);
        masp.submitIntent(d, _sig(type(uint256).max), _aux());
    }

    function test_revert_UnknownAsset() public {
        PubInputs.DepositIntent memory d = _intent(100);
        d.publicAssetId = 999;
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, 999));
        masp.submitIntent(d, _sig(type(uint256).max), _aux());
    }

    // --- admin / cancelDelay -----------------------------------------------

    function test_setCancelDelay_owner_rejectsBelowMin() public {
        vm.prank(OWNER);
        vm.expectRevert(MASP.BadCancelDelay.selector);
        masp.setCancelDelay(3_599);
    }

    function test_setCancelDelay_owner_rejectsAboveMax() public {
        vm.prank(OWNER);
        vm.expectRevert(MASP.BadCancelDelay.selector);
        masp.setCancelDelay(50_401);
    }

    function test_setCancelDelay_owner_setsValid() public {
        vm.prank(OWNER);
        masp.setCancelDelay(10_000);
        assertEq(masp.cancelDelay(), 10_000);
    }

    function test_setCancelDelay_nonOwner_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        masp.setCancelDelay(7_200);
    }
}
