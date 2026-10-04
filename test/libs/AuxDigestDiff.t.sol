// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

contract AuxDigestHarness {
    function fast(AuxValidation.Output[6] calldata aux) external pure returns (uint256) {
        return PubInputs.auxDigest(aux);
    }

    function ref(AuxValidation.Output[6] calldata aux) external pure returns (uint256) {
        return PubInputs.auxDigestRef(aux);
    }
}

/// `PubInputs.auxDigest` builds the dynamic `tuple[]` image from the fixed
/// array's encoding; `auxDigestRef` decodes into a dynamic array and encodes
/// that. The two must agree on every calldata the pool can be handed, canonical
/// or not.
contract AuxDigestDiffTest is Test {
    AuxDigestHarness internal h = new AuxDigestHarness();

    function _aux(uint256[24] memory w, bytes[6] memory ct) internal pure returns (AuxValidation.Output[6] memory aux) {
        for (uint256 j; j < 6; ++j) {
            aux[j] = AuxValidation.Output(w[4 * j], w[4 * j + 1], w[4 * j + 2], w[4 * j + 3], ct[j]);
        }
    }

    /// Calls `fast` and `ref` with the same argument bytes.
    function _both(bytes memory cd) internal view returns (bool ok1, bytes memory r1, bool ok2, bytes memory r2) {
        (ok1, r1) = address(h).staticcall(cd);
        bytes4 sel = AuxDigestHarness.ref.selector;
        assembly ("memory-safe") {
            mstore(add(cd, 0x20), or(and(mload(add(cd, 0x20)), not(shl(224, 0xffffffff))), sel))
        }
        (ok2, r2) = address(h).staticcall(cd);
    }

    function testFuzz_auxDigest_matchesRef(uint256[24] memory w, bytes[6] memory ct) public view {
        AuxValidation.Output[6] memory aux = _aux(w, ct);
        assertEq(h.fast(aux), h.ref(aux));
    }

    /// Two heads sharing one tail, and bytes past the canonical encoding.
    function testFuzz_auxDigest_sharedTailAndTrailingBytes(
        uint256[24] memory w,
        bytes[6] memory ct,
        uint8 share,
        bytes32 trailing
    ) public view {
        bytes memory cd = abi.encodeCall(AuxDigestHarness.fast, (_aux(w, ct)));
        uint256 k = share % 6;
        assembly ("memory-safe") {
            // cd: [len][sel][0x20][six element offsets]...
            mstore(add(add(cd, 0x44), mul(k, 0x20)), mload(add(cd, 0x44)))
        }
        cd = bytes.concat(cd, trailing);
        (bool ok1, bytes memory r1, bool ok2, bytes memory r2) = _both(cd);
        assertTrue(ok1 && ok2, "both must succeed");
        assertEq(r1, r2);
    }

    /// Non-zero bytes in the padding of the last ciphertext, which sits at the
    /// end of the encoding. Neither path may let them reach the digest.
    function testFuzz_auxDigest_dirtyPadding(uint256[24] memory w, bytes[6] memory ct, uint8 len, bytes1 dirt)
        public
        view
    {
        vm.assume(dirt != 0);
        // A length that is not a multiple of 32 leaves padding to dirty.
        uint256 n = uint256(len) % 31 + 1;
        ct[5] = new bytes(n);
        AuxValidation.Output[6] memory aux = _aux(w, ct);
        uint256 clean = h.fast(aux);

        bytes memory cd = abi.encodeCall(AuxDigestHarness.fast, (aux));
        cd[cd.length - 1] = dirt;
        (bool ok1, bytes memory r1, bool ok2, bytes memory r2) = _both(cd);
        assertTrue(ok1 && ok2, "both must succeed");
        assertEq(r1, r2);
        assertEq(abi.decode(r1, (uint256)), clean, "padding reached the digest");
    }
}
