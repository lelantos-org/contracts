// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { GenericCallWrapper } from "../../src/generic/GenericCallWrapper.sol";
import { CallExecutor } from "../../src/generic/CallExecutor.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockMASPSwap } from "../swap/mocks/MockMASPSwap.sol";
import { GenericIntent } from "../generic/GenericIntent.sol";
import { MockRouter, MockDrainer, MockDonor } from "../generic/mocks/MockCallTargets.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";

/// Echidna target for `GenericCallWrapper`, also driven by
/// `test/invariant/GenericCallWrapper.invariant.t.sol`.
///
/// Each handler builds an execution of one shape (a swap, a split into several
/// outputs, an adversarial call), predicts its outcome from the stub pool's fee
/// arithmetic, runs it, and books what should have moved in ghost state. The
/// properties compare every balance the wrapper can touch against those books,
/// and latch a flag whenever an outcome differs from the prediction or a call
/// the wrapper must reject lands.
///
/// No cheatcodes: hevm lacks most of Foundry's. The target is `pi_w.payer`, so
/// it drives every execution itself, and the next executor's address is derived
/// from the wrapper's CREATE nonce, tracked as a ghost and checked against the
/// clone each landed execution leaves behind.
///
/// Native coin is not modelled; the unit tests cover the unwrap path.
contract EchidnaGenericCall {
    uint64 internal constant ASSET_A = 1;
    uint64 internal constant ASSET_B = 2;
    uint64 internal constant ASSET_C = 3;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant REFUND_TO = address(0x4EF0);
    address internal constant SURPLUS_TO = address(0x5A5A);
    address internal constant RECIPIENT = address(0xBEEF);

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockMASPSwap public pool;
    GenericCallWrapper public wrapper;
    MockRouter internal router;
    MockDrainer public drainer;
    MockDonor internal donor;

    enum Status {
        Unknown,
        Pending,
        Flushed,
        Cancelled
    }

    struct Escrow {
        MockERC20 token;
        uint64 assetId;
        uint64 units;
        uint256 amount;
        Status status;
    }

    /// Every escrow the wrapper created, indexed by pool deposit id.
    Escrow[] internal escrowLog;
    /// Every clone a landed execution created.
    address[] internal executors;
    /// The wrapper's CREATE nonce: 1 at deployment, 2 after its implementation.
    uint256 internal wrapperNonce = 2;

    /// Expected balances, per token, of the addresses the wrapper pays.
    mapping(MockERC20 => uint256) internal ghostPool;
    mapping(MockERC20 => uint256) internal ghostSurplus;
    mapping(MockERC20 => uint256) internal ghostRefunded;
    /// Tokens donated straight to the wrapper, which must stay there untouched.
    mapping(MockERC20 => uint256) internal ghostStuck;
    /// B minted to a clone address whose execution then refunded. The address
    /// is reused by the next landed execution, which sweeps it to `surplusTo`.
    mapping(address => uint256) internal ghostStrandedAt;

    /// Latched violations. Never cleared.
    bool internal outcomeMismatch;
    bool internal unexpectedRevert;
    bool internal tamperAccepted;
    bool internal strangerAccepted;
    bool internal oversizedAccepted;
    bool internal settledCancelAccepted;
    bool internal executorMismatch;

    /// Landed-path counters, gated by `EchidnaGenericCallReachability.t.sol`.
    uint256 public successCount;
    uint256 public refundCount;
    uint256 public splitCount;
    uint256 public cancelCount;
    uint256 public flushCount;
    uint256 public tamperAttempts;
    uint256 public strangerAttempts;
    uint256 public oversizedAttempts;
    uint256 public settledCancelAttempts;
    uint256 public drainAttempts;
    uint256 public hookDrainRefunds;

    constructor() {
        IAllowanceTransfer permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenC = new MockERC20("C", "C", 18);

        pool = new MockMASPSwap(permit2);
        pool.registerAsset(ASSET_A, address(tokenA), SCALE);
        pool.registerAsset(ASSET_B, address(tokenB), SCALE);
        pool.registerAsset(ASSET_C, address(tokenC), SCALE);
        pool.setFeeBps(FEE_BPS);

        wrapper = new GenericCallWrapper(pool, permit2);
        wrapper.prepareToken(IERC20(address(tokenA)));
        wrapper.prepareToken(IERC20(address(tokenB)));
        wrapper.prepareToken(IERC20(address(tokenC)));

        router = new MockRouter();
        drainer = new MockDrainer();
        donor = new MockDonor();
    }

    // =====================================================================
    // Handlers
    // =====================================================================

    /// The variants of `swap`. The first group lands the calls, the second
    /// refunds them (see `_refunds`).
    enum SwapMode {
        Honest,
        /// Half the input stays unspent and goes to `surplusTo`.
        UnusedInput,
        /// A donation reaches the wrapper during the calls.
        DonationMidLeg,
        /// Tokens are sent to the clone's address before it exists.
        PrefundedExecutor,
        /// The calls leave an approval to the drainer behind.
        StaleApproval,
        // --- refunds ---
        Shortfall,
        FailingCall,
        Expired,
        DeniedTarget,
        /// A call hands control to the drainer, which pulls from this clone.
        HookDrain
    }

    uint8 internal constant SWAP_MODE_COUNT = uint8(type(SwapMode).max) + 1;

    /// Everything one `swap` decides before running, kept together so the
    /// build, run and booking steps read from one place.
    struct SwapPlan {
        SwapMode mode;
        uint64 withdrawUnits;
        uint256 received;
        /// Input the router consumes.
        uint256 used;
        uint64 outUnits;
        /// What the router mints of B.
        uint256 delivered;
        /// Donated or prefunded B, for the modes that use it.
        uint256 extra;
        address executor;
    }

    /// One swap-shaped execution of A into B, in the variant `modeSeed` picks.
    function swap(uint16 withdrawSeed, uint16 outSeed, uint64 cushionSeed, uint8 modeSeed, uint64 extraSeed) external {
        SwapPlan memory plan = _planSwap(withdrawSeed, outSeed, cushionSeed, modeSeed, extraSeed);
        if (plan.mode == SwapMode.PrefundedExecutor) tokenB.mint(plan.executor, plan.extra);

        (bool ok, bool landed) = _executeAndObserve(_swapArgs(plan), plan.executor);
        if (!ok) return;
        if (landed == _refunds(plan.mode)) {
            outcomeMismatch = true;
            return;
        }
        landed ? _bookLandedSwap(plan) : _bookRefundedSwap(plan);
    }

    /// Half the input into B and C, the other half back as a note of A: three
    /// outputs, the input token among them.
    function split(uint16 withdrawSeed, uint16 bSeed, uint16 cSeed, uint64 cushionSeed) external {
        uint64 w = _boundUnits(withdrawSeed, 100, 1_000);
        uint256 received = _fund(w);
        uint256 half = received / 2;
        uint64 bUnits = _boundUnits(bSeed, 1, 100_000);
        uint64 cUnits = _boundUnits(cSeed, 1, 100_000);
        uint256 cushion = _bound(cushionSeed, 0, 1e12);
        // Half of what comes back of A, so its note is always covered.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 aUnits = uint64((received - half) / SCALE / 2);

        GenericCallWrapper.GenericArgs memory a = _base(w);
        a.calls = new CallExecutor.Call[](2);
        a.calls[0] = _approveRouter(half);
        a.calls[1] = _call(
            address(router),
            abi.encodeCall(
                MockRouter.split,
                (address(tokenA), half, address(tokenB), _pull(bUnits), address(tokenC), _pull(cUnits) + cushion)
            )
        );
        a.outputs = new GenericCallWrapper.Output[](3);
        a.outputs[0] = _output(ASSET_B, bUnits);
        a.outputs[1] = _output(ASSET_C, cUnits);
        a.outputs[2] = _output(ASSET_A, aUnits);

        (bool ok, bool landed) = _executeAndObserve(a, _nextExecutor());
        if (!ok) return;
        if (!landed) {
            outcomeMismatch = true;
            return;
        }
        _bookEscrow(tokenB, ASSET_B, bUnits);
        _bookEscrow(tokenC, ASSET_C, cUnits);
        _bookEscrow(tokenA, ASSET_A, aUnits);
        ghostSurplus[tokenC] += cushion;
        ghostSurplus[tokenA] += (received - half) - _pull(aUnits);
        ++successCount;
        ++splitCount;
    }

    /// Cancels a recorded escrow through the wrapper. A pending one must refund
    /// `refundTo` exactly; a settled one must be refused.
    function cancel(uint256 idx) external {
        if (escrowLog.length == 0) return;
        uint256 id = idx % escrowLog.length;
        Escrow storage e = escrowLog[id];
        bool settled = e.status != Status.Pending;
        if (settled) ++settledCancelAttempts;

        PubInputs.FeeNote memory feeNote;
        // Units are bounded to 1e6 by every handler that books an escrow.
        // forge-lint: disable-next-line(unsafe-typecast)
        try wrapper.cancelEscrow(id, uint48(e.units), bytes32(0), [uint256(0), 0], e.assetId, 0, 0, feeNote) {
            if (settled) {
                settledCancelAccepted = true;
                return;
            }
            e.status = Status.Cancelled;
            ghostPool[e.token] -= e.amount;
            ghostRefunded[e.token] += e.amount;
            ++cancelCount;
        } catch {
            if (!settled) unexpectedRevert = true;
        }
    }

    /// Settles a pending escrow as a flush would, without moving tokens.
    function flush(uint256 idx) external {
        if (escrowLog.length == 0) return;
        uint256 id = idx % escrowLog.length;
        if (escrowLog[id].status != Status.Pending) return;
        pool.simulateFlush(id);
        escrowLog[id].status = Status.Flushed;
        ++flushCount;
    }

    /// Donates B straight to the wrapper, outside any execution.
    function donate(uint64 amountSeed) external {
        uint256 amount = _bound(amountSeed, 1, 1e14);
        tokenB.mint(address(wrapper), amount);
        ghostStuck[tokenB] += amount;
    }

    /// The drainer pulls from every clone it may hold an approval on. Clones
    /// hold nothing after their execution, so nothing moves.
    function drainPast(uint8 tokenSeed) external {
        MockERC20 token = [tokenA, tokenB, tokenC][tokenSeed % 3];
        for (uint256 i; i < executors.length; ++i) {
            try drainer.drain(IERC20(address(token)), executors[i]) { } catch { }
            ++drainAttempts;
        }
    }

    /// A bound payload with one field changed afterwards must be refused.
    function tamper(uint16 withdrawSeed, uint8 fieldSeed) external {
        GenericCallWrapper.GenericArgs memory a = GenericIntent.bind(_refusedSwap(withdrawSeed));
        uint8 field = fieldSeed % 8;
        if (field == 0) a.refundTo = address(0xBAD);
        else if (field == 1) a.surplusTo = address(0xBAD);
        else if (field == 2) a.deadline -= 1;
        else if (field == 3) a.minGas = 1;
        else if (field == 4) a.outputs[0].minOut -= 1;
        else if (field == 5) a.outputs[0].deposit.recipient = address(0xBAD);
        else if (field == 6) a.calls[1].data[a.calls[1].data.length - 1] ^= 0x01;
        else a.refund_d.publicIn -= 1;

        ++tamperAttempts;
        if (_lands(a)) tamperAccepted = true;
    }

    /// A proof naming another payer must be refused from this caller.
    function stranger(uint16 withdrawSeed, address payer) external {
        if (payer == address(this)) return;
        GenericCallWrapper.GenericArgs memory a = _refusedSwap(withdrawSeed);
        a.pi_w.payer = payer;

        ++strangerAttempts;
        if (_lands(GenericIntent.bind(a))) strangerAccepted = true;
    }

    /// A note larger than the calls deliver must be refused rather than funded
    /// from balances already on the wrapper.
    function oversized(uint16 withdrawSeed, uint16 overSeed) external {
        GenericCallWrapper.GenericArgs memory a = _refusedSwap(withdrawSeed);
        a.outputs[0].deposit.publicIn += _boundUnits(overSeed, 1, 1_000);

        ++oversizedAttempts;
        if (_lands(GenericIntent.bind(a))) oversizedAccepted = true;
    }

    // =====================================================================
    // Properties
    // =====================================================================

    /// The pool holds exactly the notes escrowed, net of cancels, plus
    /// withdraw fees and refused-call funding.
    function echidna_poolBalancesMatch() public view returns (bool) {
        return _balanceIs(tokenA, address(pool), ghostPool[tokenA])
            && _balanceIs(tokenB, address(pool), ghostPool[tokenB])
            && _balanceIs(tokenC, address(pool), ghostPool[tokenC]);
    }

    /// `surplusTo` received exactly the cushions, unused input and donations.
    function echidna_surplusMatches() public view returns (bool) {
        return _balanceIs(tokenA, SURPLUS_TO, ghostSurplus[tokenA])
            && _balanceIs(tokenB, SURPLUS_TO, ghostSurplus[tokenB])
            && _balanceIs(tokenC, SURPLUS_TO, ghostSurplus[tokenC]);
    }

    /// `refundTo` received exactly what cancelled escrows held.
    function echidna_refundsMatch() public view returns (bool) {
        return _balanceIs(tokenA, REFUND_TO, ghostRefunded[tokenA])
            && _balanceIs(tokenB, REFUND_TO, ghostRefunded[tokenB])
            && _balanceIs(tokenC, REFUND_TO, ghostRefunded[tokenC]);
    }

    /// The wrapper keeps nothing between executions but what was donated to it,
    /// and none of that is ever spent.
    function echidna_wrapperHoldsOnlyDonations() public view returns (bool) {
        return _balanceIs(tokenA, address(wrapper), 0) && _balanceIs(tokenB, address(wrapper), ghostStuck[tokenB])
            && _balanceIs(tokenC, address(wrapper), 0);
    }

    /// Every clone is empty after its execution, and nothing was drained from one.
    function echidna_executorsEmpty() public view returns (bool) {
        for (uint256 i; i < executors.length; ++i) {
            address e = executors[i];
            if (tokenA.balanceOf(e) != 0 || tokenB.balanceOf(e) != 0 || tokenC.balanceOf(e) != 0) return false;
        }
        return tokenA.balanceOf(address(drainer)) == 0 && tokenB.balanceOf(address(drainer)) == 0
            && tokenC.balanceOf(address(drainer)) == 0;
    }

    /// Every pending escrow's record names `refundTo` and the amount the pool holds.
    function echidna_escrowRecordsMatchPool() public view returns (bool) {
        for (uint256 id; id < escrowLog.length; ++id) {
            (address refundTo, uint256 amount) = wrapper.escrows(id);
            Status s = escrowLog[id].status;
            if (s == Status.Pending) {
                if (refundTo != REFUND_TO || amount != escrowLog[id].amount) return false;
                if (pool.escrowTotal(id) != amount) return false;
            } else if (s == Status.Cancelled) {
                if (refundTo != address(0) || pool.escrowTotal(id) != 0) return false;
            }
        }
        return true;
    }

    /// Each execution landed or refunded as predicted, and never reverted.
    function echidna_outcomesAsPredicted() public view returns (bool) {
        return !outcomeMismatch && !unexpectedRevert && !executorMismatch;
    }

    /// No tampered intent, lifted proof, oversized note or settled cancel landed.
    function echidna_guardsHold() public view returns (bool) {
        return !tamperAccepted && !strangerAccepted && !oversizedAccepted && !settledCancelAccepted;
    }

    // --- optimization ---------------------------------------------------

    /// How far the wrapper's balances drift above what was donated to it.
    function optimize_wrapperResidue() public view returns (int256) {
        return int256(tokenA.balanceOf(address(wrapper)) + tokenC.balanceOf(address(wrapper)))
            + int256(tokenB.balanceOf(address(wrapper))) - int256(ghostStuck[tokenB]);
    }

    /// How much `surplusTo` received beyond the books.
    function optimize_surplusDrift() public view returns (int256) {
        return (int256(tokenA.balanceOf(SURPLUS_TO)) - int256(ghostSurplus[tokenA]))
            + (int256(tokenB.balanceOf(SURPLUS_TO)) - int256(ghostSurplus[tokenB]))
            + (int256(tokenC.balanceOf(SURPLUS_TO)) - int256(ghostSurplus[tokenC]));
    }

    // =====================================================================
    // Swap planning and booking
    // =====================================================================

    function _planSwap(uint16 withdrawSeed, uint16 outSeed, uint64 cushionSeed, uint8 modeSeed, uint64 extraSeed)
        internal
        returns (SwapPlan memory plan)
    {
        plan.mode = SwapMode(modeSeed % SWAP_MODE_COUNT);
        plan.withdrawUnits = _boundUnits(withdrawSeed, 10, 1_000);
        plan.received = _fund(plan.withdrawUnits);
        plan.used = plan.mode == SwapMode.UnusedInput ? plan.received / 2 : plan.received;
        plan.outUnits = _boundUnits(outSeed, 1, 1_000_000);
        plan.delivered = plan.mode == SwapMode.Shortfall
            ? uint256(plan.outUnits) * SCALE - 1
            : _pull(plan.outUnits) + _bound(cushionSeed, 0, 1e14);
        plan.extra = _bound(extraSeed, 1, 1e14);
        plan.executor = _nextExecutor();
    }

    function _swapArgs(SwapPlan memory plan) internal view returns (GenericCallWrapper.GenericArgs memory a) {
        a = _base(plan.withdrawUnits);
        if (plan.mode == SwapMode.Expired) a.deadline = block.timestamp - 1;
        a.calls = new CallExecutor.Call[](3);
        a.calls[0] = _approveRouter(plan.used);
        a.calls[1] = _call(
            address(router),
            abi.encodeCall(MockRouter.swap, (address(tokenA), address(tokenB), plan.used, plan.delivered))
        );
        a.calls[2] = _modeCall(plan);
        a.outputs = new GenericCallWrapper.Output[](1);
        a.outputs[0] = _output(ASSET_B, plan.outUnits);
    }

    /// The third call of a swap: the mode's own, or a harmless read.
    function _modeCall(SwapPlan memory plan) internal view returns (CallExecutor.Call memory) {
        SwapMode mode = plan.mode;
        if (mode == SwapMode.FailingCall) return _call(address(router), abi.encodeCall(MockRouter.fail, ()));
        if (mode == SwapMode.DeniedTarget) {
            return _call(address(pool), abi.encodeCall(IERC20.balanceOf, (address(this))));
        }
        if (mode == SwapMode.DonationMidLeg) {
            return
                _call(address(donor), abi.encodeCall(MockDonor.donate, (address(tokenB), address(wrapper), plan.extra)));
        }
        if (mode == SwapMode.HookDrain) {
            return _call(address(drainer), abi.encodeCall(MockDrainer.drain, (IERC20(address(tokenB)), plan.executor)));
        }
        if (mode == SwapMode.StaleApproval) {
            return _call(address(tokenB), abi.encodeCall(IERC20.approve, (address(drainer), type(uint256).max)));
        }
        return _call(address(tokenA), abi.encodeCall(IERC20.balanceOf, (address(this))));
    }

    function _refunds(SwapMode mode) internal pure returns (bool) {
        return mode >= SwapMode.Shortfall;
    }

    function _bookLandedSwap(SwapPlan memory plan) internal {
        _bookEscrow(tokenB, ASSET_B, plan.outUnits);
        uint256 donated =
            plan.mode == SwapMode.DonationMidLeg || plan.mode == SwapMode.PrefundedExecutor ? plan.extra : 0;
        ghostSurplus[tokenB] += plan.delivered - _pull(plan.outUnits) + donated;
        ghostSurplus[tokenA] += plan.received - plan.used;
        ++successCount;
    }

    function _bookRefundedSwap(SwapPlan memory plan) internal {
        uint64 units = _refundUnits(plan.withdrawUnits);
        _bookEscrow(tokenA, ASSET_A, units);
        ghostSurplus[tokenA] += plan.received - _pull(units);
        // The clone was never created, so the prefund waits for the next one.
        if (plan.mode == SwapMode.PrefundedExecutor) ghostStrandedAt[plan.executor] += plan.extra;
        if (plan.mode == SwapMode.HookDrain) ++hookDrainRefunds;
        ++refundCount;
    }

    function _bookEscrow(MockERC20 token, uint64 assetId, uint64 units) internal {
        uint256 amount = _pull(units);
        ghostPool[token] += amount;
        escrowLog.push(Escrow({ token: token, assetId: assetId, units: units, amount: amount, status: Status.Pending }));
    }

    // =====================================================================
    // Running
    // =====================================================================

    /// Executes `a` expecting it not to revert. `ok` is false, and the revert
    /// latched, if it did; `landed` is whether the calls landed, read from the
    /// clone they leave at `executor`.
    function _executeAndObserve(GenericCallWrapper.GenericArgs memory a, address executor)
        internal
        returns (bool ok, bool landed)
    {
        uint256 gross = uint256(a.pi_w.publicOut) * SCALE;
        try wrapper.execute(GenericIntent.bind(a)) returns (uint256[] memory) {
            // The pool keeps the unshield fee whether the calls land or refund.
            ghostPool[tokenA] += (gross * FEE_BPS) / 10_000;
            landed = executor.code.length != 0;
            if (landed) _recordExecutor(executor);
            return (true, landed);
        } catch {
            unexpectedRevert = true;
            ghostPool[tokenA] += gross;
            return (false, false);
        }
    }

    function _recordExecutor(address executor) internal {
        if (CallExecutor(payable(executor)).WRAPPER() != address(wrapper)) executorMismatch = true;
        executors.push(executor);
        ++wrapperNonce;
        // Whatever an earlier refunded execution left at this address is swept now.
        ghostSurplus[tokenB] += ghostStrandedAt[executor];
        ghostStrandedAt[executor] = 0;
    }

    /// Whether an execution that must be refused landed instead.
    function _lands(GenericCallWrapper.GenericArgs memory a) internal returns (bool) {
        try wrapper.execute(a) {
            return true;
        } catch {
            return false;
        }
    }

    /// An honest swap for the refusal handlers to break. Funds the pool, and books
    /// that funding as staying there, since the break must stop the withdraw.
    function _refusedSwap(uint16 withdrawSeed) internal returns (GenericCallWrapper.GenericArgs memory a) {
        uint64 w = _boundUnits(withdrawSeed, 10, 1_000);
        uint256 received = _fund(w);
        ghostPool[tokenA] += uint256(w) * SCALE;

        a = _base(w);
        a.calls = new CallExecutor.Call[](2);
        a.calls[0] = _approveRouter(received);
        a.calls[1] = _call(
            address(router), abi.encodeCall(MockRouter.swap, (address(tokenA), address(tokenB), received, _pull(100)))
        );
        a.outputs = new GenericCallWrapper.Output[](1);
        a.outputs[0] = _output(ASSET_B, 100);
    }

    /// Funds the stub pool for a withdraw of `w` units of A; returns the net.
    function _fund(uint64 w) internal returns (uint256 received) {
        uint256 gross = uint256(w) * SCALE;
        tokenA.mint(address(pool), gross);
        pool.setNextWithdrawAmount(gross);
        received = gross - (gross * FEE_BPS) / 10_000;
    }

    // =====================================================================
    // Payloads
    // =====================================================================

    function _base(uint64 w) internal view returns (GenericCallWrapper.GenericArgs memory a) {
        uint256 gross = uint256(w) * SCALE;
        a.amountIn = gross - (gross * FEE_BPS) / 10_000;
        a.deadline = type(uint256).max;
        a.refundTo = REFUND_TO;
        a.surplusTo = SURPLUS_TO;
        a.pi_w.publicAssetId = ASSET_A;
        a.pi_w.publicOut = w;
        a.pi_w.recipient = address(wrapper);
        a.pi_w.relayer = address(wrapper);
        a.pi_w.payer = address(this);
        a.refund_d = _request(ASSET_A, _refundUnits(w));
        a.refund_d.outCm = bytes32(uint256(2));
    }

    function _output(uint64 assetId, uint64 units) internal view returns (GenericCallWrapper.Output memory o) {
        o.minOut = uint256(units) * SCALE;
        o.deposit = _request(assetId, units);
    }

    function _request(uint64 assetId, uint64 units) internal view returns (PubInputs.DepositRequest memory d) {
        return DepositFixture.request(assetId, units, address(wrapper), RECIPIENT, bytes32(uint256(1)));
    }

    function _call(address target, bytes memory data) internal pure returns (CallExecutor.Call memory) {
        return CallExecutor.Call({ target: target, value: 0, data: data });
    }

    function _approveRouter(uint256 amount) internal view returns (CallExecutor.Call memory) {
        return _call(address(tokenA), abi.encodeCall(IERC20.approve, (address(router), amount)));
    }

    // =====================================================================
    // Arithmetic
    // =====================================================================

    /// The largest refund whose pull fits what a withdraw of `w` nets.
    function _refundUnits(uint64 w) internal pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64((uint256(w) * (10_000 - 2 * uint256(FEE_BPS))) / 10_000);
    }

    function _pull(uint64 units) internal pure returns (uint256) {
        uint256 inAmt = uint256(units) * SCALE;
        return inAmt + (inAmt * FEE_BPS) / 10_000;
    }

    /// The CREATE address for the wrapper's current nonce, RLP-encoded for
    /// nonces up to 0xffff.
    function _nextExecutor() internal view returns (address) {
        address w = address(wrapper);
        uint256 n = wrapperNonce;
        bytes memory rlp;
        // forge-lint: disable-start(unsafe-typecast)
        if (n < 0x80) rlp = abi.encodePacked(bytes1(0xd6), bytes1(0x94), w, uint8(n));
        else if (n < 0x100) rlp = abi.encodePacked(bytes1(0xd7), bytes1(0x94), w, bytes1(0x81), uint8(n));
        else rlp = abi.encodePacked(bytes1(0xd8), bytes1(0x94), w, bytes1(0x82), uint16(n));
        // forge-lint: disable-end(unsafe-typecast)
        return address(uint160(uint256(keccak256(rlp))));
    }

    function _balanceIs(MockERC20 token, address who, uint256 expected) internal view returns (bool) {
        return token.balanceOf(who) == expected;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function _boundUnits(uint256 x, uint64 lo, uint64 hi) internal pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(_bound(x, lo, hi));
    }
}
