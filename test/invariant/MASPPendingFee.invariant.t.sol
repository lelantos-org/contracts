// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { FeeMath } from "../utils/FeeMath.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { EscrowHandlerBase, EscrowInvariantTestBase } from "./EscrowHandlerBase.sol";

/// Handler exercises deposit / flushBatch / cancelDeposit / sweep
/// randomly. Fees accrue only at flush; the handler shadows both the
/// escrowed totals of still-pending deposits and the expected `accruedFee`
/// so the invariants can assert solvency and accrual timing exactly.
///
/// A deposit pays its relayer note either in the deposit token or in a second
/// registered token (`FEE_ASSET_ID`, under its own `scale`). Solvency is
/// shadowed per token, so a note pulled, refunded or backed in the wrong token
/// breaks one side of the books.
contract EscrowFeeHandler is EscrowHandlerBase {
    MockERC20 public feeToken;

    uint64 public constant FEE_ASSET_ID = 2;
    uint256 public constant FEE_SCALE = 1e6;

    /// Token amount backing each deposit's relayer fee note. Distinct from
    /// `feeAt`: this one never accrues, it becomes shielded principal.
    mapping(uint256 => uint256) public relayerFeeAt;
    mapping(uint256 => uint64) public relayerFeeIn;
    /// id → the asset the relayer note is paid in: `ASSET_ID` or `FEE_ASSET_ID`.
    mapping(uint256 => uint64) public relayerFeeAsset;
    /// id → still pending?
    mapping(uint256 => bool) public pending;
    /// id → the block the escrow digest binds as `submittedAt`.
    mapping(uint256 => uint32) public preimageSubmittedAt;
    /// Sum of `inAmt + fee + relayerFee` for pending ids; escrowed balance not
    /// yet in `accruedFee`.
    uint256 public expectedPendingTotal;
    /// Mirrors masp.accruedFee(token): += fee at flush, reset by sweep.
    uint256 public expectedAccrued;
    /// Sum of principals and relayer fees for flushed ids (held in the pool as
    /// shielded value).
    uint256 public shieldedPrincipal;
    /// The same two books in `feeToken`, which only relayer notes paid in
    /// `FEE_ASSET_ID` fill. Nothing in `feeToken` ever accrues.
    uint256 public expectedPendingFeeToken;
    uint256 public shieldedFeeToken;

    constructor(MASP m, address p2, MockERC20 t, MockERC20 ft, address payer_) EscrowHandlerBase(m, p2, t, payer_) {
        feeToken = ft;
    }

    /// Handler: submit a fresh deposit.
    function submit(uint64 publicIn, uint64 feeIn, bool crossAsset) external {
        publicIn = uint64(bound(publicIn, 1, 1_000));
        // Non-zero: a zero-value fee note would let solvency hold regardless of
        // how the relayer's leg is accounted.
        feeIn = uint64(bound(feeIn, 1, 100));

        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = FeeMath.fee(inAmt, FEE_BPS);
        uint64 feeAsset = crossAsset ? FEE_ASSET_ID : ASSET_ID;
        uint256 relayerFee = uint256(feeIn) * (crossAsset ? FEE_SCALE : SCALE);
        if (crossAsset) {
            token.mint(payer, inAmt + fee);
            feeToken.mint(payer, relayerFee);
        } else {
            token.mint(payer, inAmt + fee + relayerFee);
        }
        vm.startPrank(payer);
        token.approve(address(permit2), type(uint256).max);
        feeToken.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        PubInputs.DepositRequest memory d = _request(publicIn);
        d.feeIn = feeIn;
        d.feeAssetId = feeAsset;

        uint256 id = _escrow(d, crossAsset ? type(uint256).max : 0, inAmt, fee);
        relayerFeeAt[id] = relayerFee;
        relayerFeeIn[id] = feeIn;
        relayerFeeAsset[id] = feeAsset;
        pending[id] = true;
        // forge-lint: disable-next-line(unsafe-typecast)
        preimageSubmittedAt[id] = uint32(block.number);
        if (crossAsset) {
            expectedPendingTotal += inAmt + fee;
            expectedPendingFeeToken += relayerFee;
        } else {
            expectedPendingTotal += inAmt + fee + relayerFee;
        }
    }

    /// Relayer note value owed in `token` and in `feeToken` for `id`.
    function _relayerSplit(uint256 id) internal view returns (uint256 inToken, uint256 inFeeToken) {
        if (relayerFeeAsset[id] == FEE_ASSET_ID) return (0, relayerFeeAt[id]);
        return (relayerFeeAt[id], 0);
    }

    function _isPending(uint256 id) internal view override returns (bool) {
        return pending[id];
    }

    function _submittedAt(uint256 id) internal view override returns (uint32) {
        return preimageSubmittedAt[id];
    }

    /// Arbitrary; the SNARK is mocked.
    function _newRoot(uint256) internal view override returns (bytes32) {
        return bytes32(uint256(masp.committedCount()) + 1);
    }

    /// The note as escrowed. A zero-value note declares asset 0:
    /// `tree_update_batch.circom` step 6a canonicalises the asset of a leaf
    /// whose Pedersen binding cannot see it, and `_drainDeposit` requires the
    /// match.
    function _feeLeaf(uint256 id) internal view override returns (uint64 assetId, uint64 feeIn) {
        return (relayerFeeIn[id] == 0 ? 0 : relayerFeeAsset[id], relayerFeeIn[id]);
    }

    function _onFlushed(uint256 id, bytes32) internal override {
        pending[id] = false;
        (uint256 rTok, uint256 rFee) = _relayerSplit(id);
        expectedPendingTotal -= principalAt[id] + feeAt[id] + rTok;
        expectedPendingFeeToken -= rFee;
        // The relayer's note is principal, not an accrual: the pool must keep
        // holding the tokens behind it, in the token it was paid in, or the
        // note is unspendable.
        shieldedPrincipal += principalAt[id] + rTok;
        shieldedFeeToken += rFee;
        expectedAccrued += feeAt[id];
    }

    function _onCancelled(uint256 id) internal override {
        pending[id] = false;
        (uint256 rTok, uint256 rFee) = _relayerSplit(id);
        expectedPendingTotal -= principalAt[id] + feeAt[id] + rTok;
        expectedPendingFeeToken -= rFee;
    }

    function _afterSweep() internal override {
        expectedAccrued = 0;
        // Nothing accrues in the fee token, so its sweep moves nothing.
        masp.sweep(IERC20(address(feeToken)));
    }
}

contract MASPEscrowFeeInvariantTest is EscrowInvariantTestBase {
    MockERC20 feeToken;
    EscrowFeeHandler handler;

    function setUp() public {
        _setUpPool();

        handler = new EscrowFeeHandler(masp, permit2, token, feeToken, payer);
        _targetHandler(handler, handler.submit.selector);
    }

    /// The relayer fee token, registered as asset 2 under its own scale. Here
    /// rather than after `_setUpPool` so its address is unchanged.
    function _afterPoolDeployed() internal override {
        feeToken = new MockERC20("F", "F", 6);
        masp.addAsset(2, IERC20(address(feeToken)), 1e6, TestConstants.FEE_BPS, TestConstants.FEE_BPS);
    }

    /// Solvency: the pool balance equals every still-escrowed total
    /// (principal + fee + relayer fee, not in `accruedFee` until flush), every
    /// flushed principal including relayer fee notes, and the fee claimable by
    /// sweep. Sweep never touches escrowed funds.
    function invariant_solvency() public view {
        uint256 bal = token.balanceOf(address(masp));
        uint256 owed =
            handler.expectedPendingTotal() + handler.shieldedPrincipal() + masp.accruedFee(IERC20(address(token)));
        assertEq(bal, owed, "pool balance covers escrow + shielded + claimable fee");
    }

    /// Solvency in the relayer fee token: the pool holds exactly the notes paid
    /// in it, pending or flushed, and nothing of it accrues.
    function invariant_solvencyFeeToken() public view {
        assertEq(
            feeToken.balanceOf(address(masp)),
            handler.expectedPendingFeeToken() + handler.shieldedFeeToken(),
            "pool balance covers fee-token notes, pending and shielded"
        );
        assertEq(masp.accruedFee(IERC20(address(feeToken))), 0, "fee token never accrues");
    }

    /// Accrual timing: `accruedFee` moves only at flush (up by the deposit's
    /// submit-time fee) and at sweep (to zero). Submit and cancel do not
    /// touch it.
    function invariant_accrualOnlyAtFlush() public view {
        assertEq(masp.accruedFee(IERC20(address(token))), handler.expectedAccrued(), "accruedFee drift");
    }
}
