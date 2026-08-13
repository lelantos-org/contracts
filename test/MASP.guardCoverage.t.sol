// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { AssetRegistry } from "../src/AssetRegistry.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// Guards with no direct assertion elsewhere in the suite: constructor
/// dependency checks, registry bounds, spend-path magnitude bounds, batch
/// mode, and the small-subgroup rejection in `AuxValidation`.
contract MASPGuardCoverageTest is Test {
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant TREASURY = address(0xfee);
    address internal constant RELAYER = address(0xCA11);
    address internal constant PAYER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xF00D);

    MockERC20 internal token;
    IVerifier internal v;
    IVerifier internal tub;
    address internal permit2;
    MASP internal masp;

    function setUp() public {
        token = new MockERC20("T", "T", 18);
        v = IVerifier(address(new MockERC20("v", "v", 18)));
        tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        permit2 = new DeployPermit2().deployPermit2();
        masp = _deploy(v, tub, ISignatureTransfer(permit2), _ids(), _tokens(), _scales());
        vm.mockCall(address(v), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
        vm.mockCall(address(tub), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
    }

    // --- helpers -----------------------------------------------------------

    function _ids() internal pure returns (uint64[] memory a) {
        a = new uint64[](1);
        a[0] = ASSET_ID;
    }

    function _tokens() internal view returns (IERC20[] memory a) {
        a = new IERC20[](1);
        a[0] = IERC20(address(token));
    }

    function _scales() internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = SCALE;
    }

    function _deploy(
        IVerifier v_,
        IVerifier tub_,
        ISignatureTransfer p2,
        uint64[] memory ids,
        IERC20[] memory tokens,
        uint256[] memory scales
    ) internal returns (MASP) {
        return new MASP(v_, tub_, p2, ids, tokens, scales, FEE_BPS, TREASURY, address(this));
    }

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return MASP.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    function _aux() internal pure returns (AuxValidation.Output[3] memory aux) {
        for (uint256 j = 0; j < 3; j++) {
            aux[j].clueRx = BabyJubJub.BASE8_X;
            aux[j].clueRy = BabyJubJub.BASE8_Y;
            aux[j].ephPubX = BabyJubJub.BASE8_X;
            aux[j].ephPubY = BabyJubJub.BASE8_Y;
            aux[j].ciphertext = hex"0001";
        }
    }

    function _pi() internal view returns (PubInputs.Transact memory pi) {
        pi.chainId = block.chainid;
        pi.publicAssetId = ASSET_ID;
        pi.publicOut = 1;
        pi.recipient = RECIPIENT;
        pi.payer = PAYER;
        pi.relayer = RELAYER;
        pi.nullifier[0] = bytes32(uint256(0x1111));
        pi.nullifier[1] = bytes32(uint256(0x2222));
        pi.nullifier[2] = bytes32(uint256(0x2223));
        pi.outCm[0] = bytes32(uint256(0x3333));
        pi.outCm[1] = bytes32(uint256(0x4444));
        pi.outCm[2] = bytes32(uint256(0x4445));
        pi.merkleRoot = masp.currentRoot();
    }

    function _tpi(PubInputs.Transact memory pi) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = 3;
        tpi.cms[0] = pi.outCm[0];
        tpi.cms[1] = pi.outCm[1];
        tpi.cms[2] = pi.outCm[2];
    }

    // --- constructor dependency checks -------------------------------------

    function test_revert_ZeroVerifier_transact() public {
        vm.expectRevert(MASP.ZeroVerifier.selector);
        _deploy(IVerifier(address(0)), tub, ISignatureTransfer(permit2), _ids(), _tokens(), _scales());
    }

    function test_revert_ZeroVerifier_treeUpdate() public {
        vm.expectRevert(MASP.ZeroVerifier.selector);
        _deploy(v, IVerifier(address(0)), ISignatureTransfer(permit2), _ids(), _tokens(), _scales());
    }

    /// The check is `code.length == 0`, so an EOA-shaped address is rejected
    /// even though it is non-zero.
    function test_revert_ZeroVerifier_codelessAddress() public {
        vm.expectRevert(MASP.ZeroVerifier.selector);
        _deploy(IVerifier(address(0xdeadbeef)), tub, ISignatureTransfer(permit2), _ids(), _tokens(), _scales());
    }

    function test_revert_ZeroPermit2() public {
        vm.expectRevert(MASP.ZeroPermit2.selector);
        _deploy(v, tub, ISignatureTransfer(address(0)), _ids(), _tokens(), _scales());
    }

    // --- registry bounds ---------------------------------------------------

    function test_revert_LengthMismatch_tokens() public {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token));
        tokens[1] = IERC20(address(token));
        vm.expectRevert(AssetRegistry.LengthMismatch.selector);
        _deploy(v, tub, ISignatureTransfer(permit2), _ids(), tokens, _scales());
    }

    function test_revert_LengthMismatch_scales() public {
        uint256[] memory scales = new uint256[](2);
        vm.expectRevert(AssetRegistry.LengthMismatch.selector);
        _deploy(v, tub, ISignatureTransfer(permit2), _ids(), _tokens(), scales);
    }

    function test_revert_ScaleTooLarge() public {
        vm.expectRevert(AssetRegistry.ScaleTooLarge.selector);
        masp.addAsset(2, IERC20(address(token)), 1e18 + 1);
    }

    function test_scaleAtBound_accepted() public {
        masp.addAsset(2, IERC20(address(token)), 1e18);
        assertEq(masp.asset(2).scale, 1e18, "scale at bound");
    }

    // --- spend-path magnitude + mode bounds --------------------------------

    function test_revert_PublicOutTooLarge() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicOut = uint64(type(uint48).max) + 1;
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.PublicOutTooLarge.selector);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, _aux());
    }

    /// `flushBatch` slots must be deposits; a spend-mode slot is rejected
    /// before any digest comparison.
    function test_revert_BadDepositMode() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: PAYER, submittedAt: uint32(block.number), fbps: FEE_BPS });

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = 1;
        tpi.isDeposit[0] = 0; // spend mode

        // Seed a pending deposit so the slot passes the pending check first.
        _seedDeposit();

        vm.expectRevert(MASP.BadDepositMode.selector);
        masp.flushBatch(ids, meta, _emptyProof(), tpi);
    }

    function _seedDeposit() internal {
        token.mint(address(this), 1_000 * SCALE);
        token.approve(address(permit2), type(uint256).max);
        ISignatureTransfer(permit2); // silence unused warning path
        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = 1;
        d.payer = address(this);
        d.recipient = RECIPIENT;
        d.outCm = bytes32(uint256(0x1));
        // AllowanceTransfer path avoids needing a signature.
        _approvePermit2ToMasp();
        masp.depositAuthorized(d, _aux()[0]);
    }

    function _approvePermit2ToMasp() internal {
        (bool ok,) = permit2.call(
            abi.encodeWithSignature(
                "approve(address,address,uint160,uint48)",
                address(token),
                address(masp),
                type(uint160).max,
                type(uint48).max
            )
        );
        require(ok, "permit2 approve");
    }

    // --- small-subgroup rejection ------------------------------------------

    /// `AuxValidation` rejects order-8 points on the clue and ephemeral keys.
    /// `BabyJubJub.isLowOrder` is fuzzed directly elsewhere; this pins the
    /// revert wiring in the spend path.
    function test_revert_LowOrderPoint_clue() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        AuxValidation.Output[3] memory aux = _aux();
        // Identity (0, 1) is on-curve and order 1.
        aux[0].clueRx = 0;
        aux[0].clueRy = 1;
        vm.prank(RELAYER);
        vm.expectRevert(AuxValidation.LowOrderPoint.selector);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, aux);
    }

    function test_revert_LowOrderPoint_ephemeral() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        AuxValidation.Output[3] memory aux = _aux();
        aux[1].ephPubX = 0;
        aux[1].ephPubY = 1;
        aux[2].ephPubX = 0;
        aux[2].ephPubY = 1;
        vm.prank(RELAYER);
        vm.expectRevert(AuxValidation.LowOrderPoint.selector);
        masp.withdraw(_emptyProof(), pi, _emptyProof(), tpi, aux);
    }

    // --- off-chain dry-run helpers -----------------------------------------

    /// `verifyProof` / `verifyTreeUpdateBatch` are view helpers on the public
    /// ABI; they must route through the same compression as the spend path.
    function test_dryRunHelpersRouteToVerifiers() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.TreeUpdateBatch memory tpi = _tpi(pi);
        assertTrue(masp.verifyProof(_emptyProof(), pi, _aux()), "transact helper");
        assertTrue(masp.verifyTreeUpdateBatch(_emptyProof(), tpi), "tree-update helper");

        vm.mockCall(address(v), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(false));
        assertFalse(masp.verifyProof(_emptyProof(), pi, _aux()), "transact helper reports rejection");
    }
}
