// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import { FixtureLoader } from "./utils/FixtureLoader.sol";

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
    TreeUpdateBatchGroth16Verifier tubVerifier;
    BatchedGroth16Verifier batchVerifier;
    address permit2;
    MockERC20 token;
    MockERC20 tokenAlt;
    MASP masp;

    address payer = address(0xface);
    address recipient = address(0xb0b);

    function setUp() public {
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        batchVerifier = new BatchedGroth16Verifier();
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
            IVerifier(address(tubVerifier)),
            IBatchVerifier(address(batchVerifier)),
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

    function _aux() internal pure returns (AuxValidation.Output[4] memory aux) {
        return SpendFixture.validAux();
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
        d.feeCm = bytes32(uint256(0xfee));
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
        return masp.deposit(d, sig, _aux()[0], _aux()[1]);
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

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return FixtureLoader.emptyProof();
    }

    function _mockSnark(bool ok) internal {
        // Force the batch verifier to return `ok` for any input.
        vm.mockCall(address(tubVerifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(ok));
    }

    /// Build the batch public inputs for `n` deposits.
    ///
    /// Each deposit owns two adjacent leaves — its principal at `2i` and the
    /// relayer's fee note at `2i + 1` — so `actualCount` is `2n` and the
    /// deposit's own commitments land on the even slots.
    /// The `feeCm` `_request` seeds on every deposit here.
    bytes32 internal constant FEE_CM = bytes32(uint256(0xfee));

    function _tpi(uint256 n, bytes32[] memory cms) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xfeedbeef));
        tpi.startIndex = masp.committedCount();
        // forge-lint: disable-next-line(unsafe-typecast)
        tpi.actualCount = uint64(n * PubInputs.LEAVES_PER_DEPOSIT);
        // Clamp to `bytes32[MAX_L_BATCH]` capacity; oversize cms arrays
        // (used by oversize-batch revert tests) must not OOB tpi.cms.
        uint256 cap = PubInputs.MAX_L_BATCH;
        for (uint256 i = 0; i < cms.length; i++) {
            uint256 slot = i * PubInputs.LEAVES_PER_DEPOSIT;
            if (slot + 1 >= cap) break;
            tpi.cms[slot] = cms[i];
            tpi.cms[slot + 1] = FEE_CM;
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
            uint256 slot = i * PubInputs.LEAVES_PER_DEPOSIT;
            if (slot + 1 >= PubInputs.MAX_L_BATCH) break;
            tpi.leafAsset[slot] = assetIds[i];
            tpi.leafPublicIn[slot] = publicIns[i];
            tpi.isDeposit[slot] = 1;
            // The fee note rides in the deposit's own asset, at the value the
            // builder escrowed (zero here — these tests do not price a fee).
            tpi.leafAsset[slot + 1] = assetIds[i];
            tpi.leafPublicIn[slot + 1] = 0;
            tpi.isDeposit[slot + 1] = 1;
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
        assertEq(masp.committedCount(), 2, "count += 2 (principal + relayer fee note)");

        // Slot cleared (sentinel check)
        assertEq(masp.escrowed(id), bytes32(0), "slot cleared");

        // Fee accrued at flush (submit accrues nothing).
        uint256 expectedFee = (uint256(100) * SCALE * FEE_BPS) / 10_000;
        assertEq(masp.accruedFee(IERC20(address(token))), expectedFee, "fee accrued at flush");
    }

    function test_happy_N2_singleAsset() public {
        _fund(token, 100);
        _fund(token, 100);

        uint256 id0 = _submit(100, ASSET_ID, bytes32(uint256(1)), 0);
        uint256 id1 = _submit(100, ASSET_ID, bytes32(uint256(3)), 1);

        // Two deposits fill the batch: each owns a principal leaf and the
        // relayer's fee leaf, so `MAX_L_BATCH = 4` is exactly consumed.
        bytes32[] memory cms = new bytes32[](2);
        cms[0] = bytes32(uint256(1));
        cms[1] = bytes32(uint256(3));
        PubInputs.TreeUpdateBatch memory tpi = _tpi(2, cms);
        uint64[] memory a = new uint64[](2);
        uint64[] memory p = new uint64[](2);
        a[0] = ASSET_ID;
        a[1] = ASSET_ID;
        p[0] = 100;
        p[1] = 100;
        _fillLeafPI(tpi, a, p);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id0;
        ids[1] = id1;

        _mockSnark(true);
        masp.flushBatch(ids, _meta(2), _emptyProof(), tpi);

        assertEq(masp.committedCount(), 4, "count += 4 (two leaves per deposit)");
        uint256 feePer = (uint256(100) * SCALE * FEE_BPS) / 10_000;
        // Only the treasury's cut accrues; the relayer's stays pool principal
        // backing its note.
        assertEq(masp.accruedFee(IERC20(address(token))), 2 * feePer, "both treasury fees accrued");
    }

    /// The batch ceiling is now three deposits, not five: two leaves each
    /// against `MAX_L_BATCH = 4`.
    function test_revert_BadBatchSize_threeDeposits() public {
        _fund(token, 100);
        _fund(token, 100);
        _fund(token, 100);

        uint256 id0 = _submit(100, ASSET_ID, bytes32(uint256(1)), 0);
        uint256 id1 = _submit(100, ASSET_ID, bytes32(uint256(3)), 1);
        uint256 id2 = _submit(100, ASSET_ID, bytes32(uint256(5)), 2);

        bytes32[] memory cms = new bytes32[](3);
        cms[0] = bytes32(uint256(1));
        cms[1] = bytes32(uint256(3));
        cms[2] = bytes32(uint256(5));
        PubInputs.TreeUpdateBatch memory tpi = _tpi(3, cms);

        uint256[] memory ids = new uint256[](3);
        ids[0] = id0;
        ids[1] = id1;
        ids[2] = id2;

        _mockSnark(true);
        vm.expectRevert(MASP.BadBatchSize.selector);
        masp.flushBatch(ids, _meta(3), _emptyProof(), tpi);
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
        assertEq(masp.committedCount(), 4, "count += 4 (two leaves per deposit)");
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

    // --- relayer fee leaf ---------------------------------------------------
    //
    // Every test above prices the relayer's note at zero, which leaves the odd
    // leaf's guards unexercised: a tampered zero still reconstructs the same
    // digest as an untampered zero for any field the attacker sets back to
    // zero. The tests below escrow a *priced* fee note and then mutate exactly
    // one fee-leaf field of an otherwise-valid batch, so each guard is the only
    // thing standing between the flusher and a note it did not fund.

    uint64 internal constant FEE_PUBLIC_IN = 100;
    uint64 internal constant FEE_IN = 7;
    bytes32 internal constant FEE_DEPOSIT_CM = bytes32(uint256(0x111));
    uint256 internal constant FEE_CVDEP_X = 0xfeed01;
    uint256 internal constant FEE_CVDEP_Y = 0xfeed02;

    /// Escrow one deposit carrying a priced relayer note, and build the batch
    /// that flushes it. The returned `tpi` is valid: each test below mutates a
    /// single fee-leaf field of it, so a passing test pins that field's guard
    /// and nothing else.
    function _pricedDeposit() internal returns (uint256 id, PubInputs.TreeUpdateBatch memory tpi) {
        uint256 inAmt = uint256(FEE_PUBLIC_IN) * SCALE;
        // The payer funds the relayer's leg on top of principal and treasury
        // fee, so mint past what `_fund` covers.
        token.mint(payer, inAmt + (inAmt * FEE_BPS) / 10_000 + uint256(FEE_IN) * SCALE);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);

        PubInputs.DepositRequest memory d = _request(FEE_PUBLIC_IN, ASSET_ID, FEE_DEPOSIT_CM);
        d.feeIn = FEE_IN;
        d.feeCvDep = [FEE_CVDEP_X, FEE_CVDEP_Y];
        d.feeRcv = 0xf00d;
        MASP.Permit2Sig memory sig =
            MASP.Permit2Sig({ nonce: 0, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00" });
        id = masp.deposit(d, sig, _aux()[0], _aux()[1]);

        tpi = _feeTpi();
        _mockSnark(true);
    }

    /// The batch matching `_pricedDeposit`. Rebuilt rather than copied when a
    /// test needs a second untampered one: a memory struct is a reference.
    function _feeTpi() internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        bytes32[] memory cms = new bytes32[](1);
        cms[0] = FEE_DEPOSIT_CM;
        tpi = _tpi(1, cms); // seeds cms[1] = FEE_CM
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafPublicIn[0] = FEE_PUBLIC_IN;
        tpi.isDeposit[0] = 1;
        tpi.leafAsset[1] = ASSET_ID;
        tpi.leafPublicIn[1] = FEE_IN;
        tpi.isDeposit[1] = 1;
        tpi.cvDeps[1] = [FEE_CVDEP_X, FEE_CVDEP_Y];
    }

    function _flush(uint256 id, PubInputs.TreeUpdateBatch memory tpi) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        masp.flushBatch(ids, _meta(1), _emptyProof(), tpi);
    }

    function _expectFlushRevert(uint256 id, PubInputs.TreeUpdateBatch memory tpi, bytes memory err) internal {
        vm.expectRevert(err);
        _flush(id, tpi);
    }

    /// The relayer's cut is charged to the payer at submit and never accrues:
    /// it stays pool principal, because the note minted against it is only
    /// spendable while the pool still holds the tokens behind it.
    function test_happy_relayerFeeNoteStaysPoolPrincipal() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();

        uint256 inAmt = uint256(FEE_PUBLIC_IN) * SCALE;
        uint256 treasuryFee = (inAmt * FEE_BPS) / 10_000;
        uint256 escrowed = inAmt + treasuryFee + uint256(FEE_IN) * SCALE;
        assertEq(token.balanceOf(address(masp)), escrowed, "payer funded the relayer's leg too");

        _flush(id, tpi);

        assertEq(masp.committedCount(), 2, "principal leaf + relayer fee leaf");
        assertEq(masp.accruedFee(IERC20(address(token))), treasuryFee, "relayer amount is not treasury revenue");
        assertEq(token.balanceOf(address(masp)), escrowed, "flush moves no tokens");
    }

    /// The fee leaf must be in deposit mode. Only the principal leaf's mode was
    /// covered before, so a spend-mode fee slot reached the digest check.
    function test_revert_BadDepositMode_feeLeafMarkedSpend() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.isDeposit[1] = 0;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.BadDepositMode.selector));
    }

    /// The fee leaf's value is narrowed to `uint48` for the digest, so it needs
    /// the same range check the principal leaf gets — otherwise the truncation
    /// lets a wide `leafPublicIn` reconstruct a digest it does not match.
    function test_revert_PublicInTooLarge_feeLeaf() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.leafPublicIn[1] = uint64(uint256(type(uint48).max) + 1);
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.PublicInTooLarge.selector));
    }

    /// The fee note rides in the deposit's own asset. One registry lookup
    /// serves both leaves, so a fee leaf naming a different asset would
    /// otherwise be priced against the principal's scale.
    function test_revert_DigestMismatch_feeLeafAssetDiffers() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.leafAsset[1] = ASSET_ID_ALT;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
    }

    /// The attack the fee leaf's digest binding exists to stop: `flushBatch` is
    /// permissionless and supplies both leaves from calldata, so a flusher that
    /// could swap `cms[f]` would mint the payer-funded note to itself.
    function test_revert_DigestMismatch_feeCmTampered() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.cms[1] = bytes32(uint256(0xbad)); // flusher's own commitment
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
    }

    /// Same binding, other direction: inflating the fee leaf's value mints a
    /// note worth more than the payer funded, draining pool principal.
    function test_revert_DigestMismatch_feeInInflated() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.leafPublicIn[1] = FEE_IN + 1;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
    }

    /// `feeCvDep` is what pins (asset, value) into the fee leaf in-circuit, so
    /// it is bound at submit like the principal's `cvDep`. Both coordinates are
    /// probed: a digest built over only the first would pass the second case.
    function test_revert_DigestMismatch_feeCvDepTampered() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.cvDeps[1][0] = FEE_CVDEP_X + 1;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.DigestMismatch.selector, id));

        tpi = _feeTpi();
        tpi.cvDeps[1][1] = FEE_CVDEP_Y + 1;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
    }
}
