// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { SnarkCompression } from "../../src/SnarkCompression.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { FeeMath } from "../utils/FeeMath.sol";
import { EscrowHandlerBase, EscrowInvariantTestBase } from "./EscrowHandlerBase.sol";

/// Whole-flow invariant for the MASP deposit / batch / cancel / sweep
/// state machine. The per-slice invariants
/// ([MASPPendingFee.invariant.t.sol](MASPPendingFee.invariant.t.sol),
/// [MASPNullifier.invariant.t.sol](MASPNullifier.invariant.t.sol),
/// [MASPAssets.invariant.t.sol](MASPAssets.invariant.t.sol)) each cover
/// one surface. This file exercises submit / flushBatch / cancelDeposit /
/// sweep / advance jointly and asserts cross-handler bookkeeping:
/// lifecycle exclusivity, conservation of `token.balanceOf(masp)`, root
/// coherence, and cancel-delay timing.
///
/// The tree-update SNARK verifier is stubbed with `vm.mockCall` (as in
/// `MASPEscrowFeeInvariantTest.setUp`), since otherwise every `flushBatch`
/// needs a real depth-10 proof. With the stub, flush reduces to the
/// state-machine logic these cross-handler invariants cover.
contract MaspFlowHandler is EscrowHandlerBase {
    enum Status {
        Unknown,
        Pending,
        Flushed,
        Cancelled
    }

    mapping(uint256 => Status) public status;
    /// Submit block per id: the `submittedAt` the escrow digest binds, and the
    /// origin of the cancel-delay check.
    mapping(uint256 => uint256) public submitBlock;

    /// Sum of principals for ids still `Pending`.
    uint256 public ghostPendingPrincipal;
    /// Sum of fees escrowed with ids still `Pending`. Not part of `accruedFee`
    /// until flush.
    uint256 public ghostPendingFee;
    /// Sum of principals for ids that have been `Flushed` (shielded).
    uint256 public ghostShieldedPrincipal;
    /// Most recent root pushed by `flushBatch`: the expected `currentRoot()`.
    /// Initialized to genesis in test setUp.
    bytes32 public lastNewRoot;
    /// Sum of `inserted` across all `flushBatch` calls (i.e. `2 * #flushed`).
    uint64 public ghostInserted;
    /// Number of `flushBatch` calls that landed (handler success counter).
    uint256 public flushCount;
    /// Number of `cancelDeposit` calls that landed.
    uint256 public cancelCount;

    constructor(MASP m, address p2, MockERC20 t, address payer_, bytes32 genesis) EscrowHandlerBase(m, p2, t, payer_) {
        lastNewRoot = genesis;
    }

    function submit(uint64 publicIn) external {
        publicIn = uint64(bound(publicIn, 1, 1_000));

        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = FeeMath.fee(inAmt, FEE_BPS);
        token.mint(payer, inAmt + fee);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);

        // The zero-value relayer note escrows as (0, `DepositFixture.FEE_CM`,
        // [0, 0]); `flushOne` and `cancelOne` resupply it through the default
        // `_feeLeaf`.
        uint256 id = _escrow(_request(publicIn), 0, inAmt, fee);
        status[id] = Status.Pending;
        submitBlock[id] = block.number;
        ghostPendingPrincipal += inAmt;
        ghostPendingFee += fee;
    }

    function idsLen() external view returns (uint256) {
        return allIds.length;
    }

    function _isPending(uint256 id) internal view override returns (bool) {
        return status[id] == Status.Pending;
    }

    function _submittedAt(uint256 id) internal view override returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(submitBlock[id]);
    }

    /// Distinct per (id, block). Reduced mod R because `flushBatch` compresses
    /// the batch header through `SnarkCompression.evaluatePolyAt`, which
    /// rejects any coefficient >= R. An unreduced keccak exceeds the BN254
    /// scalar field most of the time and would make flush revert for a reason
    /// unrelated to the state machine under test.
    function _newRoot(uint256 id) internal view override returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode("flushed", id, block.number))) % SnarkCompression.R);
    }

    function _onFlushed(uint256 id, bytes32 newRoot) internal override {
        status[id] = Status.Flushed;
        ghostPendingPrincipal -= principalAt[id];
        ghostPendingFee -= feeAt[id];
        ghostShieldedPrincipal += principalAt[id];
        lastNewRoot = newRoot;
        ghostInserted += uint64(PubInputs.LEAVES_PER_DEPOSIT);
        flushCount += 1;
    }

    function _onCancelled(uint256 id) internal override {
        // Cancel-delay check: at least cancelDelay blocks have passed since
        // submit. Holds by construction via the roll in `cancelOne`.
        require(block.number >= submitBlock[id] + masp.cancelDelay(), "cancel before delay");

        status[id] = Status.Cancelled;
        ghostPendingPrincipal -= principalAt[id];
        ghostPendingFee -= feeAt[id];
        cancelCount += 1;
    }
}

contract MaspFlowInvariantTest is EscrowInvariantTestBase {
    MaspFlowHandler handler;

    function setUp() public {
        _setUpPool();

        handler = new MaspFlowHandler(masp, permit2, token, payer, masp.currentRoot());
        _targetHandler(handler, handler.submit.selector);
    }

    /// Conservation: pool balance equals the pending principal + pending
    /// fees still in escrow (not in `accruedFee` until flush) + the
    /// shielded principal locked behind flushed deposits + the on-chain
    /// `accruedFee`. Sweep moves fees out, so accruedFee shrinks in
    /// lockstep with the balance.
    function invariant_balanceConservation() public view {
        uint256 bal = token.balanceOf(address(masp));
        uint256 expected = handler.ghostPendingPrincipal() + handler.ghostPendingFee()
            + handler.ghostShieldedPrincipal() + masp.accruedFee(IERC20(address(token)));
        assertEq(bal, expected, "balance conservation");
    }

    /// Lifecycle exclusivity: every submitted id sits in exactly one of
    /// {Pending, Flushed, Cancelled}, and the Flushed / Cancelled bucket sizes
    /// match the successful flush / cancel counts.
    function invariant_lifecycleExclusivity() public view {
        uint256 n = handler.idsLen();
        uint256 pending;
        uint256 flushed;
        uint256 cancelled;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.allIds(i);
            MaspFlowHandler.Status s = handler.status(id);
            if (s == MaspFlowHandler.Status.Pending) pending++;
            else if (s == MaspFlowHandler.Status.Flushed) flushed++;
            else if (s == MaspFlowHandler.Status.Cancelled) cancelled++;
            else revert("id with Unknown status");
        }
        assertEq(pending + flushed + cancelled, n, "lifecycle bucket sum");
        assertEq(handler.flushCount(), flushed, "flushCount matches Flushed bucket");
        assertEq(handler.cancelCount(), cancelled, "cancelCount matches Cancelled bucket");
    }

    /// Root coherence:
    ///   - `currentRoot()` equals the most recent `newRoot` written by
    ///     a successful `flushBatch` (or genesis if no flush yet);
    ///   - the live root is always `isKnownRoot == true`;
    ///   - `committedCount` equals 2 · #flushed (single-pair flushes).
    function invariant_rootCoherence() public view {
        assertEq(masp.currentRoot(), handler.lastNewRoot(), "currentRoot drift");
        assertTrue(masp.isKnownRoot(masp.currentRoot()), "currentRoot not known");
        assertEq(masp.committedCount(), handler.ghostInserted(), "committedCount delta");
    }

    /// Every handler path lands at least once.
    ///
    /// With `fail_on_revert = false` a handler call that always reverts rolls
    /// back its ghost updates without trace, and invariants over those ghosts
    /// (e.g. `invariant_rootCoherence` against `ghostInserted`) then hold
    /// vacuously. The invariant runner cannot distinguish a hard-to-reach path
    /// from an unreachable one, so reachability is checked here directly.
    ///
    /// Mirrors `YieldSolvencyInvariantTest.test_handlerReachesEveryPath`.
    function test_handlerReachesEveryPath() public {
        handler.submit(100);
        handler.submit(200);
        assertEq(handler.idsLen(), 2, "submit path");

        handler.flushOne(0);
        assertEq(handler.flushCount(), 1, "flush path");
        // The flush inserts both the principal leaf and the fee-note leaf.
        assertEq(masp.committedCount(), uint64(PubInputs.LEAVES_PER_DEPOSIT), "flush inserted both leaves");

        handler.cancelOne(0);
        assertEq(handler.cancelCount(), 1, "cancel path");

        handler.sweep();
        handler.advanceBlocks(10);
    }
}
