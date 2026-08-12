// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { PubInputs } from "../libs/PubInputs.sol";
import { AuxValidation } from "../libs/AuxValidation.sol";

/// Minimal MASP surface used by `SwapWrapper`.
interface IMASPSwap {
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
    function submitIntentAuthorized(PubInputs.DepositIntent calldata d, AuxValidation.Output calldata aux)
        external
        returns (uint256 id);
}
