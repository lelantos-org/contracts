// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { SnarkCompression } from "../../src/SnarkCompression.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { deployPoolUniform, realVerifierStack, twoAssets } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";
import { FeeMath } from "../utils/FeeMath.sol";

/// `flushBatch` contract-level coverage. SNARK verification is mocked via
/// `vm.mockCall`, isolating the storage/event/sentinel logic from circuit-side
/// correctness, which is covered separately with real fixtures.
contract MASPFlushBatchTest is Test {
    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;
    uint64 internal constant ASSET_ID_ALT = 2;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant TREASURY = TestConstants.TREASURY;
    address internal constant OWNER = TestConstants.OWNER;
    IVerifier tubVerifier;
    IBatchVerifier batchVerifier;
    address permit2;
    MockERC20 token;
    MockERC20 tokenAlt;
    MASP masp;

    address payer = TestConstants.ESCROW_PAYER;
    address recipient = address(0xb0b);

    function setUp() public {
        ISignatureTransfer p2;
        (tubVerifier, batchVerifier, p2) = realVerifierStack();
        permit2 = address(p2);
        token = new MockERC20("M", "M", 18);
        tokenAlt = new MockERC20("A", "A", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            twoAssets(IERC20(address(token)), ASSET_ID, IERC20(address(tokenAlt)), ASSET_ID_ALT, SCALE);

        masp = deployPoolUniform(tubVerifier, batchVerifier, p2, ids, tokens, scales, FEE_BPS, TREASURY, OWNER);

        Stubs.installPermissiveERC1271(payer);
    }

    // --- helpers -----------------------------------------------------------

    /// `inner` is the note's owner half, which is what a deposit escrows and
    /// what a flush puts in the deposit's `cms` slot. The values here are
    /// arbitrary words: the tree-update proof is mocked, so nothing opens one.
    function _request(uint64 publicIn, uint64 assetId, bytes32 inner)
        internal
        view
        returns (PubInputs.DepositRequest memory d)
    {
        return DepositFixture.request(assetId, publicIn, payer, recipient, inner);
    }

    function _fund(MockERC20 t, uint64 publicIn) internal {
        t.mint(payer, FeeMath.gross(publicIn, SCALE, FEE_BPS));
        vm.prank(payer);
        t.approve(address(permit2), type(uint256).max);
    }

    function _submit(uint64 publicIn, uint64 assetId, bytes32 inner, uint256 nonce) internal returns (uint256 id) {
        PubInputs.DepositRequest memory d = _request(publicIn, assetId, inner);
        return masp.deposit(d, DepositFixture.sig(nonce), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
    }

    /// Digest meta for deposits submitted in the current block by `payer` at
    /// the deploy-time fee, matching every `_submit` in this suite.
    function _meta(uint256 n) internal view returns (MASP.DepositMeta[] memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return DepositFixture.metas(n, payer, uint32(block.number), FEE_BPS);
    }

    function _mockSnark(bool ok) internal {
        Stubs.acceptTreeUpdateProofs(tubVerifier, ok);
    }

    /// The `feeInner` `_request` seeds on every deposit here.
    bytes32 internal constant FEE_INNER = DepositFixture.FEE_INNER;

    /// Builds the batch public inputs for `n` deposits.
    ///
    /// Each deposit owns two adjacent leaves (its principal at `2i` and the
    /// relayer's fee note at `2i + 1`), so `actualCount` is `2n` and the
    /// deposits' own `inner` words, passed in `cms`, land on the even slots.
    function _tpi(uint256 n, bytes32[] memory cms) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xfeedbeef));
        tpi.startIndex = masp.committedCount();
        // forge-lint: disable-next-line(unsafe-typecast)
        tpi.actualCount = uint64(n * PubInputs.LEAVES_PER_DEPOSIT);
        // Clamps to `bytes32[MAX_L_BATCH]` capacity so oversize cms arrays
        // (used by the oversize-batch revert tests) do not index past tpi.cms.
        uint256 cap = PubInputs.MAX_L_BATCH;
        for (uint256 i = 0; i < cms.length; i++) {
            uint256 slot = i * PubInputs.LEAVES_PER_DEPOSIT;
            if (slot + 1 >= cap) break;
            tpi.cms[slot] = cms[i];
            tpi.cms[slot + 1] = FEE_INNER;
        }
    }

    /// Fills the per-active-slot PIs that `flushBatch` cross-checks against
    /// the escrow record: with the slot's `cms` word they are the three inputs
    /// the circuit hashes into a deposit leaf, and the three the escrow digest
    /// holds for it.
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
            // The fee note carries the value the builder escrowed, zero here
            // (these tests do not price a fee), so its asset slot is zero.
            tpi.leafAsset[slot + 1] = 0;
            tpi.leafPublicIn[slot + 1] = 0;
            tpi.isDeposit[slot + 1] = 1;
        }
    }

    // --- happy paths -------------------------------------------------------

    function test_happy_N1_advancesRootAndClearsSlot() public {
        _fund(token, 100);
        bytes32 inner0 = bytes32(uint256(0x111));
        uint256 id = _submit(100, ASSET_ID, inner0, 0);

        bytes32[] memory cms = new bytes32[](1);
        cms[0] = inner0;
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        uint64[] memory a = new uint64[](1);
        uint64[] memory p = new uint64[](1);
        a[0] = ASSET_ID;
        p[0] = 100;
        _fillLeafPI(tpi, a, p);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        _mockSnark(true);
        masp.flushBatch(ids, _meta(1), FixtureLoader.emptyProof(), tpi);

        assertEq(masp.currentRoot(), tpi.newRoot, "root advanced");
        assertEq(masp.committedCount(), 2, "count += 2 (principal + relayer fee note)");

        assertEq(masp.escrowed(id), bytes32(0), "slot cleared");

        // The fee accrues at flush; submit accrues nothing.
        uint256 expectedFee = (uint256(100) * SCALE * FEE_BPS) / 10_000;
        assertEq(masp.accruedFee(IERC20(address(token))), expectedFee, "fee accrued at flush");
    }

    function test_happy_N2_singleAsset() public {
        _fund(token, 100);
        _fund(token, 100);

        uint256 id0 = _submit(100, ASSET_ID, bytes32(uint256(1)), 0);
        uint256 id1 = _submit(100, ASSET_ID, bytes32(uint256(3)), 1);

        // Two deposits, each owning a principal leaf and the relayer's fee
        // leaf, occupy four of the `MAX_L_BATCH = 8` slots.
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
        masp.flushBatch(ids, _meta(2), FixtureLoader.emptyProof(), tpi);

        assertEq(masp.committedCount(), 4, "count += 4 (two leaves per deposit)");
        uint256 feePer = (uint256(100) * SCALE * FEE_BPS) / 10_000;
        // Only the treasury's cut accrues; the relayer's stays pool principal
        // backing its note.
        assertEq(masp.accruedFee(IERC20(address(token))), 2 * feePer, "both treasury fees accrued");
    }

    /// The batch ceiling is four deposits: two leaves each against
    /// `MAX_L_BATCH = 8`. A fifth overshoots it.
    function test_revert_BadBatchSize_fiveDeposits() public {
        uint256 n = PubInputs.MAX_L_BATCH / PubInputs.LEAVES_PER_DEPOSIT + 1;

        bytes32[] memory cms = new bytes32[](n);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            _fund(token, 100);
            bytes32 inner = bytes32(2 * i + 1);
            ids[i] = _submit(100, ASSET_ID, inner, i);
            cms[i] = inner;
        }
        PubInputs.TreeUpdateBatch memory tpi = _tpi(n, cms);

        _mockSnark(true);
        vm.expectRevert(MASP.BadBatchSize.selector);
        masp.flushBatch(ids, _meta(n), FixtureLoader.emptyProof(), tpi);
    }

    // --- reverts -----------------------------------------------------------

    function test_revert_BadBatchSize_zero() public {
        bytes32[] memory cms = new bytes32[](0);
        PubInputs.TreeUpdateBatch memory tpi = _tpi(0, cms);
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(MASP.BadBatchSize.selector);
        masp.flushBatch(ids, _meta(0), FixtureLoader.emptyProof(), tpi);
    }

    function test_revert_BadBatchSize_overMax() public {
        uint256 n = PubInputs.MAX_L_BATCH + 1;
        uint256[] memory ids = new uint256[](n);
        bytes32[] memory cms = new bytes32[](n);
        // forge-lint: disable-next-line(unsafe-typecast)
        PubInputs.TreeUpdateBatch memory tpi = _tpi(n, cms);
        vm.expectRevert(MASP.BadBatchSize.selector);
        masp.flushBatch(ids, _meta(n), FixtureLoader.emptyProof(), tpi);
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
        masp.flushBatch(ids, _meta(2), FixtureLoader.emptyProof(), tpi);
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
        masp.flushBatch(ids, _meta(1), FixtureLoader.emptyProof(), tpi);
    }

    function test_revert_StaleOldRoot() public {
        bytes32[] memory cms = new bytes32[](2);
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        tpi.oldRoot = bytes32(uint256(0xbad));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.expectRevert(MASP.StaleOldRoot.selector);
        masp.flushBatch(ids, _meta(1), FixtureLoader.emptyProof(), tpi);
    }

    function test_revert_DepositNotPending_unknownId() public {
        bytes32[] memory cms = new bytes32[](2);
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;
        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, 999));
        masp.flushBatch(ids, _meta(1), FixtureLoader.emptyProof(), tpi);
    }

    /// The principal's `cms` word is the escrowed `inner`: a flusher cannot
    /// insert a different note for the deposit.
    function test_revert_DigestMismatch_innerTampered() public {
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
        masp.flushBatch(ids, _meta(1), FixtureLoader.emptyProof(), tpi);
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

        MASP.DepositMeta[] memory m = _meta(1);
        m[0].fbps = FEE_BPS + 1;
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.flushBatch(ids, m, FixtureLoader.emptyProof(), tpi);

        m = _meta(1);
        m[0].payer = address(0xbad);
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.flushBatch(ids, m, FixtureLoader.emptyProof(), tpi);

        m = _meta(1);
        m[0].submittedAt += 1;
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.flushBatch(ids, m, FixtureLoader.emptyProof(), tpi);

        // A refund cap in meta, where the plain escrow was submitted with none.
        m = _meta(1);
        m[0].pulled = 1;
        vm.expectRevert(abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
        masp.flushBatch(ids, m, FixtureLoader.emptyProof(), tpi);
    }

    function test_happy_mixedAssetBatch() public {
        // Two deposits of different assets in one flush: each token's fee
        // accrues independently.
        _fund(token, 100);
        _fund(tokenAlt, 100);
        uint256 id0 = _submit(100, ASSET_ID, bytes32(uint256(1)), 0);
        uint256 id1 = _submit(100, ASSET_ID_ALT, bytes32(uint256(3)), 1);

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
        masp.flushBatch(ids, _meta(2), FixtureLoader.emptyProof(), tpi);

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
        masp.flushBatch(ids, _meta(1), FixtureLoader.emptyProof(), tpi);
    }

    function test_revert_replay_secondFlushReverts() public {
        _fund(token, 100);
        bytes32 inner0 = bytes32(uint256(0x111));
        uint256 id = _submit(100, ASSET_ID, inner0, 0);

        bytes32[] memory cms = new bytes32[](1);
        cms[0] = inner0;
        PubInputs.TreeUpdateBatch memory tpi = _tpi(1, cms);
        uint64[] memory a = new uint64[](1);
        uint64[] memory p = new uint64[](1);
        a[0] = ASSET_ID;
        p[0] = 100;
        _fillLeafPI(tpi, a, p);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        _mockSnark(true);
        masp.flushBatch(ids, _meta(1), FixtureLoader.emptyProof(), tpi);

        // A replay with a refreshed tpi (root and startIndex aligned to the
        // post-flush state) reaches the sentinel; without the refresh
        // StaleOldRoot fires first.
        PubInputs.TreeUpdateBatch memory tpi2 = _tpi(1, cms);
        _fillLeafPI(tpi2, a, p);
        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, id));
        masp.flushBatch(ids, _meta(1), FixtureLoader.emptyProof(), tpi2);
    }

    // --- relayer fee leaf ---------------------------------------------------
    //
    // The tests above price the relayer's note at zero, which leaves the odd
    // leaf's guards unexercised: a zero-valued field reconstructs the same
    // digest whether or not it was tampered with. The tests below escrow a
    // priced fee note and mutate exactly one fee-leaf field of an otherwise
    // valid batch, so each test isolates the guard that prevents a flusher
    // from minting a note it did not fund.

    uint64 internal constant FEE_PUBLIC_IN = 100;
    uint64 internal constant FEE_IN = 7;
    bytes32 internal constant FEE_DEPOSIT_INNER = bytes32(uint256(0x111));

    /// Escrows one deposit carrying a priced relayer note and builds the batch
    /// that flushes it. The returned `tpi` is valid; each test below mutates a
    /// single field of it, so a passing test pins that field's guard alone.
    function _pricedDeposit() internal returns (uint256 id, PubInputs.TreeUpdateBatch memory tpi) {
        uint256 inAmt = uint256(FEE_PUBLIC_IN) * SCALE;
        // The payer funds the relayer's leg on top of principal and treasury
        // fee, so mint past what `_fund` covers.
        token.mint(payer, inAmt + (inAmt * FEE_BPS) / 10_000 + uint256(FEE_IN) * SCALE);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);

        PubInputs.DepositRequest memory d = _request(FEE_PUBLIC_IN, ASSET_ID, FEE_DEPOSIT_INNER);
        d.feeIn = FEE_IN;
        d.feeAssetId = ASSET_ID;
        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: 0, deadline: type(uint256).max, maxTotal: type(uint256).max, maxFee: 0, signature: hex"00"
        });
        id = masp.deposit(d, sig, SpendFixture.validAux()[0], SpendFixture.validAux()[1]);

        tpi = _feeTpi();
        _mockSnark(true);
    }

    /// The batch matching `_pricedDeposit`. Rebuilt rather than copied when a
    /// test needs a second untampered one: a memory struct is a reference.
    function _feeTpi() internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        bytes32[] memory cms = new bytes32[](1);
        cms[0] = FEE_DEPOSIT_INNER;
        tpi = _tpi(1, cms); // seeds cms[1] = FEE_INNER
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafPublicIn[0] = FEE_PUBLIC_IN;
        tpi.isDeposit[0] = 1;
        tpi.leafAsset[1] = ASSET_ID;
        tpi.leafPublicIn[1] = FEE_IN;
        tpi.isDeposit[1] = 1;
    }

    function _flush(uint256 id, PubInputs.TreeUpdateBatch memory tpi) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        masp.flushBatch(ids, _meta(1), FixtureLoader.emptyProof(), tpi);
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

    /// The fee leaf must be in deposit mode; a spend-mode fee slot reverts with
    /// `BadDepositMode`, as the principal leaf does. In spend mode the circuit
    /// would insert `feeInner` as the leaf itself instead of hashing the
    /// escrowed asset and amount into it.
    function test_revert_BadDepositMode_feeLeafMarkedSpend() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.isDeposit[1] = 0;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.BadDepositMode.selector));
    }

    /// The fee leaf's value is narrowed to `uint48` for the digest, so it gets
    /// the same range check as the principal leaf; otherwise truncation would
    /// let a wide `leafPublicIn` reconstruct a digest it does not match.
    function test_revert_PublicInTooLarge_feeLeaf() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.leafPublicIn[1] = uint64(uint256(type(uint48).max) + 1);
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.PublicInTooLarge.selector));
    }

    /// The fee leaf's asset is bound by the digest's `feeAssetId`, here the
    /// deposit's own asset. A flusher naming another registered asset would
    /// otherwise mint the relayer a note in a token the payer never funded.
    function test_revert_DigestMismatch_feeLeafAssetDiffers() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.leafAsset[1] = ASSET_ID_ALT;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
    }

    /// `flushBatch` is permissionless and takes both leaves from calldata, so
    /// without the fee leaf's digest binding a flusher could swap the fee
    /// slot's `cms` word and mint the payer-funded note to itself.
    function test_revert_DigestMismatch_feeInnerTampered() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.cms[1] = bytes32(uint256(0xbad)); // flusher's own `inner`
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
    }

    /// The same binding covers value: inflating the fee leaf's value would mint
    /// a note worth more than the payer funded, draining pool principal.
    function test_revert_DigestMismatch_feeInInflated() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.leafPublicIn[1] = FEE_IN + 1;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
    }

    // --- principal leaf ------------------------------------------------------
    //
    // The circuit builds a deposit leaf as
    // `Poseidon(TAG_CM, leafAsset * 2^64 + leafPublicIn, cms)`, taking all three
    // from the batch. Nothing else ties a deposit's note to what was escrowed
    // for it, so each of the three is bound by the escrow digest: `cms` in
    // `test_revert_DigestMismatch_innerTampered` above, the other two here.

    /// Inflating the principal's amount would insert a note worth more than
    /// the payer escrowed.
    function test_revert_DigestMismatch_principalValueInflated() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.leafPublicIn[0] = FEE_PUBLIC_IN + 1;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
    }

    /// Naming another registered asset for the principal would insert a note
    /// in a token the payer never escrowed.
    function test_revert_DigestMismatch_principalAssetDiffers() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.leafAsset[0] = ASSET_ID_ALT;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
    }

    /// The two leaves of a deposit are bound to their own slots: swapping the
    /// principal's `inner` with the fee note's reconstructs a different digest,
    /// so neither party can take the other's note.
    function test_revert_DigestMismatch_innersSwapped() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        (tpi.cms[0], tpi.cms[1]) = (tpi.cms[1], tpi.cms[0]);
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.DigestMismatch.selector, id));
    }

    /// The principal leaf must be in deposit mode. With the flag clear the
    /// circuit inserts `cms` as the leaf it is, so a depositor who escrowed a
    /// commitment of its choosing in place of `inner` would hold a note of any
    /// value for one unit paid. The untampered batch then flushes, so the
    /// guard, not the fixture, rejected it.
    function test_revert_BadDepositMode_principalLeafMarkedSpend() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.isDeposit[0] = 0;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.BadDepositMode.selector));

        _flush(id, _feeTpi());
        assertEq(masp.escrowed(id), bytes32(0), "the valid batch flushes");
    }

    // --- the batch digest word -----------------------------------------------

    /// `flushBatch` hands the tree-update verifier `PubInputs.compress(tpi)`:
    /// `[y, digest, z]`, with the batch's digest word second and exactly as
    /// calldata carried it. The pool never recomputes that commitment, so
    /// forwarding it is what lets the proof check it.
    function test_flush_forwardsBatchDigestToVerifier() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.digest = 0xd16e57;
        uint256[3] memory pub = this.compressBatch(tpi);
        assertEq(pub[1], tpi.digest, "digest is the second signal, as given");

        MASP.Proof memory proof = FixtureLoader.emptyProof();
        vm.expectCall(address(tubVerifier), abi.encodeCall(IVerifier.verifyProof, (proof.a, proof.b, proof.c, pub)));
        _flush(id, tpi);
    }

    /// The digest word is hashed into the challenge: the same batch under
    /// another digest reaches the verifier with a different `z`. A verifier
    /// that accepts only the first image therefore rejects the second, and the
    /// flush reverts.
    function test_revert_TreeUpdateRejected_batchDigestChanged() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        tpi.digest = 0xd16e57;
        uint256[3] memory pub = this.compressBatch(tpi);

        // Accept exactly `pub`, reject everything else.
        vm.clearMockedCalls();
        MASP.Proof memory proof = FixtureLoader.emptyProof();
        _mockSnark(false);
        vm.mockCall(
            address(tubVerifier),
            abi.encodeCall(IVerifier.verifyProof, (proof.a, proof.b, proof.c, pub)),
            abi.encode(true)
        );

        PubInputs.TreeUpdateBatch memory other = _feeTpi();
        other.digest = tpi.digest + 1;
        uint256[3] memory otherPub = this.compressBatch(other);
        assertEq(otherPub[1], other.digest, "digest forwarded");
        assertTrue(otherPub[2] != pub[2], "digest moves z");
        _expectFlushRevert(id, other, abi.encodeWithSelector(MASP.TreeUpdateRejected.selector));

        _flush(id, tpi);
        assertEq(masp.escrowed(id), bytes32(0), "the proven image flushes");
    }

    /// A digest word outside the scalar field does not revert in the pool's
    /// own compression: it is hashed without being evaluated, unlike a
    /// coefficient, so it reaches the verifier unreduced and is refused there
    /// (`test/verifiers/` pins that the real verifiers reject a signal
    /// `>= R`). The same word as a coefficient never gets that far.
    function test_revert_TreeUpdateRejected_batchDigestOutOfField() public {
        (uint256 id, PubInputs.TreeUpdateBatch memory tpi) = _pricedDeposit();
        // The real verifier, not the accepting mock.
        vm.clearMockedCalls();
        tpi.digest = type(uint256).max;
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(MASP.TreeUpdateRejected.selector));

        tpi = _feeTpi();
        tpi.newRoot = bytes32(type(uint256).max);
        _expectFlushRevert(id, tpi, abi.encodeWithSelector(SnarkCompression.CoefficientOutOfField.selector));
    }

    /// External so the batch arrives as calldata, which is what the pool
    /// compresses.
    function compressBatch(PubInputs.TreeUpdateBatch calldata tpi) external pure returns (uint256[3] memory) {
        return PubInputs.compress(tpi);
    }
}
