// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { IMASPSwap } from "../../../src/swap/IMASPSwap.sol";
import { PubInputs } from "../../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../../src/libs/AuxValidation.sol";

/// Test-only MASP stub. Skips Groth16 verification and tree mutation,
/// reproducing only the side effects `SwapWrapper` orchestrates against:
///   - `withdraw` pushes `nextWithdrawAmount` NET of the configured `feeBps`
///     (mirroring MASP's unshield fee) to `pi.recipient` (= the wrapper).
///   - `depositAuthorized` pulls `d.publicIn * scale + fee` of
///     the configured token from `d.payer` via Permit2.
///
/// The harness is responsible for pre-funding the mock with token A so
/// `withdraw` has something to push, and for registering the per-asset
/// scale + token mapping it expects.
contract MockMASPSwap is IMASPSwap {
    IAllowanceTransfer public immutable PERMIT2;

    /// assetId ⇒ ERC20 token address.
    mapping(uint64 assetId => address token) public assetToken;
    /// assetId ⇒ scale factor (real-units per public-units).
    mapping(uint64 assetId => uint256 scale) public assetScale;
    /// Fee bps applied at deposit submit, mirroring MASP's `_computeAmounts`.
    uint16 public feeBps;

    /// Gross token-A amount for the next `withdraw`; the mock pushes this
    /// value net of `feeBps`. Lets tests decouple from `pi.publicOut` for
    /// forced-revert scenarios while still modeling the unshield fee.
    uint256 public nextWithdrawAmount;

    /// Sequential id returned to the wrapper by `depositAuthorized`.
    uint256 public nextDepositId;

    /// Last deposit seen by `depositAuthorized`, for binding assertions.
    address public lastDepositRecipient;
    uint64 public lastDepositAssetId;
    uint64 public lastDepositPublicIn;

    /// depositId ⇒ what a cancel would refund; zeroed on cancel, mirroring
    /// MASP's `escrowed` sentinel.
    mapping(uint256 id => uint256 total) public escrowTotal;
    mapping(uint256 id => address token) public escrowToken;

    event MockWithdraw(address indexed recipient, address token, uint256 amount);
    event MockDeposit(uint256 indexed id, address indexed payer, address token, uint256 pulled);

    constructor(IAllowanceTransfer permit2_) {
        PERMIT2 = permit2_;
    }

    function registerAsset(uint64 assetId, address token, uint256 scale) external {
        assetToken[assetId] = token;
        assetScale[assetId] = scale;
    }

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function setNextWithdrawAmount(uint256 v) external {
        nextWithdrawAmount = v;
    }

    function withdraw(
        Proof calldata,
        PubInputs.Transact calldata pi,
        Proof calldata,
        PubInputs.TreeUpdateBatch calldata,
        AuxValidation.Output[3] calldata
    ) external {
        address token = assetToken[pi.publicAssetId];
        // Net the unshield fee on the gross amount, mirroring MASP's
        // `_unshieldLeg`. The wrapper only ever receives the net.
        uint256 gross = nextWithdrawAmount;
        uint256 net = gross - (gross * feeBps) / 10_000;
        IERC20(token).transfer(pi.recipient, net);
        emit MockWithdraw(pi.recipient, token, net);
    }

    function depositAuthorized(PubInputs.DepositRequest calldata d, AuxValidation.Output calldata)
        external
        returns (uint256 id)
    {
        require(msg.sender == d.payer, "MockMASPSwap: sender != payer");
        lastDepositRecipient = d.recipient;
        lastDepositAssetId = d.publicAssetId;
        lastDepositPublicIn = d.publicIn;
        address token = assetToken[d.publicAssetId];
        uint256 scale = assetScale[d.publicAssetId];
        uint256 inAmt = uint256(d.publicIn) * scale;
        uint256 fee = (inAmt * feeBps) / 10_000;
        uint256 total = inAmt + fee;
        IAllowanceTransfer(address(PERMIT2)).transferFrom(d.payer, address(this), uint160(total), token);

        // Match MASP's `id = nextDepositId++` — first id is 0.
        id = nextDepositId++;
        escrowTotal[id] = total;
        escrowToken[id] = token;
        emit MockDeposit(id, d.payer, token, total);
    }

    /// Clear an escrow without refunding, as `flushBatch` does.
    function simulateFlush(uint256 id) external {
        delete escrowTotal[id];
    }

    /// Refund this much less than escrowed on the next cancel, to exercise the
    /// wrapper's delta check against a misbehaving pool.
    uint256 public refundShortfall;

    function setRefundShortfall(uint256 v) external {
        refundShortfall = v;
    }

    function escrowed(uint256 id) external view returns (bytes32) {
        return escrowTotal[id] == 0 ? bytes32(0) : bytes32(id + 1);
    }

    /// Refunds the escrowed total to `payer`, as MASP does. The digest and
    /// delay checks are the pool's business, not the wrapper's, so the stub
    /// skips them.
    function cancelDeposit(uint256 id, uint48, bytes32, uint256[2] calldata, uint64, uint16, address payer, uint32)
        external
    {
        uint256 total = escrowTotal[id];
        require(total != 0, "MockMASPSwap: not pending");
        require(msg.sender == payer, "MockMASPSwap: sender != payer");
        delete escrowTotal[id];
        IERC20(escrowToken[id]).transfer(payer, total - refundShortfall);
    }
}
