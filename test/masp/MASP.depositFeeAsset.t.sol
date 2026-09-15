// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { IEIP712 } from "permit2/src/interfaces/IEIP712.sol";
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

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockWETH9 } from "../mocks/MockWETH9.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { YieldBase } from "../yield/YieldBase.t.sol";

/// A deposit whose relayer fee note is paid in a different registered asset
/// (`DepositRequest.feeAssetId`). The treasury's deposit fee stays in the
/// deposit asset; only the relayer's note, its pull and its refund move to the
/// fee asset.
///
/// Built on `YieldBase` for its two ids over one ERC-20 (`PLAIN_ID`,
/// `YIELD_ID`) and its accepting verifiers. A second ERC-20 is registered as
/// the fee asset under a `scale` different from the principal's, so a fee
/// priced against the wrong registry entry is off by orders of magnitude.
contract MASPDepositFeeAssetTest is YieldBase {
    uint64 internal constant FEE_ID = 2;
    uint64 internal constant DISABLED_ID = 3;
    uint64 internal constant WETH_ID = 4;
    uint64 internal constant FUZZ_FEE_ID = 5;
    uint64 internal constant UNKNOWN_ID = 77;
    /// Deliberately unlike `SCALE` (1e10).
    uint256 internal constant FEE_SCALE = 1e4;

    uint64 internal constant PUBLIC_IN = 1_000;
    uint64 internal constant FEE_IN = 7;

    uint256 internal constant SIGNER_PK = 0x5161E7;
    string internal constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token,uint256 amount)";

    MockERC20 internal feeToken;

    function setUp() public override {
        super.setUp();
        feeToken = new MockERC20("Fee", "FEE", 6);
        MockERC20 disabledToken = new MockERC20("Off", "OFF", 18);
        vm.startPrank(OWNER);
        masp.addAsset(FEE_ID, IERC20(address(feeToken)), FEE_SCALE, FEE_BPS, FEE_BPS);
        masp.addAsset(DISABLED_ID, IERC20(address(disabledToken)), SCALE, FEE_BPS, FEE_BPS);
        masp.setAssetDisabled(DISABLED_ID, true);
        vm.stopPrank();
    }

    // --- amounts ------------------------------------------------------------

    /// Principal plus treasury fee in `token`, for a `PLAIN_ID` deposit.
    function _principalPull(uint64 publicIn) internal pure returns (uint256) {
        uint256 inAmt = uint256(publicIn) * SCALE;
        return inAmt + (inAmt * FEE_BPS) / 10_000;
    }

    /// A `YIELD_ID` deposit's pull into an empty pool, where one unit is
    /// `scale` and the treasury fee is charged in (ceiled) units.
    function _yieldPrincipalPull(uint64 publicIn) internal pure returns (uint256) {
        return (uint256(publicIn) + Fees.unitFee(publicIn, FEE_BPS)) * SCALE;
    }

    /// The relayer note's value in `feeToken`, under the fee asset's `scale`.
    function _feeTokenPull() internal pure returns (uint256) {
        return uint256(FEE_IN) * FEE_SCALE;
    }

    // --- requests and funding -----------------------------------------------

    function _signer() internal pure returns (address) {
        return vm.addr(SIGNER_PK);
    }

    /// A `PUBLIC_IN` deposit from `who` paying `FEE_IN` units of `feeAssetId`
    /// to the relayer.
    function _requestPaying(address who, uint64 publicAssetId, uint64 feeAssetId, uint256 seed)
        internal
        view
        returns (PubInputs.DepositRequest memory d)
    {
        d = _request(publicAssetId, PUBLIC_IN, FEE_IN, seed);
        d.payer = who;
        d.feeAssetId = feeAssetId;
        d.cvDep = [uint256(0xc0), uint256(0xc1)];
        d.feeCvDep = [uint256(0xf0), uint256(0xf1)];
    }

    /// Funds `who` in both tokens and approves Permit2 for each.
    function _fund(address who) internal {
        token.mint(who, type(uint128).max);
        feeToken.mint(who, type(uint128).max);
        vm.startPrank(who);
        token.approve(permit2, type(uint256).max);
        feeToken.approve(permit2, type(uint256).max);
        vm.stopPrank();
    }

    /// Grants the pool a Permit2 allowance over each token.
    function _allowBoth(address who, uint160 principalCap, uint160 feeCap) internal {
        uint48 exp = uint48(block.timestamp + 365 days);
        vm.startPrank(who);
        IAllowanceTransfer(permit2).approve(address(token), address(masp), principalCap, exp);
        IAllowanceTransfer(permit2).approve(address(feeToken), address(masp), feeCap, exp);
        vm.stopPrank();
    }

    function _depositAuthorized(PubInputs.DepositRequest memory d) internal returns (uint256 id) {
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        vm.prank(d.payer);
        id = masp.depositAuthorized(d, aux[0], aux[1]);
    }

    function _expectDepositRevert(PubInputs.DepositRequest memory d, bytes memory err) internal {
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        vm.prank(d.payer);
        vm.expectRevert(err);
        masp.depositAuthorized(d, aux[0], aux[1]);
    }

    /// An allowance-path deposit from `payer` into `publicAssetId`, with the
    /// relayer paid in `feeAssetId`.
    function _escrow(uint64 publicAssetId, uint64 feeAssetId, uint256 seed)
        internal
        returns (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt)
    {
        _fund(payer);
        _allowBoth(payer, type(uint160).max, type(uint160).max);
        d = _requestPaying(payer, publicAssetId, feeAssetId, seed);
        submittedAt = uint32(vm.getBlockNumber());
        id = _depositAuthorized(d);
    }

    // --- Permit2 signatures -------------------------------------------------

    function _sig(uint256 maxTotal, uint256 maxFee) internal pure returns (MASP.Permit2Sig memory) {
        return MASP.Permit2Sig({
            nonce: 0, deadline: type(uint256).max, maxTotal: maxTotal, maxFee: maxFee, signature: hex""
        });
    }

    function _tokenPermission(address tok, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(keccak256(bytes(TOKEN_PERMISSIONS_TYPE)), tok, amount));
    }

    /// Permit2's EIP-712 digest for a witness permit with the pool as spender,
    /// given the primary type's stub and the hashed `permitted` field.
    function _witnessDigest(string memory stub, bytes32 permitted, MASP.Permit2Sig memory sig, bytes32 piHash)
        internal
        view
        returns (bytes32)
    {
        bytes32 typeHash = keccak256(abi.encodePacked(stub, masp.DEPOSIT_WITNESS_TYPE_STRING()));
        bytes32 witness = keccak256(abi.encode(masp.DEPOSIT_WITNESS_TYPEHASH(), piHash));
        bytes32 structHash = keccak256(abi.encode(typeHash, permitted, address(masp), sig.nonce, sig.deadline, witness));
        return keccak256(abi.encodePacked("\x19\x01", IEIP712(permit2).DOMAIN_SEPARATOR(), structHash));
    }

    /// Signs the `PermitBatchWitnessTransferFrom` over
    /// `[token: maxTotal, feeToken: maxFee]` that the two-token path verifies.
    function _signBatch(MASP.Permit2Sig memory sig, bytes32 piHash) internal view returns (bytes memory) {
        bytes32 permitted = keccak256(
            abi.encodePacked(
                _tokenPermission(address(token), sig.maxTotal), _tokenPermission(address(feeToken), sig.maxFee)
            )
        );
        bytes32 digest = _witnessDigest(
            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,",
            permitted,
            sig,
            piHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Signs the single-token `PermitWitnessTransferFrom` over
    /// `token: maxTotal` that the single-token path verifies.
    function _signSingle(MASP.Permit2Sig memory sig, bytes32 piHash) internal view returns (bytes memory) {
        bytes32 digest = _witnessDigest(
            "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
            _tokenPermission(address(token), sig.maxTotal),
            sig,
            piHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    /// A funded signer's `PLAIN_ID` deposit paying the relayer in `FEE_ID`,
    /// with a batch signature over the given caps.
    function _signedCrossDeposit(uint256 maxTotal, uint256 maxFee)
        internal
        returns (PubInputs.DepositRequest memory d, MASP.Permit2Sig memory sig, AuxValidation.Output[6] memory aux)
    {
        _fund(_signer());
        d = _requestPaying(_signer(), PLAIN_ID, FEE_ID, 0x100);
        aux = SpendFixture.validAux();
        sig = _sig(maxTotal, maxFee);
        sig.signature = _signBatch(sig, keccak256(abi.encode(d, aux[0], aux[1])));
    }

    // --- flush and cancel ---------------------------------------------------

    /// The flush batch for one deposit, with the fee leaf declaring
    /// `feeLeafAsset`.
    function _tpi(PubInputs.DepositRequest memory d, uint64 feeLeafAsset)
        internal
        view
        returns (PubInputs.TreeUpdateBatch memory tpi)
    {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xfeed0000) + uint256(d.outCm));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        tpi.cms[0] = d.outCm;
        tpi.cvDeps[0] = d.cvDep;
        tpi.leafAsset[0] = d.publicAssetId;
        tpi.leafPublicIn[0] = d.publicIn;
        tpi.isDeposit[0] = 1;
        tpi.cms[1] = d.feeCm;
        tpi.cvDeps[1] = d.feeCvDep;
        tpi.leafAsset[1] = feeLeafAsset;
        tpi.leafPublicIn[1] = d.feeIn;
        tpi.isDeposit[1] = 1;
    }

    function _flush(uint256 id, PubInputs.TreeUpdateBatch memory tpi, uint32 submittedAt) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: payer, submittedAt: submittedAt, fbps: FEE_BPS });
        masp.flushBatch(ids, meta, FixtureLoader.emptyProof(), tpi);
    }

    function _passCancelDelay(uint32 submittedAt) internal {
        vm.roll(uint256(submittedAt) + masp.cancelDelay());
    }

    /// Cancels with the preimage `d` escrowed. The only external call, so an
    /// expectation set just before applies to the cancel itself.
    function _cancel(PubInputs.DepositRequest memory d, uint256 id, uint32 submittedAt)
        internal
        returns (uint256 refunded, uint256 feeRefunded)
    {
        return masp.cancelDeposit(
            id,
            uint48(d.publicIn),
            d.outCm,
            d.cvDep,
            d.publicAssetId,
            FEE_BPS,
            d.payer,
            submittedAt,
            PubInputs.FeeNote({
                feeIn: uint48(d.feeIn), feeAssetId: d.feeAssetId, feeCm: d.feeCm, feeCvDep: d.feeCvDep
            })
        );
    }

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

    // --- flush --------------------------------------------------------------

    /// Flush binds the fee leaf to the submitted `feeAssetId` and accrues only
    /// the principal's treasury fee; the fee token stays as backing.
    function test_flush_crossAsset_settles() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, FEE_ID, 0x700);

        vm.expectEmit(address(masp));
        emit MASP.DepositFlushed(id, d.outCm);
        _flush(id, _tpi(d, FEE_ID), submittedAt);

        assertEq(masp.escrowed(id), bytes32(0), "escrow drained");
        uint256 inAmt = uint256(PUBLIC_IN) * SCALE;
        assertEq(masp.accruedFee(IERC20(address(token))), (inAmt * FEE_BPS) / 10_000, "treasury fee in token");
        assertEq(masp.accruedFee(IERC20(address(feeToken))), 0, "nothing accrued in the fee token");
        assertEq(feeToken.balanceOf(address(masp)), _feeTokenPull(), "fee token backs the relayer note");
    }

    /// A yield principal's flush settles its unit fee alone; the plain note in
    /// another token touches neither yield book.
    function test_flush_yieldPrincipal_plainFee() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(YIELD_ID, FEE_ID, 0x780);

        _flush(id, _tpi(d, FEE_ID), submittedAt);

        uint256 unitFee = Fees.unitFee(PUBLIC_IN, FEE_BPS);
        assertEq(masp.yieldState(YIELD_ID).totalNormalized, PUBLIC_IN, "principal units remain");
        assertEq(masp.yieldState(YIELD_ID).accruedFeeNormalized, unitFee, "unit fee moved to the treasury");
        assertEq(masp.accruedFee(IERC20(address(feeToken))), 0, "nothing accrued in the fee token");
        assertEq(feeToken.balanceOf(address(masp)), _feeTokenPull(), "fee token backs the relayer note");
    }

    /// A flusher naming any other asset for the fee leaf reconstructs a
    /// different digest: the deposit asset, asset 0, or another registered one.
    function test_revert_flush_feeLeafAssetTampered() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, FEE_ID, 0x700);
        uint64[3] memory wrong = [PLAIN_ID, uint64(0), DISABLED_ID];
        for (uint256 k = 0; k < wrong.length; ++k) {
            PubInputs.TreeUpdateBatch memory tpi = _tpi(d, wrong[k]);
            vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
            _flush(id, tpi, submittedAt);
        }
    }

    // --- cancel -------------------------------------------------------------

    /// A two-token escrow refunds in both tokens, the relayer note separately,
    /// and leaves the pool holding neither.
    function test_cancel_crossAsset_refundsBothTokens() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, FEE_ID, 0x800);
        _passCancelDelay(submittedAt);
        uint256 tokenBefore = token.balanceOf(payer);
        uint256 feeBefore = feeToken.balanceOf(payer);

        vm.expectEmit(address(masp));
        emit MASP.DepositCanceled(id, payer, _principalPull(PUBLIC_IN), FEE_ID, _feeTokenPull());
        (uint256 refunded, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(refunded, _principalPull(PUBLIC_IN), "principal refund excludes the note");
        assertEq(feeRefunded, _feeTokenPull(), "note refunded in its own token");
        assertEq(token.balanceOf(payer) - tokenBefore, refunded, "token delivered");
        assertEq(feeToken.balanceOf(payer) - feeBefore, feeRefunded, "fee token delivered");
        assertEq(token.balanceOf(address(masp)), 0, "no token left behind");
        assertEq(feeToken.balanceOf(address(masp)), 0, "no fee token left behind");
        assertEq(masp.escrowed(id), bytes32(0), "escrow cleared");
    }

    /// Disabling the fee asset after submit does not strand the escrow.
    function test_cancel_crossAsset_afterFeeAssetDisabled() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, FEE_ID, 0x880);
        _passCancelDelay(submittedAt);
        vm.prank(OWNER);
        masp.setAssetDisabled(FEE_ID, true);

        (, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(feeRefunded, _feeTokenPull(), "note refunded");
        assertEq(feeToken.balanceOf(address(masp)), 0, "no fee token left behind");
    }

    /// The single-token cancel pays one refund; `feeRefunded` is zero.
    function test_cancel_sameAsset_singleRefund() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, PLAIN_ID, 0x900);
        _passCancelDelay(submittedAt);
        uint256 total = _principalPull(PUBLIC_IN) + uint256(FEE_IN) * SCALE;
        uint256 feeBefore = feeToken.balanceOf(payer);

        vm.expectEmit(address(masp));
        emit MASP.DepositCanceled(id, payer, total, PLAIN_ID, 0);
        (uint256 refunded, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(refunded, total, "whole pull in one token");
        assertEq(feeRefunded, 0, "no second refund");
        assertEq(feeToken.balanceOf(payer), feeBefore, "fee token untouched");
    }

    /// Cancel resupplies `feeAssetId`; any other value mismatches the digest.
    function test_revert_cancel_feeAssetTampered() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(PLAIN_ID, FEE_ID, 0xa00);
        _passCancelDelay(submittedAt);
        d.feeAssetId = PLAIN_ID;
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        _cancel(d, id, submittedAt);
    }

    /// A yield principal refunds through `YieldOps.cancel` with no note units,
    /// capped at its principal pull; the plain note refunds its fixed value.
    function test_cancel_yieldPrincipal_plainFee() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _escrow(YIELD_ID, FEE_ID, 0xb00);
        _passCancelDelay(submittedAt);
        uint256 feeBefore = feeToken.balanceOf(payer);

        vm.expectEmit(address(masp));
        emit MASP.DepositCanceled(id, payer, _yieldPrincipalPull(PUBLIC_IN), FEE_ID, _feeTokenPull());
        (uint256 refunded, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(refunded, _yieldPrincipalPull(PUBLIC_IN), "principal refund at a flat index");
        assertEq(feeRefunded, _feeTokenPull(), "plain note refunded in the fee token");
        assertEq(feeToken.balanceOf(payer) - feeBefore, _feeTokenPull(), "fee token delivered");
        assertEq(masp.yieldState(YIELD_ID).totalNormalized, 0, "every unit burned");
    }

    // --- pricing across scales ----------------------------------------------

    /// For any amounts and fee-asset scale, the two-token path pulls exactly
    /// `inAmt + fee` of the deposit token and `feeIn * feeScale` of the fee
    /// token, and cancel returns exactly those amounts.
    function testFuzz_crossAsset_pullAndRefundExact(uint64 publicIn, uint64 feeIn, uint256 feeScale) public {
        publicIn = uint64(bound(publicIn, 1, type(uint48).max));
        feeIn = uint64(bound(feeIn, 1, type(uint48).max));
        feeScale = bound(feeScale, 1, 1e18);
        vm.prank(OWNER);
        masp.addAsset(FUZZ_FEE_ID, IERC20(address(feeToken)), feeScale, FEE_BPS, FEE_BPS);

        _fund(payer);
        _allowBoth(payer, type(uint160).max, type(uint160).max);
        PubInputs.DepositRequest memory d = _requestPaying(payer, PLAIN_ID, FUZZ_FEE_ID, 0xd00);
        d.publicIn = publicIn;
        d.feeIn = feeIn;
        uint32 submittedAt = uint32(vm.getBlockNumber());
        uint256 tokenBefore = token.balanceOf(payer);
        uint256 feeBefore = feeToken.balanceOf(payer);

        uint256 id = _depositAuthorized(d);

        uint256 feePull = uint256(feeIn) * feeScale;
        assertEq(tokenBefore - token.balanceOf(payer), _principalPull(publicIn), "deposit token pull");
        assertEq(feeBefore - feeToken.balanceOf(payer), feePull, "fee token pull");

        _passCancelDelay(submittedAt);
        (uint256 refunded, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(refunded, _principalPull(publicIn), "deposit token refund");
        assertEq(feeRefunded, feePull, "fee token refund");
        assertEq(token.balanceOf(payer), tokenBefore, "payer whole in token");
        assertEq(feeToken.balanceOf(payer), feeBefore, "payer whole in fee token");
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
