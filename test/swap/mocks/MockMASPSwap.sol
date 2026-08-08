// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { IMASPSwap } from "../../../src/swap/IMASPSwap.sol";
import { PubInputs } from "../../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../../src/libs/AuxValidation.sol";

/// Test-only MASP stub. Skips Groth16 verification and tree mutation,
/// reproducing only the side effects `SwapWrapper` orchestrates against:
///   - `withdraw` pushes `nextWithdrawAmount` NET of the configured `feeBps`
///     (mirroring MASP's unshield fee) to `pi.recipient` (= the wrapper).
///   - `submitIntentAuthorized` pulls `intent.publicIn * scale + fee` of
///     the configured token from `intent.payer` via Permit2.
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
    /// Fee bps applied at intent submit, mirroring MASP's `_computeAmounts`.
    uint16 public feeBps;

    /// Gross token-A amount for the next `withdraw`; the mock pushes this
    /// value net of `feeBps`. Lets tests decouple from `pi.publicOut` for
    /// forced-revert scenarios while still modeling the unshield fee.
    uint256 public nextWithdrawAmount;

    /// Sequential id returned to the wrapper by `submitIntentAuthorized`.
    uint256 public nextIntentId;

    /// Last intent seen by `submitIntentAuthorized`, for binding assertions.
    address public lastIntentRecipient;
    uint64 public lastIntentAssetId;
    uint64 public lastIntentPublicIn;

    event MockWithdraw(address indexed recipient, address token, uint256 amount);
    event MockIntent(uint256 indexed id, address indexed payer, address token, uint256 pulled);

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
        AuxValidation.Output[2] calldata
    ) external {
        address token = assetToken[pi.publicAssetId];
        // Net the unshield fee on the gross amount, mirroring MASP's
        // `_unshieldLeg`. The wrapper only ever receives the net.
        uint256 gross = nextWithdrawAmount;
        uint256 net = gross - (gross * feeBps) / 10_000;
        IERC20(token).transfer(pi.recipient, net);
        emit MockWithdraw(pi.recipient, token, net);
    }

    function submitIntentAuthorized(PubInputs.DepositIntent calldata d, AuxValidation.Output[2] calldata)
        external
        returns (uint256 id)
    {
        require(msg.sender == d.payer, "MockMASPSwap: sender != payer");
        lastIntentRecipient = d.recipient;
        lastIntentAssetId = d.publicAssetId;
        lastIntentPublicIn = d.publicIn;
        address token = assetToken[d.publicAssetId];
        uint256 scale = assetScale[d.publicAssetId];
        uint256 inAmt = uint256(d.publicIn) * scale;
        uint256 fee = (inAmt * feeBps) / 10_000;
        uint256 total = inAmt + fee;
        IAllowanceTransfer(address(PERMIT2)).transferFrom(d.payer, address(this), uint160(total), token);

        // Match MASP's `id = nextIntentId++` — first id is 0.
        id = nextIntentId++;
        emit MockIntent(id, d.payer, token, total);
    }
}
