// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IVerifier } from "../../src/interfaces/IVerifier.sol";

/// Stand-in for `TreeUpdateBatchGroth16Verifier` in suites that reach
/// `flushBatch` but are not about the pairing check.
///
/// The Foundry suites get the same effect from
/// `Stubs.acceptTreeUpdateProofs`, which routes through `vm.mockCall`. Echidna
/// runs on hevm, whose cheatcode set has no `mockCall`, so the stub has to be
/// a contract that genuinely implements the interface. Kept next to
/// `MockBatchVerifier`, which exists for the same reason on the spend leg:
/// `MASP.initialize` rejects a verifier without code, so the tree-update slot
/// must hold something callable either way.
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
