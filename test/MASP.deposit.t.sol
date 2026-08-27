// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { AssetRegistry } from "../src/AssetRegistry.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC1271 } from "./mocks/MockERC1271.sol";
import { BatchedGroth16Verifier } from "../src/verifiers/BatchedGroth16Verifier.sol";
import { IBatchVerifier } from "../src/interfaces/IBatchVerifier.sol";
import { SpendFixture } from "./utils/SpendFixture.sol";
import { uniformBps } from "./utils/FeeArrays.sol";

/// `deposit` happy path + revert coverage. Permit2 sig acceptance is
/// faked via an ERC-1271 stub at the payer address (any sig bytes valid),
/// so tests can focus on contract-level invariants.
contract MASPDepositTest is Test {
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);
    TreeUpdateBatchGroth16Verifier tubVerifier;
    BatchedGroth16Verifier batchVerifier;
    address permit2;
    MockERC20 token;
    MASP masp;

    address payer = address(0xface);
    address recipient = address(0xb0b);

    function setUp() public {
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        batchVerifier = new BatchedGroth16Verifier();
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("M", "M", 18);

        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = ASSET_ID;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;

        masp = new MASP(
            IVerifier(address(tubVerifier)),
            IBatchVerifier(address(batchVerifier)),
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            uniformBps(ids.length, FEE_BPS),
            uniformBps(ids.length, FEE_BPS),
            TREASURY,
            OWNER
        );

        // Permissive ERC-1271 stub at payer so any sig bytes pass Permit2.
        MockERC1271 stub = new MockERC1271();
        vm.etch(payer, address(stub).code);
    }

    function _request(uint64 publicIn) internal view returns (PubInputs.DepositRequest memory d) {
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = recipient;
        d.outCm = bytes32(uint256(0xdead));
        d.feeCm = bytes32(uint256(0xfee));
    }

    function _aux() internal pure returns (AuxValidation.Output[4] memory aux) {
        // Baby-Jubjub prime-order generator in both point slots — passes the
        // low-order / identity rejection added to `AuxValidation`.
        return SpendFixture.validAux();
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

        PubInputs.DepositRequest memory d = _request(publicIn);
        AuxValidation.Output[4] memory aux = _aux();

        uint256 poolBefore = token.balanceOf(address(masp));
        uint256 payerBefore = token.balanceOf(payer);

        uint256 id = masp.deposit(d, _sig(total), aux[0], aux[1]);

        assertEq(id, 0, "first id");
        assertEq(token.balanceOf(address(masp)) - poolBefore, total, "pool gross");
        assertEq(payerBefore - token.balanceOf(payer), total, "payer debited");
        assertEq(masp.accruedFee(IERC20(address(token))), 0, "no accrual at submit; fee accrues at flush");
        assertEq(masp.nextDepositId(), 1, "nextDepositId bumped");

        // Spot-check escrow slot: a single digest binds the full preimage,
        // payer and submit block included.
        bytes32 expectedDigest = keccak256(
            abi.encode(
                address(masp),
                block.chainid,
                id,
                d.outCm,
                d.cvDep,
                uint64(ASSET_ID),
                uint48(publicIn),
                uint16(FEE_BPS),
                payer,
                uint32(block.number),
                // The relayer's leaf is bound too, so a flusher cannot mint
                // itself a different fee note than the payer funded.
                uint48(d.feeIn),
                d.feeCm,
                d.feeCvDep
            )
        );
        assertEq(masp.escrowed(id), expectedDigest, "digest binds full preimage");
    }

    function test_happy_idsMonotonic() public {
        uint64 publicIn = 50;
        _fund(publicIn);
        _fund(publicIn); // second deposit's funds
        PubInputs.DepositRequest memory d = _request(publicIn);
        AuxValidation.Output[4] memory aux = _aux();
        MASP.Permit2Sig memory s1 =
            MASP.Permit2Sig({ nonce: 0, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00" });
        MASP.Permit2Sig memory s2 =
            MASP.Permit2Sig({ nonce: 1, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00" });

        uint256 a = masp.deposit(d, s1, aux[0], aux[1]);
        uint256 b = masp.deposit(d, s2, aux[0], aux[1]);
        assertEq(a, 0);
        assertEq(b, 1);
    }

    function test_happy_sweep_nothingAccruedAtSubmit() public {
        uint64 publicIn = 100;
        _fund(publicIn);
        masp.deposit(_request(publicIn), _sig(type(uint256).max), _aux()[0], _aux()[1]);

        // Fees accrue only at flush, so a bare submit leaves nothing to sweep
        // — escrowed principal + fee stay out of `accruedFee` entirely.
        uint256 swept = masp.sweep(IERC20(address(token)));
        assertEq(swept, 0, "nothing accrued");
        assertEq(masp.accruedFee(IERC20(address(token))), 0);
    }

    // --- reverts -----------------------------------------------------------

    function test_revert_BadChainId() public {
        _fund(100);
        PubInputs.DepositRequest memory d = _request(100);
        d.chainId = block.chainid + 1;
        vm.expectRevert(MASP.BadChainId.selector);
        masp.deposit(d, _sig(type(uint256).max), _aux()[0], _aux()[1]);
    }

    function test_revert_MustHaveDeposit() public {
        PubInputs.DepositRequest memory d = _request(0);
        vm.expectRevert(MASP.MustHaveDeposit.selector);
        masp.deposit(d, _sig(type(uint256).max), _aux()[0], _aux()[1]);
    }

    function test_revert_PublicInTooLarge() public {
        // 2^48 exceeds uint48 max
        PubInputs.DepositRequest memory d = _request(0);
        d.publicIn = uint64(uint256(type(uint48).max) + 1);
        vm.expectRevert(MASP.PublicInTooLarge.selector);
        masp.deposit(d, _sig(type(uint256).max), _aux()[0], _aux()[1]);
    }

    function test_revert_ZeroPayer() public {
        PubInputs.DepositRequest memory d = _request(100);
        d.payer = address(0);
        vm.expectRevert(MASP.ZeroPayer.selector);
        masp.deposit(d, _sig(type(uint256).max), _aux()[0], _aux()[1]);
    }

    function test_revert_ZeroRecipient() public {
        PubInputs.DepositRequest memory d = _request(100);
        d.recipient = address(0);
        vm.expectRevert(MASP.ZeroRecipient.selector);
        masp.deposit(d, _sig(type(uint256).max), _aux()[0], _aux()[1]);
    }

    function test_revert_ZeroCm() public {
        PubInputs.DepositRequest memory d = _request(100);
        // A deposit has exactly one leaf, so a zero cm is the whole check.
        d.outCm = bytes32(0);
        d.feeCm = bytes32(uint256(0xfee));
        vm.expectRevert(MASP.ZeroCm.selector);
        masp.deposit(d, _sig(type(uint256).max), _aux()[0], _aux()[1]);
    }

    function test_revert_UnknownAsset() public {
        PubInputs.DepositRequest memory d = _request(100);
        d.publicAssetId = 999;
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, 999));
        masp.deposit(d, _sig(type(uint256).max), _aux()[0], _aux()[1]);
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

    // --- relayer fee note ---------------------------------------------------

    /// The relayer's leg is charged on top of principal and treasury fee, so
    /// the payer funds it and treasury revenue is untouched.
    function test_happy_relayerFeeChargedOnTopOfPrincipalAndFee() public {
        uint64 publicIn = 100;
        uint64 feeIn = 7;
        uint256 relayerAmt = uint256(feeIn) * SCALE;
        (uint256 inAmt, uint256 fee) = _fund(publicIn);
        token.mint(payer, relayerAmt);

        PubInputs.DepositRequest memory d = _request(publicIn);
        d.feeIn = feeIn;
        AuxValidation.Output[4] memory aux = _aux();

        uint256 payerBefore = token.balanceOf(payer);
        uint256 poolBefore = token.balanceOf(address(masp));
        masp.deposit(d, _sig(inAmt + fee + relayerAmt), aux[0], aux[1]);

        uint256 total = inAmt + fee + relayerAmt;
        assertEq(payerBefore - token.balanceOf(payer), total, "payer funds the relayer's note too");
        assertEq(token.balanceOf(address(masp)) - poolBefore, total, "pool holds the tokens backing both leaves");
        assertEq(masp.accruedFee(IERC20(address(token))), 0, "relayer amount is not treasury revenue");
    }

    /// `_drainDeposit` narrows `feeIn` to `uint48` for the digest, the same way
    /// it does `publicIn`, so the submit path range-checks it the same way.
    function test_revert_PublicInTooLarge_feeIn() public {
        PubInputs.DepositRequest memory d = _request(100);
        d.feeIn = uint64(uint256(type(uint48).max) + 1);
        vm.expectRevert(MASP.PublicInTooLarge.selector);
        masp.deposit(d, _sig(type(uint256).max), _aux()[0], _aux()[1]);
    }

    /// A deposit mints two leaves, so the fee leaf's commitment needs the same
    /// well-formedness check the principal's gets. `feeIn` stays zero here: a
    /// subsidised deployment still mints the leaf, so the guard must fire on
    /// shape alone, not on value.
    function test_revert_ZeroCm_feeCm() public {
        PubInputs.DepositRequest memory d = _request(100);
        d.feeCm = bytes32(0);
        vm.expectRevert(MASP.ZeroCm.selector);
        masp.deposit(d, _sig(type(uint256).max), _aux()[0], _aux()[1]);
    }

    /// Both aux payloads are validated. Without this the two arguments are
    /// interchangeable in every other test, so a swapped or dropped `feeAux`
    /// would pass unnoticed and publish an unvalidated payload to the event.
    ///
    /// Each case takes its payload from a fresh `_aux()`: a memory struct is a
    /// reference, so reusing one would carry the previous mutation forward.
    function test_revert_feeAuxValidatedIndependently() public {
        _fund(100);
        PubInputs.DepositRequest memory d = _request(100);

        AuxValidation.Output memory badFee = _aux()[1];
        badFee.ciphertext = hex"";
        vm.expectRevert(AuxValidation.CiphertextTooShort.selector);
        masp.deposit(d, _sig(type(uint256).max), _aux()[0], badFee);

        // Off-curve ephemeral key in the fee payload, principal payload intact.
        badFee = _aux()[1];
        badFee.ephPubX = 1;
        badFee.ephPubY = 1;
        vm.expectRevert(AuxValidation.OffCurvePoint.selector);
        masp.deposit(d, _sig(type(uint256).max), _aux()[0], badFee);
    }
}
