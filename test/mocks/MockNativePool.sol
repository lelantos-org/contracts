// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockWETH9 } from "./MockWETH9.sol";

/// Misbehaving `IMASPPool` for `NativeAdapter` guard coverage. Real MASP
/// cannot produce these responses — a deposit always pulls, and a cancel
/// always refunds the full escrowed total — so the adapter's guards against
/// them are only reachable through a stand-in pool.
contract MockNativePool is IMASPPool {
    IAllowanceTransfer public immutable PERMIT2;
    MockWETH9 public immutable WETH;

    /// Wrapped coin pulled by the next `depositAuthorized`; 0 pulls nothing.
    uint160 public pullAmount;
    /// Wrapped coin returned by the next `cancelDeposit`.
    uint256 public refundAmount;
    /// What `escrowed` reports, i.e. whether the pool leg looks open.
    bytes32 public escrowDigest = bytes32(uint256(0xE5C0));

    uint256 public nextId;

    constructor(IAllowanceTransfer permit2, MockWETH9 weth) {
        PERMIT2 = permit2;
        WETH = weth;
    }

    function setPullAmount(uint160 v) external {
        pullAmount = v;
    }

    function setRefundAmount(uint256 v) external {
        refundAmount = v;
    }

    function setEscrowDigest(bytes32 v) external {
        escrowDigest = v;
    }

    function escrowed(uint256) external view returns (bytes32) {
        return escrowDigest;
    }

    function depositAuthorized(
        PubInputs.DepositRequest calldata,
        AuxValidation.Output calldata,
        AuxValidation.Output calldata
    ) external returns (uint256 id) {
        if (pullAmount != 0) {
            PERMIT2.transferFrom(msg.sender, address(this), pullAmount, address(WETH));
        }
        id = nextId++;
    }

    function cancelDeposit(
        uint256,
        uint48,
        bytes32,
        uint256[2] calldata,
        uint64,
        uint16,
        address payer,
        uint32,
        PubInputs.FeeNote calldata
    ) external {
        if (refundAmount != 0) WETH.transfer(payer, refundAmount);
    }

    function withdraw(
        Proof calldata,
        PubInputs.Transact calldata,
        Proof calldata,
        PubInputs.TreeUpdateBatch calldata,
        AuxValidation.Output[4] calldata
    ) external { }
}
