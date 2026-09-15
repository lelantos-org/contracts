// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IVerifier } from "../../src/interfaces/IVerifier.sol";

/// Stand-in for `TreeUpdateBatchGroth16Verifier` in suites that reach
/// `flushBatch` but are not about the pairing check.
///
/// Foundry suites achieve the same with `Stubs.acceptTreeUpdateProofs`, which
/// uses `vm.mockCall`. Echidna runs on hevm, which has no `mockCall`, so the
/// stub is a contract implementing the interface. `MASP.initialize` rejects a
/// verifier without code, so the tree-update slot must hold a callable contract
/// in either case. `MockBatchVerifier` serves the spend leg.
///
/// Answers `result` for every proof. Settable so a suite can drive the
/// rejection branch, matching `acceptTreeUpdateProofs(tub, false)`.
contract MockTreeUpdateVerifier is IVerifier {
    /// Answer returned for every proof.
    bool public result;

    constructor(bool result_) {
        result = result_;
    }

    function setResult(bool result_) external {
        result = result_;
    }

    /// @inheritdoc IVerifier
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[2] calldata)
        external
        view
        returns (bool)
    {
        return result;
    }
}
