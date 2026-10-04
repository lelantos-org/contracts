// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../../src/libs/PubInputs.sol";
import { SnarkCompression } from "../../src/SnarkCompression.sol";

import { CompressHarness, Y, DIGEST, Z } from "../utils/CompressHarness.sol";

/// `CompressHarness` plus a spend entry point that dirties memory first.
contract SpendCompressHarness is CompressHarness {
    /// `spend` with every word past the free memory pointer set to ones first,
    /// so zero padding cannot come from fresh memory by accident.
    function spendDirtyMemory(PubInputs.Transact calldata pi, PubInputs.SpendTree calldata st, bytes32 oldRoot)
        external
        pure
        returns (uint256[3] memory)
    {
        assembly {
            let p := mload(0x40)
            for { let i := 0 } lt(i, 0x1000) { i := add(i, 0x20) } { mstore(add(p, i), not(0)) }
        }
        return PubInputs.compressSpend(pi, st, oldRoot);
    }
}

/// `PubInputs.compressSpend` is `compress(TreeUpdateBatch)` of the one batch a
/// spend admits: `oldRoot`, `newRoot`, `startIndex`, `actualCount =
/// TRANSACT_OUT`, the spend's `outCm` in the first six `cms` slots, zero in
/// every other coefficient, and the prover's batch digest as the last word.
/// `tree_update_batch.circom` forces those zeros (the inactive slots 6 and 7,
/// and the deposit fields of a spend leaf), so this equality lets `MASP` omit
/// the batch from calldata while accepting exactly the proofs the explicit
/// batch would accept.
///
/// The digest is the one word of that image the contract cannot derive: it is
/// the batch circuit's Poseidon commitment to the 36 coefficients, supplied in
/// `SpendTree.digest`, and it is hashed and returned exactly as
/// `TreeUpdateBatch.digest` is on the flush path.
contract PubInputsSpendTest is Test {
    SpendCompressHarness internal h;

    function setUp() public {
        h = new SpendCompressHarness();
    }

    /// All three signals agree with the full batch's, its digest included.
    function testFuzz_compressSpend_matchesFullBatch(
        uint256 seed,
        uint64 startIndex,
        uint8 anchorIndex,
        uint256 batchDigest
    ) public view {
        PubInputs.Transact memory pi = _transact(seed);
        bytes32 oldRoot = bytes32(_field(seed, 1000));
        PubInputs.SpendTree memory st = PubInputs.SpendTree({
            newRoot: bytes32(_field(seed, 1001)), startIndex: startIndex, anchorIndex: anchorIndex, digest: batchDigest
        });

        uint256[3] memory spend = h.spend(pi, st, oldRoot);
        _assertSame(spend, h.batch(_fullBatch(pi, st, oldRoot)));
        assertEq(spend[DIGEST], batchDigest, "the batch digest is returned as given");
    }

    /// `anchorIndex` is a lookup hint, not a public input.
    function testFuzz_compressSpend_ignoresAnchorIndex(uint256 seed, uint8 a, uint8 b) public view {
        PubInputs.Transact memory pi = _transact(seed);
        PubInputs.SpendTree memory st = _spendTree(seed, a);
        uint256[3] memory x = h.spend(pi, st, bytes32(_field(seed, 1000)));
        st.anchorIndex = b;
        _assertSame(x, h.spend(pi, st, bytes32(_field(seed, 1000))));
    }

    /// Every output commitment reaches the image: changing any one of them
    /// changes `z`.
    function testFuzz_compressSpend_bindsEveryOutput(uint256 seed, uint8 which) public view {
        PubInputs.Transact memory pi = _transact(seed);
        PubInputs.SpendTree memory st = _spendTree(seed, 0);
        bytes32 oldRoot = bytes32(_field(seed, 1000));
        uint256[3] memory before = h.spend(pi, st, oldRoot);

        uint256 k = uint256(which) % PubInputs.TRANSACT_OUT;
        pi.outCm[k] = bytes32((uint256(pi.outCm[k]) + 1) % SnarkCompression.R);

        uint256[3] memory changed = h.spend(pi, st, oldRoot);
        assertTrue(changed[Z] != before[Z], "z moved");
    }

    /// The batch digest reaches the image and the verifier: it is returned as
    /// the second signal exactly as supplied, and changing it changes `z`.
    function testFuzz_compressSpend_bindsBatchDigest(uint256 seed, uint256 d0, uint256 d1) public view {
        vm.assume(d0 != d1);
        PubInputs.Transact memory pi = _transact(seed);
        PubInputs.SpendTree memory st = _spendTree(seed, 0);
        bytes32 oldRoot = bytes32(_field(seed, 1000));

        st.digest = d0;
        uint256[3] memory a = h.spend(pi, st, oldRoot);
        st.digest = d1;
        uint256[3] memory b = h.spend(pi, st, oldRoot);

        assertEq(a[DIGEST], d0, "digest returned as given");
        assertEq(b[DIGEST], d1, "digest returned as given");
        assertTrue(a[Z] != b[Z], "z moved");
    }

    /// The batch digest is hashed, not evaluated. With a zero spend every
    /// coefficient but `actualCount` is zero, so `y` is `TRANSACT_OUT * z^3`
    /// whatever the digest; a digest term would add `digest * z^36`.
    function testFuzz_compressSpend_digestIsNotEvaluated(uint256 digest) public view {
        PubInputs.Transact memory pi;
        PubInputs.SpendTree memory st;
        st.digest = digest;
        uint256[3] memory out = h.spend(pi, st, bytes32(0));

        uint256 r = SnarkCompression.R;
        uint256 z3 = mulmod(mulmod(out[Z], out[Z], r), out[Z], r);
        assertEq(out[Y], mulmod(PubInputs.TRANSACT_OUT, z3, r), "y has no digest term");
    }

    /// An evaluated word outside the field reverts; the digest, hashed only,
    /// does not. Its range is left to the verifiers, which reject any public
    /// signal `>= R`.
    function test_compressSpend_digestOutOfFieldDoesNotRevert() public {
        PubInputs.Transact memory pi = _transact(1);
        PubInputs.SpendTree memory st = _spendTree(1, 0);
        bytes32 oldRoot = bytes32(_field(1, 1000));

        st.digest = SnarkCompression.R;
        assertEq(h.spend(pi, st, oldRoot)[DIGEST], SnarkCompression.R, "digest == R passes through");
        st.digest = type(uint256).max;
        assertEq(h.spend(pi, st, oldRoot)[DIGEST], type(uint256).max, "digest passes through at full width");

        // The same word as a coefficient is rejected.
        st.digest = 0;
        st.newRoot = bytes32(SnarkCompression.R);
        vm.expectRevert(SnarkCompression.CoefficientOutOfField.selector);
        h.spend(pi, st, oldRoot);
    }

    /// Fields of `Transact` outside the outputs do not enter the tree-update
    /// image; they are bound by the transact proof's own compression. That
    /// includes `Transact.digest`, the transact circuit's commitment, which is
    /// a different word from the batch digest in `SpendTree`.
    function testFuzz_compressSpend_readsOnlyOutputs(uint256 seed, uint256 other) public view {
        PubInputs.Transact memory pi = _transact(seed);
        PubInputs.SpendTree memory st = _spendTree(seed, 0);
        bytes32 oldRoot = bytes32(_field(seed, 1000));
        uint256[3] memory before = h.spend(pi, st, oldRoot);

        pi.merkleRoot = bytes32(_field(other, 1));
        pi.nullifier[other % 4] = bytes32(_field(other, 2));
        pi.publicAssetId = uint64(other);
        pi.publicOut = uint64(other >> 64);
        pi.digest = _field(other, 3);
        pi.recipient = address(uint160(other));
        pi.payer = address(uint160(other >> 8));
        pi.relayer = address(uint160(other >> 16));
        pi.chainId = other;
        pi.intentHash = _field(other, 4);

        _assertSame(h.spend(pi, st, oldRoot), before);
    }

    /// Dirty memory past the free pointer does not leak into the zero padding.
    function testFuzz_compressSpend_paddingIndependentOfMemory(uint256 seed) public view {
        PubInputs.Transact memory pi = _transact(seed);
        PubInputs.SpendTree memory st = _spendTree(seed, 0);
        bytes32 oldRoot = bytes32(_field(seed, 1000));
        _assertSame(h.spendDirtyMemory(pi, st, oldRoot), h.batch(_fullBatch(pi, st, oldRoot)));
    }

    function test_compressSpend_zeroSpend_paddingIndependentOfMemory() public view {
        PubInputs.Transact memory pi;
        PubInputs.SpendTree memory st;
        PubInputs.TreeUpdateBatch memory t;
        t.actualCount = uint64(PubInputs.TRANSACT_OUT);
        _assertSame(h.spendDirtyMemory(pi, st, bytes32(0)), h.batch(t));
    }

    // --- helpers -----------------------------------------------------------

    function _assertSame(uint256[3] memory a, uint256[3] memory b) internal pure {
        assertEq(a[Y], b[Y], "y");
        assertEq(a[DIGEST], b[DIGEST], "digest");
        assertEq(a[Z], b[Z], "z");
    }

    /// The explicit batch a spend implies; `compressSpend` must match its
    /// compression. The digest is the batch's own, carried by `st`.
    function _fullBatch(PubInputs.Transact memory pi, PubInputs.SpendTree memory st, bytes32 oldRoot)
        internal
        pure
        returns (PubInputs.TreeUpdateBatch memory t)
    {
        t.oldRoot = oldRoot;
        t.newRoot = st.newRoot;
        t.startIndex = st.startIndex;
        t.actualCount = uint64(PubInputs.TRANSACT_OUT);
        for (uint256 k; k < PubInputs.TRANSACT_OUT; ++k) {
            t.cms[k] = pi.outCm[k];
        }
        t.digest = st.digest;
    }

    /// A spend-tree argument at a fixed position, with a seeded batch digest.
    function _spendTree(uint256 seed, uint8 anchorIndex) internal pure returns (PubInputs.SpendTree memory) {
        return PubInputs.SpendTree({
            newRoot: bytes32(_field(seed, 1001)),
            startIndex: 7,
            anchorIndex: anchorIndex,
            digest: uint256(keccak256(abi.encode(seed, "batch digest")))
        });
    }

    function _transact(uint256 seed) internal pure returns (PubInputs.Transact memory pi) {
        uint256 n;
        pi.merkleRoot = bytes32(_field(seed, n++));
        for (uint256 k; k < PubInputs.TRANSACT_IN; ++k) {
            pi.nullifier[k] = bytes32(_field(seed, n++));
        }
        for (uint256 k; k < PubInputs.TRANSACT_OUT; ++k) {
            pi.outCm[k] = bytes32(_field(seed, n++));
        }
        pi.publicAssetId = uint64(seed);
        pi.publicOut = uint64(seed >> 64);
        pi.digest = _field(seed, n++);
        pi.recipient = address(uint160(seed));
        pi.chainId = seed >> 128;
        pi.payer = address(uint160(seed >> 3));
        pi.relayer = address(uint160(seed >> 5));
        pi.intentHash = _field(seed, n++);
    }

    /// Public inputs are field elements; `compress` rejects anything else.
    function _field(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i))) % SnarkCompression.R;
    }
}
