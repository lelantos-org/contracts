// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { SnarkCompression } from "../../src/SnarkCompression.sol";

import { CompressHarness, Y, DIGEST, Z } from "../utils/CompressHarness.sol";

/// Smoke and property tests for `PubInputs.compress`, which returns the
/// verifier's public signals `[y, digest, z]`. Cross-checks the
/// `TreeUpdateBatch` flatten order against a manual PolyEval to fix the
/// on-chain to circuit coefficient layout, pins the calldata fast path to the
/// memory reference path, and pins how the digest word is treated: hashed into
/// `z`, returned as given, never evaluated into `y`.
contract PubInputsTest is Test {
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// Word positions in the `Transact` calldata block, restated here as
    /// numbers: the struct's `W_*` constants are private, and a test deriving
    /// them the same way would reproduce a mistake in them.
    uint256 internal constant T_PUBLIC_ASSET_ID = 11;
    uint256 internal constant T_PUBLIC_OUT = 12;
    uint256 internal constant T_DIGEST = 13;
    uint256 internal constant T_RECIPIENT = 14;
    uint256 internal constant T_CHAIN_ID = 15;
    uint256 internal constant T_PAYER = 16;
    uint256 internal constant T_RELAYER = 17;
    uint256 internal constant T_INTENT_HASH = 18;

    /// The batch's coefficient count, and so the position of its digest word.
    uint256 internal constant B_COEFFS = 36;

    CompressHarness internal h;

    function setUp() public {
        h = new CompressHarness();
    }

    // --- fast path ≡ reference path ----------------------------------------

    /// Pins the coefficient and preimage counts as numbers.
    ///
    /// Every derived offset in `PubInputs` follows the shape constants, so a
    /// change to `TRANSACT_OUT` or `MAX_L_BATCH` moves both vectors without a
    /// compile error, and the circuit-side PolyEval they must match lives in
    /// another repository. A count that disagrees with the shape fails here.
    ///
    /// `4x6` hashes 38 words and evaluates 13; the batch hashes 37 and
    /// evaluates 36, or 10 on the spend path, which skips the zero padding. The
    /// transact length is odd, so the odd-length prologue of
    /// `SnarkCompression.evaluatePolyAtRaw` runs on every spend.
    function test_coefficientCountsMatchTheDeployedShape() public pure {
        assertEq(PubInputs.TRANSACT_IN, 4, "transact inputs");
        assertEq(PubInputs.TRANSACT_OUT, 6, "transact outputs");
        assertEq(PubInputs.MAX_L_BATCH, 8, "batch width");

        // 19 struct words, then (clueRx, clueRy, clueBits) per output, then the
        // aux digest.
        assertEq(PubInputs.TRANSACT_CHALLENGE_WORDS, 38, "4x6 challenge preimage");
        // merkleRoot, the nullifiers, the output commitments, publicAssetId and
        // publicOut.
        assertEq(PubInputs.TRANSACT_COEFFS, 13, "4x6 coefficient vector");
        assertEq(PubInputs.TRANSACT_COEFFS, T_DIGEST, "the digest word follows the coefficients");
        // The 25-word gap is the digest word, the five struct words the
        // circuit has no signal for, the six clue triples and the aux digest:
        // hashed into `z` and not evaluated. The digest commits to the
        // coefficients, so it cannot be one of them; the rest have no witness
        // copy to disagree with calldata, so the hash alone binds them.
        assertEq(PubInputs.TRANSACT_CHALLENGE_WORDS - PubInputs.TRANSACT_COEFFS, 25, "words hashed but not evaluated");

        // oldRoot, newRoot, startIndex, actualCount, then four per-leaf arrays
        // (cms, leafAsset, leafPublicIn, isDeposit). The preimage is those plus
        // the digest word.
        assertEq(4 + 4 * PubInputs.MAX_L_BATCH, B_COEFFS, "tree_update_batch coefficient vector");
    }

    function test_batch_fastPathMatchesReference() public view {
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(3);
        _assertSame(h.batch(tpi), h.batchRef(tpi));
    }

    function testFuzz_batch_fastPathMatchesReference(
        bytes32 ro,
        bytes32 rn,
        uint64 si,
        uint64 ac,
        uint256 cmSeed,
        uint256 digest,
        uint64 asset0,
        uint64 in0,
        uint8 dep0
    ) public view {
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = bytes32(uint256(ro) % R);
        tpi.newRoot = bytes32(uint256(rn) % R);
        tpi.startIndex = si;
        tpi.actualCount = uint64(bound(ac, 1, uint64(PubInputs.MAX_L_BATCH)));
        for (uint256 i = 0; i < PubInputs.MAX_L_BATCH; i++) {
            tpi.cms[i] = bytes32(uint256(keccak256(abi.encode(cmSeed, i))) % R);
        }
        tpi.leafAsset[0] = asset0;
        tpi.leafPublicIn[0] = in0;
        tpi.isDeposit[0] = dep0;
        // Padding slots are non-zero as well; the SNARK must bind them.
        tpi.leafAsset[PubInputs.MAX_L_BATCH - 1] = asset0;
        tpi.leafPublicIn[PubInputs.MAX_L_BATCH - 1] = in0;
        tpi.isDeposit[PubInputs.MAX_L_BATCH - 1] = dep0;
        // Any word: the digest is hashed and returned, never evaluated, so it
        // is not reduced into the field like the coefficients above.
        tpi.digest = digest;

        uint256[3] memory fast = h.batch(tpi);
        _assertSame(fast, h.batchRef(tpi));
        assertEq(fast[DIGEST], digest, "digest returned as given");
    }

    function testFuzz_transact_fastPathMatchesReference(
        bytes32 root,
        bytes32 nf0,
        bytes32 cm0,
        uint64 assetId,
        uint64 pout,
        uint256 digest,
        address recipient,
        address relayer,
        uint256 seed
    ) public view {
        PubInputs.Transact memory pi = _sampleTransact(seed);
        pi.merkleRoot = bytes32(uint256(root) % R);
        pi.nullifier[0] = bytes32(uint256(nf0) % R);
        pi.outCm[0] = bytes32(uint256(cm0) % R);
        pi.publicAssetId = assetId;
        pi.publicOut = pout;
        pi.digest = digest;
        pi.recipient = recipient;
        pi.relayer = relayer;
        AuxValidation.Output[6] memory aux = _sampleAux(seed);

        uint256[3] memory fast = h.transact(pi, aux);
        _assertSame(fast, h.transactRef(pi, aux));
        assertEq(fast[DIGEST], digest, "digest returned as given");
    }

    // --- intentHash ----------------------------------------------------------

    /// `intentHash` is hashed into `z` as a full word, not masked like the
    /// address words beside it: setting its top bit moves the challenge. Its
    /// position is pinned by the fuzz above and the 4x6 vector.
    function test_transact_intentHashTopBitMovesChallenge() public view {
        PubInputs.Transact memory pi;
        AuxValidation.Output[6] memory aux = _sampleAux(0);
        uint256 base = h.transact(pi, aux)[Z];
        pi.intentHash = 1 << 255;
        assertTrue(h.transact(pi, aux)[Z] != base, "intentHash top bit must move z");
    }

    // --- the digest word: Transact ------------------------------------------
    //
    // The circuit outputs a Poseidon commitment to its own coefficients as its
    // second public signal. `compress` never computes it: it takes the prover's
    // copy from calldata, hashes it into `z` so the commitment is fixed before
    // the challenge exists, and hands it to the verifier to compare. These
    // tests pin the three properties `PubInputs.TRANSACT_COEFFS` lists.

    /// The word reaches the verifier as given: second of the three signals,
    /// neither reduced nor masked, at any width.
    function testFuzz_transact_digestReturnedUnmodified(uint256 seed, uint256 digest) public view {
        PubInputs.Transact memory pi = _sampleTransact(seed);
        pi.digest = digest;
        assertEq(h.transact(pi, _sampleAux(seed))[DIGEST], digest, "digest is signal 1, as given");
    }

    /// The word is in the preimage of `z` and is not a coefficient of `y`.
    ///
    /// `y` is evaluated at `z`, so with any non-zero coefficient it moves
    /// whenever `z` does. What must hold is that the digest contributes no term
    /// of its own: `y` stays the Horner evaluation of the thirteen coefficients
    /// alone, at the new `z`.
    function testFuzz_transact_digestMovesZAndIsNotEvaluated(uint256 seed, uint256 d0, uint256 d1) public view {
        vm.assume(d0 != d1);
        PubInputs.Transact memory pi = _sampleTransact(seed);
        AuxValidation.Output[6] memory aux = _sampleAux(seed);

        pi.digest = d0;
        uint256[3] memory a = h.transact(pi, aux);
        pi.digest = d1;
        uint256[3] memory b = h.transact(pi, aux);

        assertTrue(a[Z] != b[Z], "digest must move z");
        uint256[] memory c = _transactCoeffs(pi);
        assertEq(a[Y], SnarkCompression.evaluatePolyAt(c, a[Z]), "y is the coefficients alone at z");
        assertEq(b[Y], SnarkCompression.evaluatePolyAt(c, b[Z]), "y is the coefficients alone at the new z");
    }

    /// With every coefficient zero the polynomial is zero, so `y` is 0 for any
    /// digest while `z` still follows it. Were the digest evaluated as a
    /// fourteenth coefficient, `y` would be `digest * z^13`.
    function testFuzz_transact_digestChangesZNotY(uint256 d0, uint256 d1) public view {
        vm.assume(d0 != d1);
        PubInputs.Transact memory pi;
        AuxValidation.Output[6] memory aux = _sampleAux(0);

        pi.digest = d0;
        uint256[3] memory a = h.transact(pi, aux);
        pi.digest = d1;
        uint256[3] memory b = h.transact(pi, aux);

        assertTrue(a[Z] != b[Z], "digest must move z");
        assertEq(a[Y], 0, "y has no digest term");
        assertEq(b[Y], 0, "y has no digest term");
    }

    /// An evaluated word outside the field reverts; the digest does not, being
    /// hashed only. `compress` leaves its range to the verifiers, which reject
    /// any public signal `>= R`.
    function test_transact_digestOutOfFieldDoesNotRevert() public view {
        PubInputs.Transact memory pi = _sampleTransact(1);
        AuxValidation.Output[6] memory aux = _sampleAux(1);

        pi.digest = R;
        assertEq(h.transact(pi, aux)[DIGEST], R, "digest == R passes through");
        pi.digest = type(uint256).max;
        uint256[3] memory out = h.transact(pi, aux);
        assertEq(out[DIGEST], type(uint256).max, "digest passes through at full width");
        assertLt(out[Z], R, "z stays in the field");
        assertLt(out[Y], R, "y stays in the field");
    }

    /// Every coefficient that can hold a full word is range-checked: the root,
    /// the nullifiers and the output commitments. The two `uint64` publics
    /// cannot reach `R`.
    function testFuzz_revert_transact_coefficientOutOfField(uint256 seed, uint8 which, uint256 over) public {
        PubInputs.Transact memory pi = _sampleTransact(seed);
        AuxValidation.Output[6] memory aux = _sampleAux(seed);
        bytes32 bad = bytes32(bound(over, R, type(uint256).max));

        uint256 w = uint256(which) % (1 + PubInputs.TRANSACT_IN + PubInputs.TRANSACT_OUT);
        if (w == 0) pi.merkleRoot = bad;
        else if (w <= PubInputs.TRANSACT_IN) pi.nullifier[w - 1] = bad;
        else pi.outCm[w - 1 - PubInputs.TRANSACT_IN] = bad;

        vm.expectRevert(SnarkCompression.CoefficientOutOfField.selector);
        h.transact(pi, aux);
    }

    /// The words after the digest are hashed only, like it: a full-width
    /// `chainId` or `intentHash` does not revert.
    function test_transact_challengeOnlyWordsAreNotRangeChecked() public view {
        PubInputs.Transact memory pi = _sampleTransact(2);
        pi.chainId = type(uint256).max;
        pi.intentHash = type(uint256).max;
        assertLt(h.transact(pi, _sampleAux(2))[Z], R, "z stays in the field");
    }

    // --- dirty high bits: Transact ------------------------------------------
    //
    // The fast path copies the struct's calldata words verbatim, so a sub-word
    // member's unused high bits would reach the hash unless `compress` cleared
    // them. A typed read reverts on them instead; the reference path takes a
    // decoded struct and never sees them.

    /// `publicAssetId` and `publicOut` are masked to 64 bits, `recipient`,
    /// `payer` and `relayer` to 160: dirty calldata compresses to exactly what
    /// the clean struct does.
    function testFuzz_transact_masksDirtyHighBits(uint256 seed, uint256 dirt) public view {
        PubInputs.Transact memory pi = _sampleTransact(seed);
        AuxValidation.Output[6] memory aux = _sampleAux(seed);
        bytes memory cd = abi.encodeCall(h.transact, (pi, aux));

        // At least one bit above each member's width.
        uint256 above64 = (dirt | 1) << 64;
        uint256 above160 = (dirt | 1) << 160;
        _or(cd, T_PUBLIC_ASSET_ID, above64);
        _or(cd, T_PUBLIC_OUT, above64);
        _or(cd, T_RECIPIENT, above160);
        _or(cd, T_PAYER, above160);
        _or(cd, T_RELAYER, above160);

        _assertSame(_call(cd), h.transact(pi, aux));

        // The dirt is in typed members: the reference harness, which decodes
        // the same calldata into a memory struct, refuses it.
        (bool ok,) = address(h).staticcall(_retarget(cd, CompressHarness.transactRef.selector));
        assertFalse(ok, "a typed decode rejects the dirty words");
    }

    /// The full-width words are not masked: the same bits set in `digest`,
    /// `chainId` or `intentHash` are part of the value and move `z`.
    function testFuzz_transact_fullWordsAreNotMasked(uint256 seed, uint8 which) public view {
        PubInputs.Transact memory pi = _sampleTransact(seed);
        AuxValidation.Output[6] memory aux = _sampleAux(seed);
        // Clear the top bit so setting it below is a change.
        pi.digest &= type(uint256).max >> 1;
        pi.chainId &= type(uint256).max >> 1;
        pi.intentHash &= type(uint256).max >> 1;
        bytes memory cd = abi.encodeCall(h.transact, (pi, aux));

        uint256[3] memory word = [T_DIGEST, T_CHAIN_ID, T_INTENT_HASH];
        _or(cd, word[which % 3], 1 << 255);

        assertTrue(_call(cd)[Z] != h.transact(pi, aux)[Z], "a full word's top bit must move z");
    }

    // --- TreeUpdateBatch layout --------------------------------------------

    function test_compressTreeUpdateBatch_layoutMatchesManualPolyEval() public view {
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(1);
        tpi.leafAsset[0] = 7;
        tpi.leafPublicIn[0] = 1000;
        tpi.isDeposit[0] = 1;
        tpi.digest = 0xd16e57;
        uint256[3] memory got = h.batch(tpi);

        // Re-derives (y, z) manually to pin both layouts.
        // Coefficients: 4 header + MAX_L cms + MAX_L leafAsset
        //             + MAX_L leafPublicIn + MAX_L isDeposit  =  4 + 4*MAX_L
        // Preimage: the coefficients, then the digest word.
        uint256[] memory c = _batchCoeffs(tpi);
        uint256[] memory pre = new uint256[](c.length + 1);
        for (uint256 i = 0; i < c.length; i++) {
            pre[i] = c[i];
        }
        pre[c.length] = tpi.digest;

        uint256 z = uint256(keccak256(abi.encode(pre))) % R;
        uint256 y = SnarkCompression.evaluatePolyAt(c, z);

        assertEq(got[Y], y, "y mismatch");
        assertEq(got[DIGEST], tpi.digest, "digest mismatch");
        assertEq(got[Z], z, "z mismatch");
    }

    function test_compressTreeUpdateBatch_actualCountAffectsHash() public view {
        PubInputs.TreeUpdateBatch memory a = _sampleBatch(1);
        PubInputs.TreeUpdateBatch memory b = _sampleBatch(1);
        b.actualCount = 2;
        // Both have all-zero cms beyond the first slot; only actualCount
        // differs, and PolyEval distinguishes them.
        uint256[3] memory ca = h.batch(a);
        uint256[3] memory cb = h.batch(b);
        assertTrue(ca[Y] != cb[Y] || ca[Z] != cb[Z], "actualCount must affect compress");
    }

    function test_compressTreeUpdateBatch_paddingSlotAffectsHash() public view {
        // Two batches identical except cms[MAX_L_BATCH - 1] (padding slot).
        // Compression covers every coefficient, padding included, so the
        // SNARK can constrain padding == 0.
        PubInputs.TreeUpdateBatch memory a = _sampleBatch(1);
        PubInputs.TreeUpdateBatch memory b = _sampleBatch(1);
        b.cms[PubInputs.MAX_L_BATCH - 1] = bytes32(uint256(0xdeadbeef));
        uint256[3] memory ca = h.batch(a);
        uint256[3] memory cb = h.batch(b);
        assertTrue(ca[Y] != cb[Y] || ca[Z] != cb[Z], "padding slot must bind");
    }

    function testFuzz_compressTreeUpdateBatch_zInField(bytes32 ro, bytes32 rn, uint64 si, uint64 ac, bytes32 c0)
        public
        view
    {
        // Clamp roots and cms into the BN254 scalar field; compress reverts
        // with CoefficientOutOfField when any coefficient is >= R.
        ro = bytes32(uint256(ro) % R);
        rn = bytes32(uint256(rn) % R);
        c0 = bytes32(uint256(c0) % R);
        ac = uint64(bound(ac, 1, uint64(PubInputs.MAX_L_BATCH)));
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = ro;
        tpi.newRoot = rn;
        tpi.startIndex = si;
        tpi.actualCount = ac;
        tpi.cms[0] = c0;
        uint256[3] memory got = h.batch(tpi);
        assertLt(got[Z], R, "z must be in field");
        assertLt(got[Y], R, "y must be in field");
    }

    function test_compressTreeUpdateBatch_outOfFieldReverts() public {
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(1);
        tpi.cms[0] = bytes32(R);
        vm.expectRevert(SnarkCompression.CoefficientOutOfField.selector);
        h.batch(tpi);
    }

    /// Every coefficient that can hold a full word is range-checked: both
    /// roots and each `cms` slot. The remaining coefficients are masked to 64
    /// or 8 bits and cannot reach `R`.
    function testFuzz_revert_batch_coefficientOutOfField(uint8 which, uint256 over) public {
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(3);
        bytes32 bad = bytes32(bound(over, R, type(uint256).max));

        uint256 w = uint256(which) % (2 + PubInputs.MAX_L_BATCH);
        if (w == 0) tpi.oldRoot = bad;
        else if (w == 1) tpi.newRoot = bad;
        else tpi.cms[w - 2] = bad;

        vm.expectRevert(SnarkCompression.CoefficientOutOfField.selector);
        h.batch(tpi);
    }

    // --- the digest word: TreeUpdateBatch -----------------------------------

    function testFuzz_batch_digestReturnedUnmodified(uint64 ac, uint256 digest) public view {
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(uint64(bound(ac, 1, PubInputs.MAX_L_BATCH)));
        tpi.digest = digest;
        assertEq(h.batch(tpi)[DIGEST], digest, "digest is signal 1, as given");
    }

    /// As on the transact shape: the digest is in the preimage of `z` and
    /// contributes no term to `y`, which stays the evaluation of the 36
    /// coefficients alone at whatever `z` results.
    function testFuzz_batch_digestMovesZAndIsNotEvaluated(uint64 ac, uint256 d0, uint256 d1) public view {
        vm.assume(d0 != d1);
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(uint64(bound(ac, 1, PubInputs.MAX_L_BATCH)));

        tpi.digest = d0;
        uint256[3] memory a = h.batch(tpi);
        tpi.digest = d1;
        uint256[3] memory b = h.batch(tpi);

        assertTrue(a[Z] != b[Z], "digest must move z");
        uint256[] memory c = _batchCoeffs(tpi);
        assertEq(a[Y], SnarkCompression.evaluatePolyAt(c, a[Z]), "y is the coefficients alone at z");
        assertEq(b[Y], SnarkCompression.evaluatePolyAt(c, b[Z]), "y is the coefficients alone at the new z");
    }

    /// With every coefficient zero, `y` is 0 for any digest while `z` follows
    /// it. Were the digest a thirty-seventh coefficient, `y` would be
    /// `digest * z^36`.
    function testFuzz_batch_digestChangesZNotY(uint256 d0, uint256 d1) public view {
        vm.assume(d0 != d1);
        PubInputs.TreeUpdateBatch memory tpi;

        tpi.digest = d0;
        uint256[3] memory a = h.batch(tpi);
        tpi.digest = d1;
        uint256[3] memory b = h.batch(tpi);

        assertTrue(a[Z] != b[Z], "digest must move z");
        assertEq(a[Y], 0, "y has no digest term");
        assertEq(b[Y], 0, "y has no digest term");
    }

    /// The counterpart of `test_compressTreeUpdateBatch_outOfFieldReverts`: the
    /// same out-of-field word in the digest slot is accepted, because the
    /// digest is not evaluated. The verifiers reject it as a public signal.
    function test_batch_digestOutOfFieldDoesNotRevert() public view {
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(1);

        tpi.digest = R;
        assertEq(h.batch(tpi)[DIGEST], R, "digest == R passes through");
        tpi.digest = type(uint256).max;
        uint256[3] memory out = h.batch(tpi);
        assertEq(out[DIGEST], type(uint256).max, "digest passes through at full width");
        assertLt(out[Z], R, "z stays in the field");
        assertLt(out[Y], R, "y stays in the field");
    }

    // --- dirty high bits: TreeUpdateBatch -----------------------------------

    /// `startIndex`, `actualCount`, `leafAsset[]` and `leafPublicIn[]` are
    /// masked to 64 bits and `isDeposit[]` to 8: dirty calldata compresses to
    /// exactly what the clean struct does.
    function testFuzz_batch_masksDirtyHighBits(uint64 ac, uint256 digest, uint256 dirt) public view {
        uint256 n = PubInputs.MAX_L_BATCH;
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(uint64(bound(ac, 1, n)));
        for (uint256 k = 0; k < n; k++) {
            tpi.leafAsset[k] = uint64(k + 1);
            tpi.leafPublicIn[k] = uint64(100 + k);
            tpi.isDeposit[k] = uint8(k & 1);
        }
        tpi.digest = digest;
        bytes memory cd = abi.encodeCall(h.batch, (tpi));

        uint256 above64 = (dirt | 1) << 64;
        uint256 above8 = (dirt | 1) << 8;
        _or(cd, 2, above64); // startIndex
        _or(cd, 3, above64); // actualCount
        for (uint256 k = 0; k < n; k++) {
            _or(cd, 4 + n + k, above64); // leafAsset
            _or(cd, 4 + 2 * n + k, above64); // leafPublicIn
            _or(cd, 4 + 3 * n + k, above8); // isDeposit
        }

        _assertSame(_call(cd), h.batch(tpi));

        // As on the transact shape: a typed decode of the same calldata fails.
        (bool ok,) = address(h).staticcall(_retarget(cd, CompressHarness.batchRef.selector));
        assertFalse(ok, "a typed decode rejects the dirty words");
    }

    /// The digest word is the one full-width word after the masked arrays: its
    /// high bits are part of the value, returned and hashed.
    function test_batch_digestIsNotMasked() public view {
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(2);
        tpi.digest = 1;
        bytes memory cd = abi.encodeCall(h.batch, (tpi));
        _or(cd, B_COEFFS, 1 << 255);

        uint256[3] memory dirty = _call(cd);
        uint256[3] memory clean = h.batch(tpi);
        assertEq(dirty[DIGEST], (1 << 255) | 1, "digest keeps every bit");
        assertTrue(dirty[Z] != clean[Z], "digest top bit must move z");
    }

    // --- helpers -----------------------------------------------------------

    function _assertSame(uint256[3] memory a, uint256[3] memory b) internal pure {
        assertEq(a[Y], b[Y], "y mismatch");
        assertEq(a[DIGEST], b[DIGEST], "digest mismatch");
        assertEq(a[Z], b[Z], "z mismatch");
    }

    /// Calls the harness with hand-built calldata, which a typed call would
    /// re-encode clean.
    function _call(bytes memory cd) internal view returns (uint256[3] memory) {
        (bool ok, bytes memory ret) = address(h).staticcall(cd);
        assertTrue(ok, "harness call reverted");
        return abi.decode(ret, (uint256[3]));
    }

    /// A copy of `cd` addressed to another harness function taking the same
    /// arguments.
    function _retarget(bytes memory cd, bytes4 selector) internal pure returns (bytes memory out) {
        out = bytes.concat(cd);
        for (uint256 i = 0; i < 4; i++) {
            out[i] = selector[i];
        }
    }

    /// ORs `bits` into argument word `word` of `cd`. Both structs are static
    /// and the first argument, so word `k` of the struct is word `k` of the
    /// arguments.
    function _or(bytes memory cd, uint256 word, uint256 bits) internal pure {
        uint256 offset = 0x20 + 4 + word * 0x20;
        assembly ("memory-safe") {
            let p := add(cd, offset)
            mstore(p, or(mload(p), bits))
        }
    }

    function _sampleBatch(uint64 ac) internal pure returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = bytes32(uint256(0xa11ce));
        tpi.newRoot = bytes32(uint256(0xb0b));
        tpi.startIndex = 7;
        tpi.actualCount = ac;
        // `actualCount` counts leaves, not pairs, so one slot per unit.
        for (uint64 i = 0; i < ac; i++) {
            tpi.cms[i] = bytes32(uint256(0xc1 + i));
        }
        // Remaining cms[i] for i >= ac stay zero.
    }

    /// The batch's 36 coefficients in circuit order, written out independently
    /// of `PubInputs.compressRef`.
    function _batchCoeffs(PubInputs.TreeUpdateBatch memory tpi) internal pure returns (uint256[] memory s) {
        uint256 n = PubInputs.MAX_L_BATCH;
        s = new uint256[](4 + 4 * n);
        s[0] = uint256(tpi.oldRoot);
        s[1] = uint256(tpi.newRoot);
        s[2] = uint256(tpi.startIndex);
        s[3] = uint256(tpi.actualCount);
        for (uint256 i = 0; i < n; i++) {
            s[4 + i] = uint256(tpi.cms[i]);
            s[4 + n + i] = uint256(tpi.leafAsset[i]);
            s[4 + 2 * n + i] = uint256(tpi.leafPublicIn[i]);
            s[4 + 3 * n + i] = uint256(tpi.isDeposit[i]);
        }
    }

    /// A `Transact` with every member set from `seed`: field elements where
    /// the word is evaluated, full words where it is only hashed.
    function _sampleTransact(uint256 seed) internal pure returns (PubInputs.Transact memory pi) {
        pi.merkleRoot = bytes32(_field(seed, "root", 0));
        for (uint256 k = 0; k < PubInputs.TRANSACT_IN; k++) {
            pi.nullifier[k] = bytes32(_field(seed, "nf", k));
        }
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; k++) {
            pi.outCm[k] = bytes32(_field(seed, "cm", k));
        }
        pi.publicAssetId = uint64(_word(seed, "asset"));
        pi.publicOut = uint64(_word(seed, "out"));
        pi.digest = _word(seed, "digest");
        pi.recipient = address(uint160(_word(seed, "recipient")));
        pi.chainId = _word(seed, "chain");
        pi.payer = address(uint160(_word(seed, "payer")));
        pi.relayer = address(uint160(_word(seed, "relayer")));
        pi.intentHash = _word(seed, "intent");
    }

    /// The transact shape's 13 coefficients in circuit order.
    function _transactCoeffs(PubInputs.Transact memory pi) internal pure returns (uint256[] memory c) {
        c = new uint256[](3 + PubInputs.TRANSACT_IN + PubInputs.TRANSACT_OUT);
        uint256 i;
        c[i++] = uint256(pi.merkleRoot);
        for (uint256 k = 0; k < PubInputs.TRANSACT_IN; k++) {
            c[i++] = uint256(pi.nullifier[k]);
        }
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; k++) {
            c[i++] = uint256(pi.outCm[k]);
        }
        c[i++] = uint256(pi.publicAssetId);
        c[i++] = uint256(pi.publicOut);
    }

    function _sampleAux(uint256 seed) internal pure returns (AuxValidation.Output[6] memory aux) {
        for (uint256 j = 0; j < aux.length; j++) {
            aux[j].clueRx = _field(seed, "rx", j);
            aux[j].clueRy = _field(seed, "ry", j);
            aux[j].ciphertext = abi.encodePacked(uint16(0x0123), bytes32(seed));
        }
    }

    function _field(uint256 seed, string memory tag, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, tag, i))) % R;
    }

    /// As `_field`, at full width: for a member that is hashed only, or
    /// narrowed to its own type.
    function _word(uint256 seed, string memory tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, tag)));
    }
}
