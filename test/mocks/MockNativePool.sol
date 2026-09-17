// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockWETH9 } from "./MockWETH9.sol";

/// Misbehaving `IMASPPool` for `NativeAdapter` guard coverage. MASP cannot
/// produce these responses (a deposit always pulls, and a cancel delivers exactly
/// the refund it returns), so the adapter's guards against them are reachable
/// only through a stand-in pool.
contract MockNativePool is IMASPPool {
    IAllowanceTransfer public immutable PERMIT2;
    MockWETH9 public immutable WETH;

    /// Wrapped coin pulled by the next `depositAuthorized`; 0 pulls nothing.
    uint160 public pullAmount;
    /// Wrapped coin returned by the next `cancelDeposit`.
    uint256 public refundAmount;
    /// Refund `cancelDeposit` reports paying, when `reportOverridden` is set.
    /// Otherwise it reports `refundAmount`, what it actually transfers.
    uint256 public reportedAmount;
    bool public reportOverridden;
    /// Second-token refund `cancelDeposit` reports, which MASP pays only for a
    /// relayer note in another asset. Nothing is transferred for it.
    uint256 public feeRefundedReport;
    /// What `escrowed` reports, i.e. whether the pool leg looks open.
    bytes32 public escrowDigest = bytes32(uint256(0xE5C0));

    uint256 public nextId;

    /// The native adapter never asks; no asset here carries a venue.
    function isYieldAsset(uint64) external pure returns (bool) {
        return false;
    }

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

    /// Makes `cancelDeposit` report `v` regardless of what it transfers.
    function setReportedAmount(uint256 v) external {
        reportedAmount = v;
        reportOverridden = true;
    }

    function setFeeRefundedReport(uint256 v) external {
        feeRefundedReport = v;
    }

    function setEscrowDigest(bytes32 v) external {
        escrowDigest = v;
    }

    function asset(uint64) external pure returns (AssetEntry memory a) { }

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
    ) external returns (uint256 total, uint256 feeRefunded) {
        if (refundAmount != 0) WETH.transfer(payer, refundAmount);
        feeRefunded = feeRefundedReport;
        total = reportOverridden ? reportedAmount : refundAmount;
    }

    function withdraw(
        Proof calldata,
        PubInputs.Transact calldata,
        Proof calldata,
        PubInputs.SpendTree calldata,
        AuxValidation.Output[6] calldata
    ) external { }
}
