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
    uint64 internal constant UNKNOWN_ID = 77;
    /// Deliberately unlike `SCALE` (1e10).
    uint256 internal constant FEE_SCALE = 1e4;

    uint64 internal constant PUBLIC_IN = 1_000;
    uint64 internal constant FEE_IN = 7;

    uint256 internal constant SIGNER_PK = 0x5161E7;

    string internal constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token,uint256 amount)";

    MockERC20 internal feeToken;
    MockERC20 internal disabledToken;

    function setUp() public override {
        super.setUp();
        feeToken = new MockERC20("Fee", "FEE", 6);
        disabledToken = new MockERC20("Off", "OFF", 18);
        vm.startPrank(OWNER);
        masp.addAsset(FEE_ID, IERC20(address(feeToken)), FEE_SCALE, FEE_BPS, FEE_BPS);
        masp.addAsset(DISABLED_ID, IERC20(address(disabledToken)), SCALE, FEE_BPS, FEE_BPS);
        masp.setAssetDisabled(DISABLED_ID, true);
        vm.stopPrank();
    }

    // --- helpers ------------------------------------------------------------

    function _signer() internal pure returns (address) {
        return vm.addr(SIGNER_PK);
    }

    /// A plain-asset deposit paying `FEE_IN` units of `feeAssetId` to the
    /// relayer.
    function _crossRequest(address who, uint64 publicAssetId, uint64 feeAssetId, uint256 seed)
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

    /// Principal plus treasury fee in `token`, for `PLAIN_ID`.
    function _principalPull() internal pure returns (uint256) {
        uint256 inAmt = uint256(PUBLIC_IN) * SCALE;
        return inAmt + (inAmt * FEE_BPS) / 10_000;
    }

    /// The relayer note's value in `feeToken`, priced under the fee asset's
    /// own `scale`.
    function _feePull() internal pure returns (uint256) {
        return uint256(FEE_IN) * FEE_SCALE;
    }

    function _fundAndApprove(address who) internal {
        token.mint(who, type(uint128).max);
        feeToken.mint(who, type(uint128).max);
        vm.startPrank(who);
        token.approve(permit2, type(uint256).max);
        feeToken.approve(permit2, type(uint256).max);
        vm.stopPrank();
    }

    function _allowBoth(address who, uint160 principalCap, uint160 feeCap) internal {
        uint48 exp = uint48(block.timestamp + 365 days);
        vm.startPrank(who);
        IAllowanceTransfer(permit2).approve(address(token), address(masp), principalCap, exp);
        IAllowanceTransfer(permit2).approve(address(feeToken), address(masp), feeCap, exp);
        vm.stopPrank();
    }

    /// The EIP-712 digest Permit2 checks for the batch
    /// `permitWitnessTransferFrom`, built from the type string MASP passes it.
    /// Mirrors `PermitHash.hashWithWitness(PermitBatchTransferFrom, ...)` with
    /// the pool as spender.
    function _batchDigest(
        address principalToken,
        uint256 maxTotal,
        address feeTok,
        uint256 maxFee,
        uint256 nonce,
        uint256 deadline,
        bytes32 piHash
    ) internal view returns (bytes32) {
        bytes32 tpType = keccak256(bytes(TOKEN_PERMISSIONS_TYPE));
        bytes32[] memory perms = new bytes32[](2);
        perms[0] = keccak256(abi.encode(tpType, principalToken, maxTotal));
        perms[1] = keccak256(abi.encode(tpType, feeTok, maxFee));
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,",
                masp.DEPOSIT_WITNESS_TYPE_STRING()
            )
        );
        bytes32 witness = keccak256(abi.encode(masp.DEPOSIT_WITNESS_TYPEHASH(), piHash));
        bytes32 structHash = keccak256(
            abi.encode(typeHash, keccak256(abi.encodePacked(perms)), address(masp), nonce, deadline, witness)
        );
        return keccak256(abi.encodePacked("\x19\x01", IEIP712(permit2).DOMAIN_SEPARATOR(), structHash));
    }

    function _signBatch(MASP.Permit2Sig memory sig, bytes32 piHash) internal view returns (bytes memory) {
        bytes32 digest = _batchDigest(
            address(token), sig.maxTotal, address(feeToken), sig.maxFee, sig.nonce, sig.deadline, piHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sig(uint256 maxTotal, uint256 maxFee) internal pure returns (MASP.Permit2Sig memory) {
        return MASP.Permit2Sig({
            nonce: 0, deadline: type(uint256).max, maxTotal: maxTotal, maxFee: maxFee, signature: hex""
        });
    }

    /// A deposit by the allowance path, from `payer` (an EOA).
    function _depositAuthorized(PubInputs.DepositRequest memory d) internal returns (uint256 id) {
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        vm.prank(d.payer);
        id = masp.depositAuthorized(d, aux[0], aux[1]);
    }

    function _crossDeposit(uint64 publicAssetId, uint256 seed)
        internal
        returns (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt)
    {
        _fundAndApprove(payer);
        _allowBoth(payer, type(uint160).max, type(uint160).max);
        d = _crossRequest(payer, publicAssetId, FEE_ID, seed);
        submittedAt = uint32(vm.getBlockNumber());
        id = _depositAuthorized(d);
    }

    function _feeNote(PubInputs.DepositRequest memory d) internal pure returns (PubInputs.FeeNote memory) {
        return
            PubInputs.FeeNote({
                feeIn: uint48(d.feeIn), feeAssetId: d.feeAssetId, feeCm: d.feeCm, feeCvDep: d.feeCvDep
            });
    }

    function _cancel(PubInputs.DepositRequest memory d, uint256 id, uint32 submittedAt)
        internal
        returns (uint256 refunded, uint256 feeRefunded)
    {
        return masp.cancelDeposit(
            id, uint48(d.publicIn), d.outCm, d.cvDep, d.publicAssetId, FEE_BPS, d.payer, submittedAt, _feeNote(d)
        );
    }

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

    // --- signature path -----------------------------------------------------

    /// A real key signs a `PermitBatchWitnessTransferFrom` over
    /// `[token, feeToken]`; the pool pulls the principal and treasury fee in
    /// the deposit token and the relayer note in the fee token, each against
    /// its own signed cap.
    function test_signature_crossAsset_pullsBothTokens() public {
        _fundAndApprove(_signer());
        PubInputs.DepositRequest memory d = _crossRequest(_signer(), PLAIN_ID, FEE_ID, 0x100);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();

        MASP.Permit2Sig memory sig = _sig(_principalPull(), _feePull());
        sig.signature = _signBatch(sig, keccak256(abi.encode(d, aux[0], aux[1])));

        uint256 tokenBefore = token.balanceOf(_signer());
        uint256 feeBefore = feeToken.balanceOf(_signer());

        vm.expectEmit(address(masp));
        emit MASP.AssetMoved(PLAIN_ID, IERC20(address(token)), uint256(PUBLIC_IN) * SCALE, 0, PUBLIC_IN, 0);
        uint256 id = masp.deposit(d, sig, aux[0], aux[1]);

        assertEq(tokenBefore - token.balanceOf(_signer()), _principalPull(), "principal + treasury fee in token");
        assertEq(feeBefore - feeToken.balanceOf(_signer()), _feePull(), "relayer note in the fee token");
        assertEq(feeToken.balanceOf(address(masp)), _feePull(), "fee token held by the pool");

        // The digest carries the fee asset between `feeIn` and `feeCm`.
        bytes32 expected = keccak256(
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
        );
        assertEq(masp.escrowed(id), expected, "digest binds feeAssetId");
    }

    /// `DepositEscrowed` carries `feeAssetId` immediately before `feeIn`.
    function test_signature_crossAsset_eventCarriesFeeAsset() public {
        _fundAndApprove(_signer());
        PubInputs.DepositRequest memory d = _crossRequest(_signer(), PLAIN_ID, FEE_ID, 0x100);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        MASP.Permit2Sig memory sig = _sig(_principalPull(), _feePull());
        sig.signature = _signBatch(sig, keccak256(abi.encode(d, aux[0], aux[1])));

        vm.recordLogs();
        masp.deposit(d, sig, aux[0], aux[1]);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "DepositEscrowed(uint256,address,address,uint64,uint64,uint16,bytes32,uint256,uint256,uint256,"
            "uint256,uint256,uint256,uint256,bytes,uint64,uint64,bytes32,uint256,uint256,uint256,uint256,uint256,"
            "uint256,uint256,bytes)"
        );
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            found = true;
            // Head words 0..10 are the static fields through `ephPubY`, word 11
            // the first `bytes` offset, word 12 `feeAssetId`, word 13 `feeIn`.
            (uint256 w12, uint256 w13) = _words(logs[i].data, 12, 13);
            assertEq(w12, FEE_ID, "feeAssetId");
            assertEq(w13, FEE_IN, "feeIn");
        }
        assertTrue(found, "DepositEscrowed emitted");
    }

    function _words(bytes memory data, uint256 a, uint256 b) internal pure returns (uint256 x, uint256 y) {
        assembly {
            x := mload(add(data, add(0x20, mul(a, 0x20))))
            y := mload(add(data, add(0x20, mul(b, 0x20))))
        }
    }

    /// A single-token signature does not authorize a two-token pull: the pool
    /// asks Permit2 to verify a batch permit, whose digest differs.
    function test_revert_signature_crossAsset_singleTokenPermitRejected() public {
        _fundAndApprove(_signer());
        PubInputs.DepositRequest memory d = _crossRequest(_signer(), PLAIN_ID, FEE_ID, 0x100);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        MASP.Permit2Sig memory sig = _sig(_principalPull(), _feePull());
        // Signed over the batch, but for a different fee cap than submitted.
        sig.signature = _signBatch(_sig(_principalPull(), _feePull() + 1), keccak256(abi.encode(d, aux[0], aux[1])));

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        masp.deposit(d, sig, aux[0], aux[1]);
    }

    /// `feeAssetId` is inside the signed witness, so it cannot be changed after
    /// signing, even to another asset over a token the payer has approved.
    function test_revert_signature_feeAssetSwappedAfterSigning() public {
        _fundAndApprove(_signer());
        PubInputs.DepositRequest memory d = _crossRequest(_signer(), PLAIN_ID, FEE_ID, 0x100);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        MASP.Permit2Sig memory sig = _sig(_principalPull(), _feePull());
        sig.signature = _signBatch(sig, keccak256(abi.encode(d, aux[0], aux[1])));

        // Now a same-asset deposit on the single-token path, with a cap that
        // covers its larger single pull, so only the witness check can reject.
        d.feeAssetId = PLAIN_ID;
        sig.maxTotal = type(uint256).max;
        sig.maxFee = 0;
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        masp.deposit(d, sig, aux[0], aux[1]);
    }

    /// The fee token's cap is `maxFee`, checked by Permit2 per entry.
    function test_revert_signature_maxFeeTooLow() public {
        _fundAndApprove(_signer());
        PubInputs.DepositRequest memory d = _crossRequest(_signer(), PLAIN_ID, FEE_ID, 0x100);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        MASP.Permit2Sig memory sig = _sig(_principalPull(), _feePull() - 1);
        sig.signature = _signBatch(sig, keccak256(abi.encode(d, aux[0], aux[1])));

        vm.expectRevert(abi.encodeWithSelector(ISignatureTransfer.InvalidAmount.selector, _feePull() - 1));
        masp.deposit(d, sig, aux[0], aux[1]);
    }

    /// `maxTotal` caps only the deposit token on the two-token path: the
    /// relayer note no longer counts against it.
    function test_revert_signature_maxTotalExcludesRelayerNote() public {
        _fundAndApprove(_signer());
        PubInputs.DepositRequest memory d = _crossRequest(_signer(), PLAIN_ID, FEE_ID, 0x100);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        MASP.Permit2Sig memory sig = _sig(_principalPull() - 1, _feePull());
        sig.signature = _signBatch(sig, keccak256(abi.encode(d, aux[0], aux[1])));

        vm.expectRevert(abi.encodeWithSelector(ISignatureTransfer.InvalidAmount.selector, _principalPull() - 1));
        masp.deposit(d, sig, aux[0], aux[1]);
    }

    /// `maxFee` is meaningless on the single-token path and must be zero, so a
    /// wallet that signed a batch permit cannot have it read as a single one.
    function test_revert_BadMaxFee_sameAsset() public {
        PubInputs.DepositRequest memory d = _crossRequest(payer, PLAIN_ID, PLAIN_ID, 0x100);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        vm.expectRevert(MASP.BadMaxFee.selector);
        masp.deposit(d, _sig(type(uint256).max, 1), aux[0], aux[1]);
    }

    /// The zero-fee deposit is on the single-token path too.
    function test_revert_BadMaxFee_zeroFee() public {
        PubInputs.DepositRequest memory d = _crossRequest(payer, PLAIN_ID, 0, 0x100);
        d.feeIn = 0;
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        vm.expectRevert(MASP.BadMaxFee.selector);
        masp.deposit(d, _sig(type(uint256).max, 1), aux[0], aux[1]);
    }

    // --- allowance path -----------------------------------------------------

    function test_allowance_crossAsset_pullsBothTokens() public {
        _fundAndApprove(payer);
        _allowBoth(payer, uint160(_principalPull()), uint160(_feePull()));
        PubInputs.DepositRequest memory d = _crossRequest(payer, PLAIN_ID, FEE_ID, 0x200);

        uint256 tokenBefore = token.balanceOf(payer);
        uint256 feeBefore = feeToken.balanceOf(payer);
        _depositAuthorized(d);

        assertEq(tokenBefore - token.balanceOf(payer), _principalPull(), "principal + treasury fee in token");
        assertEq(feeBefore - feeToken.balanceOf(payer), _feePull(), "relayer note in the fee token");
        (uint160 left,,) = IAllowanceTransfer(permit2).allowance(payer, address(feeToken), address(masp));
        assertEq(left, 0, "fee allowance spent exactly");
        (left,,) = IAllowanceTransfer(permit2).allowance(payer, address(token), address(masp));
        assertEq(left, 0, "principal allowance spent exactly");
    }

    /// Each token draws on its own allowance.
    function test_revert_allowance_crossAsset_feeAllowanceTooLow() public {
        _fundAndApprove(payer);
        _allowBoth(payer, type(uint160).max, uint160(_feePull() - 1));
        PubInputs.DepositRequest memory d = _crossRequest(payer, PLAIN_ID, FEE_ID, 0x200);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.InsufficientAllowance.selector, _feePull() - 1));
        masp.depositAuthorized(d, aux[0], aux[1]);
    }

    /// A note in the deposit's own asset keeps today's single pull of
    /// `inAmt + fee + relayer`, and the fee token is untouched.
    function test_allowance_sameAsset_singlePull() public {
        _fundAndApprove(payer);
        _allowBoth(payer, type(uint160).max, type(uint160).max);
        PubInputs.DepositRequest memory d = _crossRequest(payer, PLAIN_ID, PLAIN_ID, 0x300);

        uint256 tokenBefore = token.balanceOf(payer);
        uint256 feeBefore = feeToken.balanceOf(payer);
        _depositAuthorized(d);

        assertEq(
            tokenBefore - token.balanceOf(payer),
            _principalPull() + uint256(FEE_IN) * SCALE,
            "one pull, relayer note under the principal's scale"
        );
        assertEq(feeToken.balanceOf(payer), feeBefore, "fee token untouched");
    }

    /// The branch is by asset id, not token: a yield principal paying its
    /// relayer in the plain id over the same ERC-20 takes the two-entry pull,
    /// and the note stays out of the yield books.
    function test_allowance_yieldPrincipal_plainFeeSameToken() public {
        token.mint(payer, type(uint128).max);
        _allow(type(uint160).max);
        PubInputs.DepositRequest memory d = _request(YIELD_ID, PUBLIC_IN, FEE_IN, 0x400);
        d.feeAssetId = PLAIN_ID;

        uint256 before = token.balanceOf(payer);
        uint256 unitsBefore = masp.yieldState(YIELD_ID).totalNormalized;
        _depositAuthorized(d);

        assertEq(
            masp.yieldState(YIELD_ID).totalNormalized - unitsBefore,
            uint256(PUBLIC_IN) + Fees.unitFee(PUBLIC_IN, FEE_BPS),
            "no fee units booked into the yield asset"
        );
        // Empty yield pool: one unit is `scale`, so the principal pull is
        // exact, and the plain note adds `feeIn * scale` beside it.
        uint256 principal = (uint256(PUBLIC_IN) + Fees.unitFee(PUBLIC_IN, FEE_BPS)) * SCALE;
        assertEq(before - token.balanceOf(payer), principal + uint256(FEE_IN) * SCALE, "both entries pulled");
    }

    // --- validation ---------------------------------------------------------

    function _expectDepositRevert(PubInputs.DepositRequest memory d, bytes memory err) internal {
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        vm.prank(d.payer);
        vm.expectRevert(err);
        masp.depositAuthorized(d, aux[0], aux[1]);
    }

    function test_revert_FeeAssetMustBeZero() public {
        PubInputs.DepositRequest memory d = _crossRequest(payer, PLAIN_ID, FEE_ID, 0x500);
        d.feeIn = 0;
        _expectDepositRevert(d, abi.encodeWithSelector(MASP.FeeAssetMustBeZero.selector));
    }

    /// A valued note in asset 0 is unprovable (the circuit forces a valued
    /// deposit leaf's asset non-zero), so it is refused at submit.
    function test_revert_FeeAssetUnsupported_zero() public {
        PubInputs.DepositRequest memory d = _crossRequest(payer, PLAIN_ID, 0, 0x500);
        _expectDepositRevert(d, abi.encodeWithSelector(MASP.FeeAssetUnsupported.selector, uint64(0)));
    }

    function test_revert_UnknownAsset_feeAsset() public {
        PubInputs.DepositRequest memory d = _crossRequest(payer, PLAIN_ID, UNKNOWN_ID, 0x500);
        _expectDepositRevert(d, abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, UNKNOWN_ID));
    }

    function test_revert_AssetDisabled_feeAsset() public {
        PubInputs.DepositRequest memory d = _crossRequest(payer, PLAIN_ID, DISABLED_ID, 0x500);
        _expectDepositRevert(d, abi.encodeWithSelector(AssetRegistry.AssetDisabled.selector, DISABLED_ID));
    }

    /// A yield asset may pay the relayer only as the deposit's own asset: its
    /// note would need units booked into that asset's supply.
    function test_revert_FeeAssetUnsupported_yield() public {
        PubInputs.DepositRequest memory d = _crossRequest(payer, PLAIN_ID, YIELD_ID, 0x500);
        _expectDepositRevert(d, abi.encodeWithSelector(MASP.FeeAssetUnsupported.selector, YIELD_ID));
    }

    /// The same yield asset is the same-asset path and is accepted.
    function test_yieldFeeAsset_accepted_whenDepositAsset() public {
        token.mint(payer, type(uint128).max);
        _allow(type(uint160).max);
        PubInputs.DepositRequest memory d = _request(YIELD_ID, PUBLIC_IN, FEE_IN, 0x600);
        d.feeAssetId = YIELD_ID;
        _depositAuthorized(d);
    }

    // --- flush --------------------------------------------------------------

    /// Flush binds the fee leaf to the submitted `feeAssetId` and accrues only
    /// the principal's treasury fee; the fee token stays as backing.
    function test_flush_crossAsset_settles() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _crossDeposit(PLAIN_ID, 0x700);
        _flush(id, _tpi(d, FEE_ID), submittedAt);

        assertEq(masp.escrowed(id), bytes32(0), "escrow drained");
        uint256 inAmt = uint256(PUBLIC_IN) * SCALE;
        assertEq(masp.accruedFee(IERC20(address(token))), (inAmt * FEE_BPS) / 10_000, "treasury fee in token");
        assertEq(masp.accruedFee(IERC20(address(feeToken))), 0, "nothing accrued in the fee token");
        assertEq(feeToken.balanceOf(address(masp)), _feePull(), "fee token backs the relayer note");
    }

    /// A flusher naming any other asset for the fee leaf reconstructs a
    /// different digest: the deposit asset, asset 0, or another plain asset.
    function test_revert_flush_feeLeafAssetTampered() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _crossDeposit(PLAIN_ID, 0x700);
        uint64[3] memory wrong = [PLAIN_ID, uint64(0), DISABLED_ID];
        for (uint256 k = 0; k < wrong.length; ++k) {
            PubInputs.TreeUpdateBatch memory tpi = _tpi(d, wrong[k]);
            uint256[] memory ids = new uint256[](1);
            ids[0] = id;
            MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
            meta[0] = MASP.DepositMeta({ payer: payer, submittedAt: submittedAt, fbps: FEE_BPS });
            vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
            masp.flushBatch(ids, meta, FixtureLoader.emptyProof(), tpi);
        }
    }

    // --- cancel -------------------------------------------------------------

    /// A two-token escrow refunds in both tokens, the relayer note separately.
    function test_cancel_crossAsset_refundsBothTokens() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _crossDeposit(PLAIN_ID, 0x800);
        vm.roll(vm.getBlockNumber() + masp.cancelDelay());

        uint256 tokenBefore = token.balanceOf(payer);
        uint256 feeBefore = feeToken.balanceOf(payer);
        vm.expectEmit(address(masp));
        emit MASP.DepositCanceled(id, payer, _principalPull(), FEE_ID, _feePull());
        (uint256 refunded, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(refunded, _principalPull(), "principal refund excludes the note");
        assertEq(feeRefunded, _feePull(), "note refunded in its own token");
        assertEq(token.balanceOf(payer) - tokenBefore, refunded, "token delivered");
        assertEq(feeToken.balanceOf(payer) - feeBefore, feeRefunded, "fee token delivered");
        assertEq(feeToken.balanceOf(address(masp)), 0, "no fee token left behind");
        assertEq(masp.escrowed(id), bytes32(0), "escrow cleared");
    }

    /// The same-asset cancel is unchanged: one refund, `feeRefunded == 0`.
    function test_cancel_sameAsset_singleRefund() public {
        _fundAndApprove(payer);
        _allowBoth(payer, type(uint160).max, type(uint160).max);
        PubInputs.DepositRequest memory d = _crossRequest(payer, PLAIN_ID, PLAIN_ID, 0x900);
        uint32 submittedAt = uint32(vm.getBlockNumber());
        uint256 id = _depositAuthorized(d);
        vm.roll(vm.getBlockNumber() + masp.cancelDelay());

        uint256 total = _principalPull() + uint256(FEE_IN) * SCALE;
        vm.expectEmit(address(masp));
        emit MASP.DepositCanceled(id, payer, total, PLAIN_ID, 0);
        (uint256 refunded, uint256 feeRefunded) = _cancel(d, id, submittedAt);
        assertEq(refunded, total, "whole pull in one token");
        assertEq(feeRefunded, 0, "no second refund");
    }

    /// Cancel resupplies `feeAssetId`; any other value mismatches the digest.
    function test_revert_cancel_feeAssetTampered() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _crossDeposit(PLAIN_ID, 0xa00);
        vm.roll(vm.getBlockNumber() + masp.cancelDelay());
        d.feeAssetId = PLAIN_ID;
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        _cancel(d, id, submittedAt);
    }

    /// A yield principal refunds through `YieldOps.cancel` with no note units,
    /// capped at its principal pull; the plain note refunds its fixed value.
    function test_cancel_yieldPrincipal_plainFee() public {
        (uint256 id, PubInputs.DepositRequest memory d, uint32 submittedAt) = _crossDeposit(YIELD_ID, 0xb00);
        uint256 principal = (uint256(PUBLIC_IN) + Fees.unitFee(PUBLIC_IN, FEE_BPS)) * SCALE;
        assertEq(masp.yieldState(YIELD_ID).totalNormalized, PUBLIC_IN + Fees.unitFee(PUBLIC_IN, FEE_BPS), "units");

        vm.roll(vm.getBlockNumber() + masp.cancelDelay());
        uint256 feeBefore = feeToken.balanceOf(payer);
        (uint256 refunded, uint256 feeRefunded) = _cancel(d, id, submittedAt);

        assertEq(refunded, principal, "principal refund at a flat index");
        assertEq(feeRefunded, _feePull(), "plain note refunded in the fee token");
        assertEq(feeToken.balanceOf(payer) - feeBefore, _feePull(), "fee token delivered");
        assertEq(masp.yieldState(YIELD_ID).totalNormalized, 0, "every unit burned");
    }

    // --- satellites ---------------------------------------------------------

    /// A satellite measures one token, so it refuses a relayer note in another
    /// asset before calling the pool.
    function test_revert_satellite_FeeAssetMismatch() public {
        MockWETH9 weth = new MockWETH9();
        vm.prank(OWNER);
        masp.addAsset(WETH_ID, IERC20(address(weth)), SCALE, FEE_BPS, FEE_BPS);
        NativeAdapter adapter =
            new NativeAdapter(IMASPPool(address(masp)), IWrappedNative(address(weth)), IAllowanceTransfer(permit2));

        PubInputs.DepositRequest memory d = _crossRequest(address(adapter), WETH_ID, FEE_ID, 0xc00);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(MaspEscrowSatellite.FeeAssetMismatch.selector);
        adapter.depositNative{ value: 1 ether }(d, aux[0], aux[1]);
    }
}
