// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { SignatureVerification } from "permit2/src/libraries/SignatureVerification.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { MaspEscrowSatellite } from "../../src/MaspEscrowSatellite.sol";
import { NativeAdapter } from "../../src/native/NativeAdapter.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { Fees } from "../../src/libs/Fees.sol";

import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { DepositFeeAssetTestBase } from "./DepositFeeAssetTestBase.sol";

/// Cross-asset relayer fee at submit: the Permit2 signature and allowance
/// paths, request validation, and the satellite guard. Fixture and helpers in
/// `DepositFeeAssetTestBase`; flush and cancel in
/// `MASP.depositFeeAsset.settlement.t.sol`.
contract MASPDepositFeeAssetTest is DepositFeeAssetTestBase {
    // --- signature path -----------------------------------------------------

    /// The pool pulls the principal and treasury fee in the deposit token and
    /// the relayer note in the fee token, each against its own signed cap, and
    /// the escrow digest carries the fee asset between `feeIn` and `feeCm`.
    function test_signature_crossAsset_pullsBothTokensAndBindsFeeAsset() public {
        (PubInputs.DepositRequest memory d, MASP.Permit2Sig memory sig, AuxValidation.Output[6] memory aux) =
            _signedCrossDeposit(_principalPull(PUBLIC_IN), _feeTokenPull());
        uint256 tokenBefore = token.balanceOf(_signer());
        uint256 feeBefore = feeToken.balanceOf(_signer());

        vm.expectEmit(address(masp));
        emit MASP.AssetMoved(PLAIN_ID, IERC20(address(token)), uint256(PUBLIC_IN) * SCALE, 0, PUBLIC_IN, 0);
        uint256 id = masp.deposit(d, sig, aux[0], aux[1]);

        assertEq(tokenBefore - token.balanceOf(_signer()), _principalPull(PUBLIC_IN), "principal + fee in token");
        assertEq(feeBefore - feeToken.balanceOf(_signer()), _feeTokenPull(), "relayer note in the fee token");
        assertEq(token.balanceOf(address(masp)), _principalPull(PUBLIC_IN), "token held by the pool");
        assertEq(feeToken.balanceOf(address(masp)), _feeTokenPull(), "fee token held by the pool");
        assertEq(
            masp.escrowed(id),
            keccak256(
                abi.encode(
                    address(masp),
                    block.chainid,
                    id,
                    d.outCm,
                    d.cvDep,
                    PLAIN_ID,
                    uint48(PUBLIC_IN),
                    FEE_BPS,
                    _signer(),
                    uint32(vm.getBlockNumber()),
                    uint48(FEE_IN),
                    FEE_ID,
                    d.feeCm,
                    d.feeCvDep
                )
            ),
            "digest binds feeAssetId"
        );
    }

    /// `DepositEscrowed` carries `feeAssetId` immediately before `feeIn`.
    function test_signature_crossAsset_eventCarriesFeeAsset() public {
        (PubInputs.DepositRequest memory d, MASP.Permit2Sig memory sig, AuxValidation.Output[6] memory aux) =
            _signedCrossDeposit(_principalPull(PUBLIC_IN), _feeTokenPull());

        vm.recordLogs();
        masp.deposit(d, sig, aux[0], aux[1]);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "DepositEscrowed(uint256,address,address,uint64,uint64,uint16,bytes32,uint256,uint256,uint256,"
            "uint256,uint256,uint256,uint256,bytes,uint64,uint64,bytes32,uint256,uint256,uint256,uint256,uint256,"
            "uint256,uint256,bytes)"
        );
        uint256 found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            ++found;
            // Head words 0..10 are the static fields through `ephPubY`, word 11
            // the first `bytes` offset, word 12 `feeAssetId`, word 13 `feeIn`.
            assertEq(_word(logs[i].data, 12), FEE_ID, "feeAssetId");
            assertEq(_word(logs[i].data, 13), FEE_IN, "feeIn");
        }
        assertEq(found, 1, "one DepositEscrowed");
    }

    function _word(bytes memory data, uint256 i) internal pure returns (uint256 w) {
        assembly {
            w := mload(add(data, mul(add(i, 1), 0x20)))
        }
    }

    /// A single-token permit, even one whose cap covers both amounts, does not
    /// authorize the two-token pull: the pool asks Permit2 to verify a batch.
    function test_revert_signature_crossAsset_singleTokenPermit() public {
        (PubInputs.DepositRequest memory d, MASP.Permit2Sig memory sig, AuxValidation.Output[6] memory aux) =
            _signedCrossDeposit(type(uint256).max, _feeTokenPull());
        sig.signature = _signSingle(sig, keccak256(abi.encode(d, aux[0], aux[1])));

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        masp.deposit(d, sig, aux[0], aux[1]);
    }

    /// `feeAssetId` is inside the signed witness, so it cannot be changed after
    /// signing, here to the single-token path with a cap that covers its larger
    /// pull, so only the witness check can reject.
    function test_revert_signature_feeAssetChangedAfterSigning() public {
        (PubInputs.DepositRequest memory d, MASP.Permit2Sig memory sig, AuxValidation.Output[6] memory aux) =
            _signedCrossDeposit(_principalPull(PUBLIC_IN), _feeTokenPull());
        d.feeAssetId = PLAIN_ID;
        sig.maxTotal = type(uint256).max;
        sig.maxFee = 0;

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        masp.deposit(d, sig, aux[0], aux[1]);
    }

    /// The fee token's cap is `maxFee`, checked by Permit2 on its own entry.
    function test_revert_signature_maxFeeTooLow() public {
        (PubInputs.DepositRequest memory d, MASP.Permit2Sig memory sig, AuxValidation.Output[6] memory aux) =
            _signedCrossDeposit(_principalPull(PUBLIC_IN), _feeTokenPull() - 1);

        vm.expectRevert(abi.encodeWithSelector(ISignatureTransfer.InvalidAmount.selector, _feeTokenPull() - 1));
        masp.deposit(d, sig, aux[0], aux[1]);
    }

    /// On the two-token path `maxTotal` caps the deposit token alone: the
    /// relayer note no longer counts against it.
    function test_revert_signature_maxTotalExcludesRelayerNote() public {
        (PubInputs.DepositRequest memory d, MASP.Permit2Sig memory sig, AuxValidation.Output[6] memory aux) =
            _signedCrossDeposit(_principalPull(PUBLIC_IN) - 1, _feeTokenPull());

        vm.expectRevert(
            abi.encodeWithSelector(ISignatureTransfer.InvalidAmount.selector, _principalPull(PUBLIC_IN) - 1)
        );
        masp.deposit(d, sig, aux[0], aux[1]);
    }

    /// `maxFee` has no token to cap on the single-token path and must be zero,
    /// whether the note is in the deposit asset or carries no value.
    function test_revert_BadMaxFee_singleTokenPath() public {
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        PubInputs.DepositRequest memory sameAsset = _requestPaying(payer, PLAIN_ID, PLAIN_ID, 0x100);
        PubInputs.DepositRequest memory zeroFee = _requestPaying(payer, PLAIN_ID, 0, 0x100);
        zeroFee.feeIn = 0;

        vm.expectRevert(MASP.BadMaxFee.selector);
        masp.deposit(sameAsset, _sig(type(uint256).max, 1), aux[0], aux[1]);
        vm.expectRevert(MASP.BadMaxFee.selector);
        masp.deposit(zeroFee, _sig(type(uint256).max, 1), aux[0], aux[1]);
    }

    // --- allowance path -----------------------------------------------------

    /// Each token draws exactly its amount from its own Permit2 allowance.
    function test_allowance_crossAsset_pullsBothTokens() public {
        _fund(payer);
        _allowBoth(payer, uint160(_principalPull(PUBLIC_IN)), uint160(_feeTokenPull()));
        PubInputs.DepositRequest memory d = _requestPaying(payer, PLAIN_ID, FEE_ID, 0x200);
        uint256 tokenBefore = token.balanceOf(payer);
        uint256 feeBefore = feeToken.balanceOf(payer);

        _depositAuthorized(d);

        assertEq(tokenBefore - token.balanceOf(payer), _principalPull(PUBLIC_IN), "principal + fee in token");
        assertEq(feeBefore - feeToken.balanceOf(payer), _feeTokenPull(), "relayer note in the fee token");
        (uint160 left,,) = IAllowanceTransfer(permit2).allowance(payer, address(token), address(masp));
        assertEq(left, 0, "principal allowance spent exactly");
        (left,,) = IAllowanceTransfer(permit2).allowance(payer, address(feeToken), address(masp));
        assertEq(left, 0, "fee allowance spent exactly");
    }

    function test_revert_allowance_crossAsset_feeAllowanceTooLow() public {
        _fund(payer);
        _allowBoth(payer, type(uint160).max, uint160(_feeTokenPull() - 1));
        PubInputs.DepositRequest memory d = _requestPaying(payer, PLAIN_ID, FEE_ID, 0x200);
        _expectDepositRevert(
            d, abi.encodeWithSelector(IAllowanceTransfer.InsufficientAllowance.selector, _feeTokenPull() - 1)
        );
    }

    /// A note in the deposit's own asset keeps the single pull of
    /// `inAmt + fee + relayer` under the principal's scale; the fee token is
    /// untouched.
    function test_allowance_sameAsset_singlePull() public {
        _fund(payer);
        _allowBoth(payer, type(uint160).max, type(uint160).max);
        PubInputs.DepositRequest memory d = _requestPaying(payer, PLAIN_ID, PLAIN_ID, 0x300);
        uint256 tokenBefore = token.balanceOf(payer);
        uint256 feeBefore = feeToken.balanceOf(payer);

        _depositAuthorized(d);

        assertEq(tokenBefore - token.balanceOf(payer), _principalPull(PUBLIC_IN) + uint256(FEE_IN) * SCALE, "one pull");
        assertEq(feeToken.balanceOf(payer), feeBefore, "fee token untouched");
    }

    /// The path is chosen by asset id, not token: a yield principal paying its
    /// relayer in the plain id over the same ERC-20 takes the two-entry pull,
    /// and the note stays out of the yield books.
    function test_allowance_yieldPrincipal_plainFeeOverSameToken() public {
        token.mint(payer, type(uint128).max);
        _allow(type(uint160).max);
        PubInputs.DepositRequest memory d = _requestPaying(payer, YIELD_ID, PLAIN_ID, 0x400);
        uint256 before = token.balanceOf(payer);

        _depositAuthorized(d);

        assertEq(
            masp.yieldState(YIELD_ID).totalNormalized,
            uint256(PUBLIC_IN) + Fees.unitFee(PUBLIC_IN, FEE_BPS),
            "no note units booked into the yield asset"
        );
        assertEq(
            before - token.balanceOf(payer),
            _yieldPrincipalPull(PUBLIC_IN) + uint256(FEE_IN) * SCALE,
            "principal entry + plain note entry"
        );
    }

    // --- validation ---------------------------------------------------------

    function test_revert_FeeAssetMustBeZero() public {
        PubInputs.DepositRequest memory d = _requestPaying(payer, PLAIN_ID, FEE_ID, 0x500);
        d.feeIn = 0;
        _expectDepositRevert(d, abi.encodeWithSelector(MASP.FeeAssetMustBeZero.selector));
    }

    /// A valued note in asset 0 is unprovable (the circuit forces a valued
    /// deposit leaf's asset non-zero), so it is refused at submit.
    function test_revert_FeeAssetUnsupported_zero() public {
        PubInputs.DepositRequest memory d = _requestPaying(payer, PLAIN_ID, 0, 0x500);
        _expectDepositRevert(d, abi.encodeWithSelector(MASP.FeeAssetUnsupported.selector, uint64(0)));
    }

    /// A yield asset may pay the relayer only as the deposit's own asset: a
    /// note in it would need units booked into that asset's supply.
    function test_revert_FeeAssetUnsupported_yield() public {
        PubInputs.DepositRequest memory d = _requestPaying(payer, PLAIN_ID, YIELD_ID, 0x500);
        _expectDepositRevert(d, abi.encodeWithSelector(MASP.FeeAssetUnsupported.selector, YIELD_ID));
    }

    function test_revert_UnknownAsset_feeAsset() public {
        PubInputs.DepositRequest memory d = _requestPaying(payer, PLAIN_ID, UNKNOWN_ID, 0x500);
        _expectDepositRevert(d, abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, UNKNOWN_ID));
    }

    function test_revert_AssetDisabled_feeAsset() public {
        PubInputs.DepositRequest memory d = _requestPaying(payer, PLAIN_ID, DISABLED_ID, 0x500);
        _expectDepositRevert(d, abi.encodeWithSelector(AssetRegistry.AssetDisabled.selector, DISABLED_ID));
    }

    /// A yield deposit paying the relayer in its own asset is the single-token
    /// path: the note's units join the yield supply as before.
    function test_yieldDeposit_sameAssetNote_accepted() public {
        token.mint(payer, type(uint128).max);
        _allow(type(uint160).max);
        PubInputs.DepositRequest memory d = _requestPaying(payer, YIELD_ID, YIELD_ID, 0x600);

        _depositAuthorized(d);

        assertEq(
            masp.yieldState(YIELD_ID).totalNormalized,
            uint256(PUBLIC_IN) + Fees.unitFee(PUBLIC_IN, FEE_BPS) + FEE_IN,
            "note units booked with the principal"
        );
    }

    // --- satellites ---------------------------------------------------------

    /// A satellite measures one token, so it refuses a relayer note charged in
    /// another asset before calling the pool.
    function test_revert_satellite_FeeAssetMismatch() public {
        MockWETH9 weth = new MockWETH9();
        vm.prank(OWNER);
        masp.addAsset(WETH_ID, IERC20(address(weth)), SCALE, FEE_BPS, FEE_BPS);
        NativeAdapter adapter =
            new NativeAdapter(IMASPPool(address(masp)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));

        PubInputs.DepositRequest memory d = _requestPaying(address(adapter), WETH_ID, FEE_ID, 0xc00);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(MaspEscrowSatellite.FeeAssetMismatch.selector);
        adapter.depositNative{ value: 1 ether }(d, aux[0], aux[1]);
    }
}
