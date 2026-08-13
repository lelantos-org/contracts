// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";

/// Test-only subclass exposing internal entrypoints so invariant handlers can
/// drive state transitions without going through the SNARK pipeline. The full
/// `transact` flow requires valid Groth16 proofs, which Foundry cannot
/// synthesize; this harness exercises the storage layer in isolation.
contract MASPHarness is MASP {
    constructor(IVerifier v, IVerifier tub, ISignatureTransfer permit2_, address treasury_, address owner_)
        MASP(v, tub, permit2_, new uint64[](0), new IERC20[](0), new uint256[](0), 0, treasury_, owner_)
    { }

    function consumeNullifierExternal(bytes32 nf) external {
        _consumeNullifier(nf);
    }
}
