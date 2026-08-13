// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { PubInputs } from "../libs/PubInputs.sol";
import { AuxValidation } from "../libs/AuxValidation.sol";

/// Minimal MASP surface used by `NativeAdapter`.
interface IMASPNative {
    struct Proof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
    }

    function withdraw(
        Proof calldata p,
        PubInputs.Transact calldata pi,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[3] calldata aux
    ) external;

    /// A deposit occupies one leaf, hence a single aux payload.
    function depositAuthorized(PubInputs.DepositRequest calldata d, AuxValidation.Output calldata aux)
        external
        returns (uint256 id);

    function cancelDeposit(
        uint256 id,
        uint48 publicIn,
        bytes32 cm,
        uint256[2] calldata cvDep,
        uint64 publicAssetId,
        uint16 fbps,
        address payer,
        uint32 submittedAt
    ) external;

    /// Per-deposit escrow digest; zero once flushed or canceled.
    function escrowed(uint256 id) external view returns (bytes32);
}
