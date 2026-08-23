// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";

/// Test-only subclass that lets a test seed the commitment-tree state
/// directly (root + committedCount) without going through the
/// `deposit` + `flushBatch` chain. Used by `MASP.transferSnark.t.sol`
/// to verify the spend-side Groth16 pair against a pre-populated tree.
contract MASPSpendHarness is MASP {
    constructor(
        IVerifier treeUpdateBatchVerifier_,
        IBatchVerifier batchVerifier_,
        ISignatureTransfer permit2_,
        uint64[] memory ids,
        IERC20[] memory tokens,
        uint256[] memory scales,
        address treasury_,
        address owner_
    ) MASP(treeUpdateBatchVerifier_, batchVerifier_, permit2_, ids, tokens, scales, 0, treasury_, owner_) { }

    /// Seed the tree to a known root + committedCount without proof.
    function seedRoot(bytes32 newRoot, uint64 inserted) external {
        _advanceRoot(newRoot, inserted, currentRoot());
    }
}
