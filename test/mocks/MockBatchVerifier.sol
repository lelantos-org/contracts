// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";

/// Stand-in for `BatchedGroth16Verifier` in tests that are not about pairing.
///
/// Must implement `IBatchVerifier`: `MASP`'s constructor probes the spend
/// verifier by calling `verifyBatch`, and an address without that function
/// reverts the deployment.
///
/// Set the answer with `setResult` rather than `vm.mockCall`. A blanket mock on
/// this selector also intercepts the constructor probe of any `MASP` deployed
/// later in the same test.
contract MockBatchVerifier is IBatchVerifier {
    /// Answer returned for every instance.
    bool public result;

    function setResult(bool result_) external {
        result = result_;
    }

    /// @inheritdoc IBatchVerifier
    function verifyBatch(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[2] calldata,
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[2] calldata
    ) external view returns (bool) {
        return result;
    }
}
