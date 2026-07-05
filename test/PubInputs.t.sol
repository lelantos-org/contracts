// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { SnarkCompression } from "../src/SnarkCompression.sol";

/// Smoke + property tests for `PubInputs.compress`. Cross-checks the
/// `TreeUpdateBatch` flatten order against the contract's manual
/// PolyEval to lock in the on-chain ↔ circuit coefficient layout.
contract PubInputsTest is Test {
    using PubInputs for PubInputs.TreeUpdateBatch;

    uint256 internal constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // --- TreeUpdateBatch ---------------------------------------------------

    function test_compressTreeUpdateBatch_layoutMatchesManualPolyEval() public pure {
        PubInputs.TreeUpdateBatch memory tpi = _sampleBatch(1);
        uint256[2] memory got = tpi.compress();

        // Re-derive (z, y) manually to lock the coefficient layout.
        // Layout: 4 header + 2*MAX_N cms + 2*(2*MAX_N) cvDeps + MAX_N pairAsset
        //       + MAX_N pairPublicIn + MAX_N isDeposit  =  4 + 9*MAX_N
        uint256 N = PubInputs.MAX_N_BATCH;
        uint256[] memory s = new uint256[](4 + 9 * N);
        s[0] = uint256(tpi.oldRoot);
        s[1] = uint256(tpi.newRoot);
        s[2] = uint256(tpi.startIndex);
        s[3] = uint256(tpi.actualCount);
        uint256 off = 4;
        for (uint256 i = 0; i < 2 * N; i++) {
            s[off + i] = uint256(tpi.cms[i]);
        }
        off += 2 * N;
        for (uint256 i = 0; i < 2 * N; i++) {
            s[off + 2 * i + 0] = tpi.cvDeps[i][0];
            s[off + 2 * i + 1] = tpi.cvDeps[i][1];
        }
        off += 4 * N;
        for (uint256 i = 0; i < N; i++) {
            s[off + i] = uint256(tpi.pairAsset[i]);
        }
        off += N;
        for (uint256 i = 0; i < N; i++) {
            s[off + i] = uint256(tpi.pairPublicIn[i]);
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

    function test_compressTreeUpdateBatch_actualCountAffectsHash() public pure {
        PubInputs.TreeUpdateBatch memory a = _sampleBatch(1);
        PubInputs.TreeUpdateBatch memory b = _sampleBatch(1);
        b.actualCount = 2;
        // Both have all-zero cms beyond first slot; only actualCount differs.
        // PolyEval should distinguish.
        uint256[2] memory ca = a.compress();
        uint256[2] memory cb = b.compress();
        assertTrue(ca[0] != cb[0] || ca[1] != cb[1], "actualCount must affect compress");
    }

    function test_compressTreeUpdateBatch_paddingSlotAffectsHash() public pure {
        // Two batches identical except cms[2*MAX_N_BATCH - 1] (padding slot).
        // Compress MUST reflect ALL coefficients including padding so the
        // SNARK can constrain padding == 0.
        PubInputs.TreeUpdateBatch memory a = _sampleBatch(1);
        PubInputs.TreeUpdateBatch memory b = _sampleBatch(1);
        b.cms[2 * PubInputs.MAX_N_BATCH - 1] = bytes32(uint256(0xdeadbeef));
        uint256[2] memory ca = a.compress();
        uint256[2] memory cb = b.compress();
        assertTrue(ca[0] != cb[0] || ca[1] != cb[1], "padding slot must bind");
    }

    function testFuzz_compressTreeUpdateBatch_zInField(bytes32 ro, bytes32 rn, uint64 si, uint64 ac, bytes32 c0)
        public
        pure
    {
        // Clamp roots/cms into the BN254 scalar field — compress reverts with
        // CoefficientOutOfField when any coefficient is >= R.
        ro = bytes32(uint256(ro) % R);
        rn = bytes32(uint256(rn) % R);
        c0 = bytes32(uint256(c0) % R);
        ac = uint64(bound(ac, 1, uint64(PubInputs.MAX_N_BATCH)));
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = ro;
        tpi.newRoot = rn;
        tpi.startIndex = si;
        tpi.actualCount = ac;
        tpi.cms[0] = c0;
        uint256[2] memory got = tpi.compress();
        assertLt(got[1], R, "z must be in field");
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
        // remaining cms[i] for i ≥ 2*ac stay zero
    }
}
