// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

// Indices into the `[y, digest, z]` triple that `PubInputs` returns and the
// verifiers take as public signals.
uint256 constant Y = 0;
uint256 constant DIGEST = 1;
uint256 constant Z = 2;

/// Exposes `PubInputs` compression across an external call boundary, so the
/// `calldata` fast paths read real calldata, as they do under `MASP`.
contract CompressHarness {
    function transact(PubInputs.Transact calldata pi, AuxValidation.Output[6] calldata aux)
        external
        pure
        returns (uint256[3] memory)
    {
        return PubInputs.compress(pi, aux);
    }

    /// The memory reference path, behind the calldata-to-memory decode.
    function transactRef(PubInputs.Transact calldata pi, AuxValidation.Output[6] calldata aux)
        external
        pure
        returns (uint256[3] memory)
    {
        PubInputs.Transact memory m = pi;
        return PubInputs.compressRef(m, aux);
    }

    function batch(PubInputs.TreeUpdateBatch calldata tpi) external pure returns (uint256[3] memory) {
        return PubInputs.compress(tpi);
    }

    /// The memory reference path, behind the calldata-to-memory decode.
    function batchRef(PubInputs.TreeUpdateBatch calldata tpi) external pure returns (uint256[3] memory) {
        PubInputs.TreeUpdateBatch memory m = tpi;
        return PubInputs.compressRef(m);
    }

    function spend(PubInputs.Transact calldata pi, PubInputs.SpendTree calldata st, bytes32 oldRoot)
        external
        pure
        returns (uint256[3] memory)
    {
        return PubInputs.compressSpend(pi, st, oldRoot);
    }

    function auxDigest(AuxValidation.Output[6] calldata aux) external pure returns (uint256) {
        return PubInputs.auxDigest(aux);
    }
}
