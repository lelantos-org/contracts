// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { PubInputs } from "../libs/PubInputs.sol";
import { AuxValidation } from "../libs/AuxValidation.sol";

/// The MASP surface the adapters call.
///
/// `NativeAdapter` and `SwapWrapper` require the same four functions and share
/// this declaration. Solidity does not check a hand-written interface against
/// the contract it describes, and a mismatched signature is a wrong selector at
/// runtime rather than a compile error, so `IMASPPoolTest` pins every selector
/// below against `MASP`'s: a signature that changes in one place and not the
/// other fails the test suite.
interface IMASPPool {
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
        AuxValidation.Output[6] calldata aux
    ) external;

    /// A deposit occupies two leaves — the depositor's note and the note paying
    /// whoever flushes it — hence two aux payloads.
    function depositAuthorized(
        PubInputs.DepositRequest calldata d,
        AuxValidation.Output calldata aux,
        AuxValidation.Output calldata feeAux
    ) external returns (uint256 id);

    /// `feeNote` is the relayer leaf's half of the escrow digest preimage. A
    /// canceller reads it from the deposit's `DepositEscrowed` event; the pool
    /// rejects any other value.
    function cancelDeposit(
        uint256 id,
        uint48 publicIn,
        bytes32 cm,
        uint256[2] calldata cvDep,
        uint64 publicAssetId,
        uint16 fbps,
        address payer,
        uint32 submittedAt,
        PubInputs.FeeNote calldata feeNote
    ) external;

    /// Per-deposit escrow digest; zero once flushed or canceled.
    function escrowed(uint256 id) external view returns (bytes32);
}
