// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { SnarkCompression } from "../src/SnarkCompression.sol";

/// Exposes both compression paths across an external call boundary so the
/// `calldata` fast paths get real calldata to read from.
contract PubInputsHarness {
    using PubInputs for PubInputs.TreeUpdateBatch;
    using PubInputs for PubInputs.Transact;

    function batch(PubInputs.TreeUpdateBatch calldata tpi) external pure returns (uint256[2] memory) {
        return tpi.compress();
    }

    function batchRef(PubInputs.TreeUpdateBatch calldata tpi) external pure returns (uint256[2] memory) {
        // Forces the calldata → memory decode, then runs the reference path.
        PubInputs.TreeUpdateBatch memory m = tpi;
        return PubInputs.compressRef(m);
    }

    function transact(PubInputs.Transact calldata pi, AuxValidation.Output[3] calldata aux)
        external
        pure
        returns (uint256[2] memory)
    {
        return PubInputs.compress(pi, aux);
    }

    function transactRef(PubInputs.Transact calldata pi, AuxValidation.Output[3] calldata aux)
        external
        pure
        returns (uint256[2] memory)
    {
        PubInputs.Transact memory m = pi;
        return PubInputs.compressRef(m, aux);
    }
}

/// Smoke and property tests for `PubInputs.compress`. Cross-checks the
/// `TreeUpdateBatch` flatten order against a manual PolyEval to fix the
/// on-chain to circuit coefficient layout, and pins the calldata fast path to
/// the memory reference path.
contract PubInputsTest is Test {
    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    PubInputsHarness internal h;

    function setUp() public {
        h = new PubInputsHarness();
    }

    // --- fast path ≡ reference path ----------------------------------------

    function test_batch_fastPathMatchesReference() public view {
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(3);
        uint256[2] memory fast = h.batch(tpi);
        uint256[2] memory ref = h.batchRef(tpi);
        assertEq(fast[0], ref[0], "y mismatch");
        assertEq(fast[1], ref[1], "z mismatch");
    }

    function testFuzz_batch_fastPathMatchesReference(
        bytes32 ro,
        bytes32 rn,
        uint64 si,
        uint64 ac,
        uint256 cmSeed,
        uint256 cvSeed,
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
            tpi.cvDeps[i][0] = uint256(keccak256(abi.encode(cvSeed, i, uint256(0)))) % R;
            tpi.cvDeps[i][1] = uint256(keccak256(abi.encode(cvSeed, i, uint256(1)))) % R;
        }
        tpi.leafAsset[0] = asset0;
        tpi.leafPublicIn[0] = in0;
        tpi.isDeposit[0] = dep0;
        // Padding slots are non-zero as well; the SNARK must bind them.
        tpi.leafAsset[PubInputs.MAX_L_BATCH - 1] = asset0;
        tpi.isDeposit[PubInputs.MAX_L_BATCH - 1] = dep0;

        uint256[2] memory fast = h.batch(tpi);
        uint256[2] memory ref = h.batchRef(tpi);
        assertEq(fast[0], ref[0], "y mismatch");
        assertEq(fast[1], ref[1], "z mismatch");
    }

    function testFuzz_transact_fastPathMatchesReference(
        bytes32 root,
        bytes32 nf0,
        bytes32 nf1,
        bytes32 cm0,
        bytes32 cm1,
        uint64 assetId,
        uint64 pin,
        uint64 pout,
        address recipient,
        address relayer,
        uint256 cvSeed
    ) public view {
        PubInputs.Transact memory pi;
        pi.merkleRoot = bytes32(uint256(root) % R);
        pi.nullifier[0] = bytes32(uint256(nf0) % R);
        pi.nullifier[1] = bytes32(uint256(nf1) % R);
        pi.outCm[0] = bytes32(uint256(cm0) % R);
        pi.outCm[1] = bytes32(uint256(cm1) % R);
        pi.publicAssetId = assetId;
        pi.publicIn = pin;
        pi.publicOut = pout;
        pi.recipient = recipient;
        pi.relayer = relayer;
        pi.payer = address(uint160(uint256(keccak256(abi.encode(cvSeed)))));
        pi.chainId = block.chainid;
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 k = 0; k < 2; k++) {
                pi.inCv[i][k] = uint256(keccak256(abi.encode(cvSeed, "in", i, k))) % R;
                pi.outCv[i][k] = uint256(keccak256(abi.encode(cvSeed, "out", i, k))) % R;
                pi.outCvDep[i][k] = uint256(keccak256(abi.encode(cvSeed, "dep", i, k))) % R;
            }
        }

        AuxValidation.Output[3] memory aux;
        for (uint256 j = 0; j < 3; j++) {
            aux[j].clueRx = uint256(keccak256(abi.encode(cvSeed, "rx", j))) % R;
            aux[j].clueRy = uint256(keccak256(abi.encode(cvSeed, "ry", j))) % R;
            aux[j].ciphertext = abi.encodePacked(uint16(0x0123), bytes32(cvSeed));
        }

        uint256[2] memory fast = h.transact(pi, aux);
        uint256[2] memory ref = h.transactRef(pi, aux);
        assertEq(fast[0], ref[0], "y mismatch");
        assertEq(fast[1], ref[1], "z mismatch");
    }

    // --- TreeUpdateBatch layout --------------------------------------------

    function test_compressTreeUpdateBatch_layoutMatchesManualPolyEval() public view {
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(1);
        uint256[2] memory got = h.batch(tpi);

        // Re-derive (z, y) manually to lock the coefficient layout.
        // Layout: 4 header + MAX_L cms + 2*MAX_L cvDeps + MAX_L leafAsset
        //       + MAX_L leafPublicIn + MAX_L isDeposit  =  4 + 6*MAX_L
        uint256 N = PubInputs.MAX_L_BATCH;
        uint256[] memory s = new uint256[](4 + 6 * N);
        s[0] = uint256(tpi.oldRoot);
        s[1] = uint256(tpi.newRoot);
        s[2] = uint256(tpi.startIndex);
        s[3] = uint256(tpi.actualCount);
        uint256 off = 4;
        for (uint256 i = 0; i < N; i++) {
            s[off + i] = uint256(tpi.cms[i]);
        }
        off += N;
        for (uint256 i = 0; i < N; i++) {
            s[off + 2 * i + 0] = tpi.cvDeps[i][0];
            s[off + 2 * i + 1] = tpi.cvDeps[i][1];
        }
        off += 2 * N;
        for (uint256 i = 0; i < N; i++) {
            s[off + i] = uint256(tpi.leafAsset[i]);
        }
        off += N;
        for (uint256 i = 0; i < N; i++) {
            s[off + i] = uint256(tpi.leafPublicIn[i]);
        }
        off += N;
        for (uint256 i = 0; i < N; i++) {
            s[off + i] = uint256(tpi.isDeposit[i]);
        }

        uint256 z = uint256(keccak256(abi.encode(s))) % R;
        uint256 y = SnarkCompression.evaluatePolyAt(s, z);

        assertEq(got[0], y, "y mismatch");
        assertEq(got[1], z, "z mismatch");
    }

    function test_compressTreeUpdateBatch_actualCountAffectsHash() public view {
        PubInputs.TreeUpdateBatch memory a = _sampleBatch(1);
        PubInputs.TreeUpdateBatch memory b = _sampleBatch(1);
        b.actualCount = 2;
        // Both have all-zero cms beyond the first slot; only actualCount
        // differs. PolyEval must distinguish them.
        uint256[2] memory ca = h.batch(a);
        uint256[2] memory cb = h.batch(b);
        assertTrue(ca[0] != cb[0] || ca[1] != cb[1], "actualCount must affect compress");
    }

    function test_compressTreeUpdateBatch_paddingSlotAffectsHash() public view {
        // Two batches identical except cms[2*MAX_L_BATCH - 1] (padding slot).
        // Compress MUST reflect ALL coefficients including padding so the
        // SNARK can constrain padding == 0.
        PubInputs.TreeUpdateBatch memory a = _sampleBatch(1);
        PubInputs.TreeUpdateBatch memory b = _sampleBatch(1);
        b.cms[PubInputs.MAX_L_BATCH - 1] = bytes32(uint256(0xdeadbeef));
        uint256[2] memory ca = h.batch(a);
        uint256[2] memory cb = h.batch(b);
        assertTrue(ca[0] != cb[0] || ca[1] != cb[1], "padding slot must bind");
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
        uint256[2] memory got = h.batch(tpi);
        assertLt(got[1], R, "z must be in field");
    }

    function test_compressTreeUpdateBatch_outOfFieldReverts() public {
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(1);
        tpi.cms[0] = bytes32(R);
        vm.expectRevert(SnarkCompression.CoefficientOutOfField.selector);
        h.batch(tpi);
    }

    // --- helpers -----------------------------------------------------------

    function _sampleBatch(uint64 ac) internal pure returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = bytes32(uint256(0xa11ce));
        tpi.newRoot = bytes32(uint256(0xb0b));
        tpi.startIndex = 7;
        tpi.actualCount = ac;
        for (uint64 i = 0; i < 2 * ac; i++) {
            tpi.cms[i] = bytes32(uint256(0xc1 + i));
        }
        // Remaining cms[i] for i >= 2*ac stay zero.
    }
}
