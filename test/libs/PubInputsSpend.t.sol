// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { PubInputs } from "../../src/libs/PubInputs.sol";
import { SnarkCompression } from "../../src/SnarkCompression.sol";

/// Calldata entry points for both compressions. Each reads its arguments from
/// calldata, as `MASP` does.
contract SpendCompressHarness {
    function spend(PubInputs.Transact calldata pi, PubInputs.SpendTree calldata st, bytes32 oldRoot)
        external
        pure
        returns (uint256[2] memory)
    {
        return PubInputs.compressSpend(pi, st, oldRoot);
    }

    /// `spend` with every word past the free memory pointer set to ones first,
    /// so zero padding cannot come from fresh memory by accident.
    function spendDirtyMemory(PubInputs.Transact calldata pi, PubInputs.SpendTree calldata st, bytes32 oldRoot)
        external
        pure
        returns (uint256[2] memory)
    {
        assembly {
            let p := mload(0x40)
            for { let i := 0 } lt(i, 0x1000) { i := add(i, 0x20) } { mstore(add(p, i), not(0)) }
        }
        return PubInputs.compressSpend(pi, st, oldRoot);
    }

    function batch(PubInputs.TreeUpdateBatch calldata tpi) external pure returns (uint256[2] memory) {
        return PubInputs.compress(tpi);
    }
}

/// `PubInputs.compressSpend` is `compress(TreeUpdateBatch)` of the one batch a
/// spend admits: `oldRoot`, `newRoot`, `startIndex`, `actualCount =
/// TRANSACT_OUT`, the spend's `outCm` and `outCvDep` in the first six slots, and
/// zero everywhere else. `tree_update_batch.circom` forces those zeros (step 3
/// on the inactive slots 6 and 7, step 4 on the deposit fields of a spend
/// leaf), so this equality lets `MASP` omit the batch from calldata while
/// accepting exactly the proofs the explicit batch would accept.
contract PubInputsSpendTest is Test {
    SpendCompressHarness internal h;

    function setUp() public {
        h = new SpendCompressHarness();
    }

    function testFuzz_compressSpend_matchesFullBatch(uint256 seed, uint64 startIndex, uint8 anchorIndex) public view {
        PubInputs.Transact memory pi = _transact(seed);
        bytes32 oldRoot = bytes32(_field(seed, 1000));
        PubInputs.SpendTree memory st = PubInputs.SpendTree({
            newRoot: bytes32(_field(seed, 1001)), startIndex: startIndex, anchorIndex: anchorIndex
        });

        uint256[2] memory spend = h.spend(pi, st, oldRoot);
        uint256[2] memory full = h.batch(_fullBatch(pi, st, oldRoot));
        assertEq(spend[0], full[0], "y");
        assertEq(spend[1], full[1], "z");
    }

    /// `anchorIndex` is a lookup hint, not a public input.
    function testFuzz_compressSpend_ignoresAnchorIndex(uint256 seed, uint8 a, uint8 b) public view {
        PubInputs.Transact memory pi = _transact(seed);
        PubInputs.SpendTree memory st = PubInputs.SpendTree(bytes32(_field(seed, 1001)), 7, a);
        uint256[2] memory x = h.spend(pi, st, bytes32(_field(seed, 1000)));
        st.anchorIndex = b;
        uint256[2] memory y = h.spend(pi, st, bytes32(_field(seed, 1000)));
        assertEq(x[0], y[0], "y");
        assertEq(x[1], y[1], "z");
    }

    /// Every output commitment and value-commitment coordinate reaches the
    /// image: changing any one of them changes `z`.
    function testFuzz_compressSpend_bindsEveryOutput(uint256 seed, uint8 which) public view {
        PubInputs.Transact memory pi = _transact(seed);
        PubInputs.SpendTree memory st = PubInputs.SpendTree(bytes32(_field(seed, 1001)), 7, 0);
        bytes32 oldRoot = bytes32(_field(seed, 1000));
        uint256[2] memory before = h.spend(pi, st, oldRoot);

        uint256 w = uint256(which) % (3 * PubInputs.TRANSACT_OUT);
        uint256 k = w / 3;
        if (w % 3 == 0) pi.outCm[k] = bytes32((uint256(pi.outCm[k]) + 1) % SnarkCompression.R);
        else pi.outCvDep[k][w % 3 - 1] = (pi.outCvDep[k][w % 3 - 1] + 1) % SnarkCompression.R;

        uint256[2] memory changed = h.spend(pi, st, oldRoot);
        assertTrue(changed[1] != before[1], "z moved");
    }

    /// Fields of `Transact` outside the outputs do not enter the tree-update
    /// image; they are bound by the transact proof's own compression.
    function testFuzz_compressSpend_readsOnlyOutputs(uint256 seed, uint256 other) public view {
        PubInputs.Transact memory pi = _transact(seed);
        PubInputs.SpendTree memory st = PubInputs.SpendTree(bytes32(_field(seed, 1001)), 7, 0);
        bytes32 oldRoot = bytes32(_field(seed, 1000));
        uint256[2] memory before = h.spend(pi, st, oldRoot);

        pi.merkleRoot = bytes32(_field(other, 1));
        pi.nullifier[other % 4] = bytes32(_field(other, 2));
        pi.outCv[other % 6] = [_field(other, 3), _field(other, 4)];
        pi.inCv[other % 4] = [_field(other, 5), _field(other, 6)];
        pi.publicAssetId = uint64(other);
        pi.publicOut = uint64(other >> 64);
        pi.recipient = address(uint160(other));
        pi.payer = address(uint160(other >> 8));
        pi.relayer = address(uint160(other >> 16));
        pi.chainId = other;

        uint256[2] memory after_ = h.spend(pi, st, oldRoot);
        assertEq(after_[0], before[0], "y");
        assertEq(after_[1], before[1], "z");
    }

    /// Dirty memory past the free pointer does not leak into the zero padding.
    function testFuzz_compressSpend_paddingIndependentOfMemory(uint256 seed) public view {
        PubInputs.Transact memory pi = _transact(seed);
        PubInputs.SpendTree memory st = PubInputs.SpendTree(bytes32(_field(seed, 1001)), 7, 0);
        bytes32 oldRoot = bytes32(_field(seed, 1000));
        uint256[2] memory dirty = h.spendDirtyMemory(pi, st, oldRoot);
        uint256[2] memory full = h.batch(_fullBatch(pi, st, oldRoot));
        assertEq(dirty[0], full[0], "y");
        assertEq(dirty[1], full[1], "z");
    }

    function test_compressSpend_zeroSpend_paddingIndependentOfMemory() public view {
        PubInputs.Transact memory pi;
        PubInputs.SpendTree memory st;
        uint256[2] memory dirty = h.spendDirtyMemory(pi, st, bytes32(0));
        PubInputs.TreeUpdateBatch memory t;
        t.actualCount = uint64(PubInputs.TRANSACT_OUT);
        uint256[2] memory full = h.batch(t);
        assertEq(dirty[0], full[0], "y");
        assertEq(dirty[1], full[1], "z");
    }

    // --- helpers -----------------------------------------------------------

    /// The explicit batch a spend implies; `compressSpend` must match its
    /// compression.
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
            t.cvDeps[k] = pi.outCvDep[k];
        }
    }

    function _transact(uint256 seed) internal pure returns (PubInputs.Transact memory pi) {
        uint256 n;
        pi.merkleRoot = bytes32(_field(seed, n++));
        for (uint256 k; k < PubInputs.TRANSACT_IN; ++k) {
            pi.nullifier[k] = bytes32(_field(seed, n++));
            pi.inCv[k] = [_field(seed, n++), _field(seed, n++)];
        }
        for (uint256 k; k < PubInputs.TRANSACT_OUT; ++k) {
            pi.outCm[k] = bytes32(_field(seed, n++));
            pi.outCv[k] = [_field(seed, n++), _field(seed, n++)];
            pi.outCvDep[k] = [_field(seed, n++), _field(seed, n++)];
        }
        pi.publicAssetId = uint64(seed);
        pi.publicOut = uint64(seed >> 64);
        pi.recipient = address(uint160(seed));
        pi.chainId = seed >> 128;
        pi.payer = address(uint160(seed >> 3));
        pi.relayer = address(uint160(seed >> 5));
    }

    /// Public inputs are field elements; `compress` rejects anything else.
    function _field(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i))) % SnarkCompression.R;
    }
}
