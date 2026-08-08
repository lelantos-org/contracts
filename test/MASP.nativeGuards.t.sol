// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../src/interfaces/IWrappedNative.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockWETH9 } from "./mocks/MockWETH9.sol";
import { MockERC1271 } from "./mocks/MockERC1271.sol";

/// Native-bridge guard coverage for `withdrawNative` and `submitIntentNative`.
/// Two MASP instances: one without WETH (address(0)) and one with WETH.
contract MASPNativeGuardsTest is Test {
    uint64 internal constant ASSET_ERC20 = 1; // plain ERC-20 (not WETH)
    uint64 internal constant ASSET_WETH = 2; // WETH-backed asset
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;

    address internal constant RELAYER = address(0xCA11);
    address internal constant PAYER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xF00D);

    MockERC20 token;
    MockWETH9 weth;

    MASP maspNoWeth; // WRAPPED_NATIVE = address(0)
    MASP maspWithWeth; // WRAPPED_NATIVE = weth; two assets registered

    address permit2;

    function setUp() public {
        token = new MockERC20("T", "T", 18);
        weth = new MockWETH9();
        permit2 = new DeployPermit2().deployPermit2();

        IVerifier v = IVerifier(address(new MockERC20("v", "v", 18)));
        IVerifier tub = IVerifier(address(new MockERC20("tub", "tub", 18)));

        // MASP with no WETH.
        {
            uint64[] memory ids = new uint64[](1);
            IERC20[] memory tokens = new IERC20[](1);
            uint256[] memory scales = new uint256[](1);
            ids[0] = ASSET_ERC20;
            tokens[0] = IERC20(address(token));
            scales[0] = SCALE;
            maspNoWeth = new MASP(
                v,
                tub,
                ISignatureTransfer(address(permit2)),
                IWrappedNative(address(0)),
                ids,
                tokens,
                scales,
                FEE_BPS,
                address(0xfee),
                address(this)
            );
        }

        // MASP with WETH, two assets.
        {
            uint64[] memory ids = new uint64[](2);
            IERC20[] memory tokens = new IERC20[](2);
            uint256[] memory scales = new uint256[](2);
            ids[0] = ASSET_ERC20;
            tokens[0] = IERC20(address(token));
            scales[0] = SCALE;
            ids[1] = ASSET_WETH;
            tokens[1] = IERC20(address(weth));
            scales[1] = SCALE;
            maspWithWeth = new MASP(
                v,
                tub,
                ISignatureTransfer(address(permit2)),
                IWrappedNative(address(weth)),
                ids,
                tokens,
                scales,
                FEE_BPS,
                address(0xfee),
                address(this)
            );
        }
    }

    // --- helpers -----------------------------------------------------------

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return MASP.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    function _validAux() internal pure returns (AuxValidation.Output[2] memory aux) {
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

    function _validTransactPi(MASP m, uint64 assetId) internal view returns (PubInputs.Transact memory pi) {
        pi.chainId = block.chainid;
        pi.publicAssetId = assetId;
        pi.publicIn = 0;
        pi.publicOut = 1;
        pi.recipient = RECIPIENT;
        pi.payer = PAYER;
        pi.relayer = RELAYER;
        pi.nullifier[0] = bytes32(uint256(0x1111));
        pi.nullifier[1] = bytes32(uint256(0x2222));
        pi.outCm[0] = bytes32(uint256(0x3333));
        pi.outCm[1] = bytes32(uint256(0x4444));
        pi.merkleRoot = m.currentRoot();
    }

    function _validTpi(MASP m, PubInputs.Transact memory pi)
        internal
        view
        returns (PubInputs.TreeUpdateBatch memory tpi)
    {
        tpi.oldRoot = m.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = m.committedCount();
        tpi.actualCount = 1;
        tpi.cms[0] = pi.outCm[0];
        tpi.cms[1] = pi.outCm[1];
    }

    function _validIntent(MASP, uint64 assetId, address payer)
        internal
        view
        returns (PubInputs.DepositIntent memory d)
    {
        d.chainId = block.chainid;
        d.publicAssetId = assetId;
        d.publicIn = 1;
        d.payer = payer;
        d.recipient = RECIPIENT;
        d.outCm[0] = bytes32(uint256(0x1));
        d.outCm[1] = bytes32(uint256(0x2));
    }

    // --- withdrawNative guards ---------------------------------------------

    function test_withdrawNative_WrappedNativeNotConfigured() public {
        PubInputs.Transact memory pi = _validTransactPi(maspNoWeth, ASSET_ERC20);
        pi.publicIn = 0;
        pi.publicOut = 1;
        PubInputs.TreeUpdateBatch memory tpi = _validTpi(maspNoWeth, pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.WrappedNativeNotConfigured.selector);
        maspNoWeth.withdrawNative(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    /// WETH configured but asset resolves to non-WETH ERC-20 → AssetNotWrappedNative.
    /// Must pass _validateRequest first (valid structure, known root, etc.).
    function test_withdrawNative_AssetNotWrappedNative() public {
        PubInputs.Transact memory pi = _validTransactPi(maspWithWeth, ASSET_ERC20);
        PubInputs.TreeUpdateBatch memory tpi = _validTpi(maspWithWeth, pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.AssetNotWrappedNative.selector);
        maspWithWeth.withdrawNative(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    // --- withdrawNative success path ---------------------------------------

    /// Fund the pool with WETH so an unshield has backing, and accept any
    /// proof. The guard tests above all revert before `_finalize`, so the
    /// unwrap and native-send legs are only reached from here.
    function _armWethWithdraw(uint256 wethAmount) internal {
        vm.deal(address(this), wethAmount);
        weth.deposit{ value: wethAmount }();
        weth.transfer(address(maspWithWeth), wethAmount);
        vm.mockCall(
            address(maspWithWeth.VERIFIER()), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true)
        );
        vm.mockCall(
            address(maspWithWeth.TREE_UPDATE_BATCH_VERIFIER()),
            abi.encodeWithSelector(IVerifier.verifyProof.selector),
            abi.encode(true)
        );
    }

    function test_withdrawNative_unwrapsAndSendsNative() public {
        uint64 publicOut = 7;
        uint256 gross = uint256(publicOut) * SCALE;
        uint256 fee = (gross * FEE_BPS) / 10_000;
        uint256 net = gross - fee;
        _armWethWithdraw(gross);

        PubInputs.Transact memory pi = _validTransactPi(maspWithWeth, ASSET_WETH);
        pi.publicOut = publicOut;
        PubInputs.TreeUpdateBatch memory tpi = _validTpi(maspWithWeth, pi);

        uint64 countBefore = maspWithWeth.committedCount();

        vm.expectEmit(true, true, true, true, address(maspWithWeth));
        emit MASP.AssetMoved(ASSET_WETH, IERC20(address(weth)), 0, gross);

        vm.prank(RELAYER);
        maspWithWeth.withdrawNative(_emptyProof(), pi, _emptyProof(), tpi, _validAux());

        // Recipient is paid in raw native, not WETH.
        assertEq(RECIPIENT.balance, net, "recipient native");
        assertEq(weth.balanceOf(RECIPIENT), 0, "recipient holds no WETH");
        // The fee stays wrapped and is claimable via `sweep`.
        assertEq(maspWithWeth.accruedFee(IERC20(address(weth))), fee, "accrued fee in WETH");
        assertEq(weth.balanceOf(address(maspWithWeth)), fee, "pool retains only the fee");
        assertEq(address(maspWithWeth).balance, 0, "pool holds no leftover native");
        assertEq(maspWithWeth.committedCount(), countBefore + 2, "two leaves committed");
        assertTrue(maspWithWeth.spent(pi.nullifier[0]), "nf0 spent");
        assertTrue(maspWithWeth.spent(pi.nullifier[1]), "nf1 spent");
    }

    /// The unwrap leg pushes raw native to `pi.recipient`; a recipient that
    /// rejects it must surface `NativeTransferFailed` rather than stranding
    /// the funds.
    function test_withdrawNative_recipientRejectsNative() public {
        uint64 publicOut = 7;
        uint256 gross = uint256(publicOut) * SCALE;
        _armWethWithdraw(gross);

        address rejector = address(new NativeRejector());
        PubInputs.Transact memory pi = _validTransactPi(maspWithWeth, ASSET_WETH);
        pi.publicOut = publicOut;
        pi.recipient = rejector;
        PubInputs.TreeUpdateBatch memory tpi = _validTpi(maspWithWeth, pi);

        vm.prank(RELAYER);
        vm.expectRevert(MASP.NativeTransferFailed.selector);
        maspWithWeth.withdrawNative(_emptyProof(), pi, _emptyProof(), tpi, _validAux());
    }

    // --- submitIntentNative guards -----------------------------------------

    function test_submitIntentNative_WrappedNativeNotConfigured() public {
        PubInputs.DepositIntent memory d = _validIntent(maspNoWeth, ASSET_ERC20, PAYER);
        vm.prank(PAYER);
        vm.expectRevert(MASP.WrappedNativeNotConfigured.selector);
        maspNoWeth.submitIntentNative{ value: 0 }(d, _validAux());
    }

    /// WETH configured but asset id points to plain ERC-20 → AssetNotWrappedNative.
    function test_submitIntentNative_AssetNotWrappedNative() public {
        PubInputs.DepositIntent memory d = _validIntent(maspWithWeth, ASSET_ERC20, PAYER);
        vm.prank(PAYER);
        vm.expectRevert(MASP.AssetNotWrappedNative.selector);
        maspWithWeth.submitIntentNative{ value: 0 }(d, _validAux());
    }

    /// Caller != d.payer → PayerNotSender.
    function test_submitIntentNative_PayerNotSender() public {
        PubInputs.DepositIntent memory d = _validIntent(maspWithWeth, ASSET_WETH, PAYER);
        address notPayer = address(0xBAD);
        vm.prank(notPayer); // sender != d.payer
        vm.expectRevert(MASP.PayerNotSender.selector);
        maspWithWeth.submitIntentNative{ value: 0 }(d, _validAux());
    }

    /// msg.value != inAmt + fee → MsgValueMismatch.
    function test_submitIntentNative_MsgValueMismatch() public {
        PubInputs.DepositIntent memory d = _validIntent(maspWithWeth, ASSET_WETH, PAYER);
        uint256 inAmt = uint256(d.publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;
        uint256 correct = inAmt + fee;
        uint256 wrong = correct + 1;

        vm.deal(PAYER, wrong);
        vm.prank(PAYER);
        vm.expectRevert(MASP.MsgValueMismatch.selector);
        maspWithWeth.submitIntentNative{ value: wrong }(d, _validAux());
    }

    /// Correct msg.value → no revert on native-specific guards (proceeds to
    /// WETH.deposit → WETH balance insufficient revert, confirming guards passed).
    function test_submitIntentNative_correctValue_passesMsgValueCheck() public {
        PubInputs.DepositIntent memory d = _validIntent(maspWithWeth, ASSET_WETH, PAYER);
        uint256 inAmt = uint256(d.publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;
        uint256 correct = inAmt + fee;

        vm.deal(PAYER, correct);
        vm.prank(PAYER);
        // MockWETH9 accepts any deposit value, so the call reaches
        // _finalizeIntent.
        uint256 id = maspWithWeth.submitIntentNative{ value: correct }(d, _validAux());
        assertEq(id, 0);
    }
}

/// Rejects raw native, forcing the `_sendNative` low-level call to fail.
contract NativeRejector {
    receive() external payable {
        revert("no native");
    }
}
