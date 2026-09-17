// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { IEIP712 } from "permit2/src/interfaces/IEIP712.sol";

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { Fees } from "../../src/libs/Fees.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { YieldTestBase } from "../utils/YieldTestBase.sol";

/// A deposit whose relayer fee note is paid in a different registered asset
/// (`DepositRequest.feeAssetId`). The treasury's deposit fee stays in the
/// deposit asset; only the relayer's note, its pull and its refund move to the
/// fee asset.
///
/// Built on `YieldTestBase` for its two ids over one ERC-20 (`PLAIN_ID`,
/// `YIELD_ID`) and its accepting verifiers. A second ERC-20 is registered as
/// the fee asset under a `scale` different from the principal's, so a fee
/// priced against the wrong registry entry is off by orders of magnitude.
///
/// Fixture, pricing, signing, flush and cancel helpers shared by the
/// `MASP.depositFeeAsset*.t.sol` suites.
abstract contract DepositFeeAssetTestBase is YieldTestBase {
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

    function setUp() public virtual override {
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
}
