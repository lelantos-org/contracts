// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { AssetRegistry } from "../src/AssetRegistry.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { Groth16Verifier } from "../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC1271 } from "./mocks/MockERC1271.sol";

/// `flushBatch` contract-level coverage. SNARK verification is mocked via
/// `vm.mockCall`, isolating the storage/event/sentinel logic from circuit-side
/// correctness, which is covered separately with real fixtures.
contract MASPFlushBatchTest is Test {
    uint64 internal constant ASSET_ID = 1;
    uint64 internal constant ASSET_ID_ALT = 2;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);

    Groth16Verifier verifier;
    TreeUpdateBatchGroth16Verifier tubVerifier;
    address permit2;
    MockERC20 token;
    MockERC20 tokenAlt;
    MASP masp;

    address payer = address(0xface);
    address recipient = address(0xb0b);

    function setUp() public {
        verifier = new Groth16Verifier();
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("M", "M", 18);
        tokenAlt = new MockERC20("A", "A", 18);

        uint64[] memory ids = new uint64[](2);
        IERC20[] memory tokens = new IERC20[](2);
        uint256[] memory scales = new uint256[](2);
        ids[0] = ASSET_ID;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;
        ids[1] = ASSET_ID_ALT;
        tokens[1] = IERC20(address(tokenAlt));
        scales[1] = SCALE;

        masp = new MASP(
            IVerifier(address(verifier)),
            IVerifier(address(tubVerifier)),
            ISignatureTransfer(address(permit2)),
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

    // --- helpers -----------------------------------------------------------

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

    function _request(uint64 publicIn, uint64 assetId, bytes32 cm)
        internal
        view
        returns (PubInputs.DepositRequest memory d)
    {
        d.chainId = block.chainid;
        d.publicAssetId = assetId;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = recipient;
        d.outCm = cm;
    }

    function _fund(MockERC20 t, uint64 publicIn) internal {
        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;
        t.mint(payer, inAmt + fee);
        vm.prank(payer);
        t.approve(address(permit2), type(uint256).max);
    }

    function _submit(uint64 publicIn, uint64 assetId, bytes32 cm, uint256 nonce) internal returns (uint256 id) {
        PubInputs.DepositRequest memory d = _request(publicIn, assetId, cm);
        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: nonce, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00"
        });
        return masp.deposit(d, sig, _aux()[0]);
    }

    /// Digest meta for deposits submitted in the current block by `payer` at
    /// the deploy-time fee — matches every `_submit` in this suite.
    function _meta(uint256 n) internal view returns (MASP.DepositMeta[] memory m) {
        m = new MASP.DepositMeta[](n);
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            m[i] = MASP.DepositMeta({ payer: payer, submittedAt: uint32(block.number), fbps: FEE_BPS });
        }
    }

    function _emptyProof() internal pure returns (MASP.Proof memory p) {
        p.a = [uint256(0), 0];
        p.b = [[uint256(0), 0], [uint256(0), 0]];
        p.c = [uint256(0), 0];
    }

    function _mockSnark(bool ok) internal {
        // Force the batch verifier to return `ok` for any input.
        vm.mockCall(address(tubVerifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(ok));
    }

    function _tpi(uint256 n, bytes32[] memory cms) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xfeedbeef));
        tpi.startIndex = masp.committedCount();
        // forge-lint: disable-next-line(unsafe-typecast)
        tpi.actualCount = uint64(n);
        // Clamp to `bytes32[MAX_L_BATCH]` capacity; oversize cms arrays
        // (used by oversize-batch revert tests) must not OOB tpi.cms.
        uint256 cap = PubInputs.MAX_L_BATCH;
        for (uint256 i = 0; i < cms.length && i < cap; i++) {
            tpi.cms[i] = cms[i];
        }
    }

    /// Fill the per-active-slot PIs that `flushBatch` cross-checks against
    /// the escrow record. cvDep coords stay zero — `_request` leaves
    /// `DepositRequest.cvDep` zero so the escrow digest is over (0,0).
    function _fillLeafPI(PubInputs.TreeUpdateBatch memory tpi, uint64[] memory assetIds, uint64[] memory publicIns)
        internal
        pure
    {
        for (uint256 i = 0; i < assetIds.length; i++) {
            tpi.leafAsset[i] = assetIds[i];
            tpi.leafPublicIn[i] = publicIns[i];
            tpi.isDeposit[i] = 1;
        }
    }

    // --- happy paths -------------------------------------------------------

    function test_happy_N1_advancesRootAndClearsSlot() public {
        _fund(token, 100);
        bytes32 cm0 = bytes32(uint256(0x111));
        uint256 id = _submit(100, ASSET_ID, cm0, 0);

        bytes32[] memory cms = new bytes32[](1);
        cms[0] = cm0;
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        uint64[] memory a = new uint64[](1);
        uint64[] memory p = new uint64[](1);
        a[0] = ASSET_ID;
        p[0] = 100;
        _fillLeafPI(tpi, a, p);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        _mockSnark(true);
        masp.flushBatch(ids, _meta(1), _emptyProof(), tpi);

        // Root advanced
        assertEq(masp.currentRoot(), tpi.newRoot, "root advanced");
        assertEq(masp.committedCount(), 1, "count += n (one leaf per deposit)");

        // Slot cleared (sentinel check)
        assertEq(masp.escrowed(id), bytes32(0), "slot cleared");

        // Fee accrued at flush (submit accrues nothing).
        uint256 expectedFee = (uint256(100) * SCALE * FEE_BPS) / 10_000;
        assertEq(masp.accruedFee(IERC20(address(token))), expectedFee, "fee accrued at flush");
    }

    function test_happy_N3_singleAsset() public {
        _fund(token, 100);
        _fund(token, 100);
        _fund(token, 100);

        uint256 id0 = _submit(100, ASSET_ID, bytes32(uint256(1)), 0);
        uint256 id1 = _submit(100, ASSET_ID, bytes32(uint256(3)), 1);
        uint256 id2 = _submit(100, ASSET_ID, bytes32(uint256(5)), 2);

        // Three deposits, three leaves — an odd batch, which the leaf-granular
        // circuit and `_advanceRoot(.., n, ..)` now express directly.
        bytes32[] memory cms = new bytes32[](3);
        cms[0] = bytes32(uint256(1));
        cms[1] = bytes32(uint256(3));
        cms[2] = bytes32(uint256(5));
        PubInputs.TreeUpdateBatch memory tpi = _tpi(3, cms);
        uint64[] memory a = new uint64[](3);
        uint64[] memory p = new uint64[](3);
        a[0] = ASSET_ID;
        a[1] = ASSET_ID;
        a[2] = ASSET_ID;
        p[0] = 100;
        p[1] = 100;
        p[2] = 100;
        _fillLeafPI(tpi, a, p);

        uint256[] memory ids = new uint256[](3);
        ids[0] = id0;
        ids[1] = id1;
        ids[2] = id2;

        _mockSnark(true);
        masp.flushBatch(ids, _meta(3), _emptyProof(), tpi);

        assertEq(masp.committedCount(), 3, "count += 3 (odd leaf count)");
        uint256 feePer = (uint256(100) * SCALE * FEE_BPS) / 10_000;
        assertEq(masp.accruedFee(IERC20(address(token))), 3 * feePer, "all three fees accrued");
    }

    // --- reverts -----------------------------------------------------------

    function test_revert_BadBatchSize_zero() public {
        bytes32[] memory cms = new bytes32[](0);
        PubInputs.TreeUpdateBatch memory tpi = _tpi(0, cms);
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(MASP.BadBatchSize.selector);
        masp.flushBatch(ids, _meta(0), _emptyProof(), tpi);
    }

    function test_revert_BadBatchSize_overMax() public {
        uint256 n = PubInputs.MAX_L_BATCH + 1;
        uint256[] memory ids = new uint256[](n);
        bytes32[] memory cms = new bytes32[](n);
        // forge-lint: disable-next-line(unsafe-typecast)
        PubInputs.TreeUpdateBatch memory tpi = _tpi(n, cms);
        vm.expectRevert(MASP.BadBatchSize.selector);
        masp.flushBatch(ids, _meta(n), _emptyProof(), tpi);
    }

    function test_revert_BadBatchSize_metaLengthMismatch() public {
        _fund(token, 100);
        uint256 id = _submit(100, ASSET_ID, bytes32(uint256(1)), 0);
        bytes32[] memory cms = new bytes32[](1);
        cms[0] = bytes32(uint256(1));
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectRevert(MASP.BadBatchSize.selector);
        masp.flushBatch(ids, _meta(2), _emptyProof(), tpi);
    }

    function test_revert_BatchMisaligned_actualCountMismatch() public {
        _fund(token, 100);
        _submit(100, ASSET_ID, bytes32(uint256(1)), 0);

        bytes32[] memory cms = new bytes32[](1);
        cms[0] = bytes32(uint256(1));
        PubInputs.TreeUpdateBatch memory tpi = _tpi(2, cms); // n=2 but ids.length=1

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.expectRevert(MASP.BatchMisaligned.selector);
        masp.flushBatch(ids, _meta(1), _emptyProof(), tpi);
    }

    function test_revert_StaleOldRoot() public {
        bytes32[] memory cms = new bytes32[](2);
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        tpi.oldRoot = bytes32(uint256(0xbad));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.expectRevert(MASP.StaleOldRoot.selector);
        masp.flushBatch(ids, _meta(1), _emptyProof(), tpi);
    }

    function test_revert_DepositNotPending_unknownId() public {
        bytes32[] memory cms = new bytes32[](2);
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;
        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, 999));
        masp.flushBatch(ids, _meta(1), _emptyProof(), tpi);
    }

    function test_revert_DigestMismatch_cmTampered() public {
        _fund(token, 100);
        uint256 id = _submit(100, ASSET_ID, bytes32(uint256(1)), 0);

        bytes32[] memory cms = new bytes32[](2);
        cms[0] = bytes32(uint256(99)); // tamper
        cms[1] = bytes32(uint256(2));
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        uint64[] memory a = new uint64[](1);
        uint64[] memory p = new uint64[](1);
        a[0] = ASSET_ID;
        p[0] = 100;
        _fillLeafPI(tpi, a, p);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.flushBatch(ids, _meta(1), _emptyProof(), tpi);
    }

    function test_revert_DigestMismatch_metaTampered() public {
        _fund(token, 100);
        uint256 id = _submit(100, ASSET_ID, bytes32(uint256(1)), 0);

        bytes32[] memory cms = new bytes32[](1);
        cms[0] = bytes32(uint256(1));
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        uint64[] memory a = new uint64[](1);
        uint64[] memory p = new uint64[](1);
        a[0] = ASSET_ID;
        p[0] = 100;
        _fillLeafPI(tpi, a, p);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        // Wrong fbps in meta.
        MASP.DepositMeta[] memory m = _meta(1);
        m[0].fbps = FEE_BPS + 1;
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.flushBatch(ids, m, _emptyProof(), tpi);

        // Wrong payer in meta.
        m = _meta(1);
        m[0].payer = address(0xbad);
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.flushBatch(ids, m, _emptyProof(), tpi);

        // Wrong submittedAt in meta.
        m = _meta(1);
        m[0].submittedAt += 1;
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.flushBatch(ids, m, _emptyProof(), tpi);
    }

    function test_happy_mixedAssetBatch() public {
        // Two deposits of different assets in the same flush. Per-token
        // fees accrue independently in the tail loop.
        _fund(token, 100);
        _fund(tokenAlt, 100);
        uint256 id0 = _submit(100, ASSET_ID, bytes32(uint256(1)), 0);
        uint256 id1 = _submit(100, ASSET_ID_ALT, bytes32(uint256(3)), 1);

        // Pre-flush: nothing accrued for either token.
        uint256 inAmt = uint256(100) * SCALE;
        uint256 expectedFee = (inAmt * FEE_BPS) / 10_000;
        assertEq(masp.accruedFee(IERC20(address(token))), 0, "token nothing accrued pre-flush");
        assertEq(masp.accruedFee(IERC20(address(tokenAlt))), 0, "tokenAlt nothing accrued pre-flush");

        bytes32[] memory cms = new bytes32[](2);
        cms[0] = bytes32(uint256(1));
        cms[1] = bytes32(uint256(3));
        PubInputs.TreeUpdateBatch memory tpi = _tpi(2, cms);
        uint64[] memory a = new uint64[](2);
        uint64[] memory p = new uint64[](2);
        a[0] = ASSET_ID;
        a[1] = ASSET_ID_ALT;
        p[0] = 100;
        p[1] = 100;
        _fillLeafPI(tpi, a, p);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id0;
        ids[1] = id1;

        _mockSnark(true);
        masp.flushBatch(ids, _meta(2), _emptyProof(), tpi);

        // Both tokens' fees accrued at flush.
        assertEq(masp.accruedFee(IERC20(address(token))), expectedFee, "token fee accrued");
        assertEq(masp.accruedFee(IERC20(address(tokenAlt))), expectedFee, "tokenAlt fee accrued");
        assertEq(masp.committedCount(), 2, "count += 2 (one leaf per deposit)");
    }

    function test_revert_TreeUpdateRejected() public {
        _fund(token, 100);
        uint256 id = _submit(100, ASSET_ID, bytes32(uint256(1)), 0);

        bytes32[] memory cms = new bytes32[](1);
        cms[0] = bytes32(uint256(1));
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        uint64[] memory a = new uint64[](1);
        uint64[] memory p = new uint64[](1);
        a[0] = ASSET_ID;
        p[0] = 100;
        _fillLeafPI(tpi, a, p);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        _mockSnark(false);
        vm.expectRevert(MASP.TreeUpdateRejected.selector);
        masp.flushBatch(ids, _meta(1), _emptyProof(), tpi);
    }

    function test_revert_replay_secondFlushReverts() public {
        _fund(token, 100);
        bytes32 cm0 = bytes32(uint256(0x111));
        uint256 id = _submit(100, ASSET_ID, cm0, 0);

        bytes32[] memory cms = new bytes32[](1);
        cms[0] = cm0;
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        uint64[] memory a = new uint64[](1);
        uint64[] memory p = new uint64[](1);
        a[0] = ASSET_ID;
        p[0] = 100;
        _fillLeafPI(tpi, a, p);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        _mockSnark(true);
        masp.flushBatch(ids, _meta(1), _emptyProof(), tpi);

        // Replay with a refreshed tpi (root + startIndex aligned to post-flush
        // state) reaches the sentinel; without the refresh StaleOldRoot fires
        // first.
        PubInputs.TreeUpdateBatch memory tpi2 = _tpi(1, cms);
        _fillLeafPI(tpi2, a, p);
        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, id));
        masp.flushBatch(ids, _meta(1), _emptyProof(), tpi2);
    }
}
