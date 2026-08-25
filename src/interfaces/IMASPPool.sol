// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PubInputs } from "../libs/PubInputs.sol";
import { AuxValidation } from "../libs/AuxValidation.sol";

/// The MASP surface the adapters call.
///
/// One interface, not one per adapter. `NativeAdapter` and `SwapWrapper` need
/// exactly the same four functions, and for as long as each kept its own
/// hand-written copy the two were free to disagree — which they did: the swap
/// copy was left on the pre-fee-note `cancelDeposit`, and because a stale
/// interface is a wrong selector at runtime rather than a build failure,
/// `SwapWrapper.cancelEscrow` compiled cleanly while being unable to dispatch
/// against the deployed pool at all.
///
/// Solidity still cannot check a hand-written interface against the contract it
/// describes, so a single copy only narrows the exposure. `IMASPPoolTest` pins
/// every selector below against `MASP`'s, which closes it: a signature that
/// moves in one place and not the other fails the suite instead of the deploy.
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
        AuxValidation.Output[4] calldata aux
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
