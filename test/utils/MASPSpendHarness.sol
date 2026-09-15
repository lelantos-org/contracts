// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { uniformBps } from "./FeeArrays.sol";
import { deployBehindProxy, poolInitCalldata } from "./PoolDeployer.sol";

/// Test-only subclass that seeds commitment-tree state (root and
/// committedCount) directly, bypassing `deposit` and `flushBatch`. Used by
/// spend suites such as `MASP.transferSnark.t.sol` to verify the spend-side
/// Groth16 pair against a pre-populated tree. The pool is deployable only
/// behind a proxy, so this takes no constructor arguments;
/// `deploySpendHarness` initializes it behind one.
contract MASPSpendHarness is MASP {
    /// Seeds the tree to a known root and committedCount without a proof.
    function seedRoot(bytes32 newRoot, uint64 inserted) external {
        _advanceRoot(newRoot, inserted, currentRoot());
    }
}

/// Deploys `MASPSpendHarness` behind the standard test proxy, at zero fees.
function deploySpendHarness(
    IVerifier treeUpdateBatchVerifier_,
    IBatchVerifier batchVerifier_,
    ISignatureTransfer permit2_,
    uint64[] memory ids,
    IERC20[] memory tokens,
    uint256[] memory scales,
    address treasury_,
    address owner_
) returns (MASPSpendHarness) {
    MASPSpendHarness impl = new MASPSpendHarness();
    bytes memory initData = poolInitCalldata(
        treeUpdateBatchVerifier_,
        batchVerifier_,
        permit2_,
        ids,
        tokens,
        scales,
        uniformBps(ids.length, 0),
        uniformBps(ids.length, 0),
        treasury_,
        owner_
    );
    return MASPSpendHarness(deployBehindProxy(address(impl), initData));
}
