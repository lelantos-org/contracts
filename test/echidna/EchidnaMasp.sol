// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { MockTreeUpdateVerifier } from "../mocks/MockTreeUpdateVerifier.sol";
import { EchidnaRoots } from "./EchidnaRoots.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import {
    newPoolImplementation,
    poolInitCalldata,
    singleAsset,
    TEST_MAX_PAUSE,
    TEST_UPGRADE_DELAY
} from "../utils/PoolDeployer.sol";
import { uniformBps } from "../utils/FeeArrays.sol";
import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { EchidnaMaspPayer } from "./EchidnaMaspPayer.sol";

import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

/// Echidna target for the MASP deposit / flush / cancel / sweep state machine.
///
/// Covers the same subject as `test/invariant/MASPPendingFee.invariant.t.sol`
/// and `test/invariant/MASP.flow.invariant.t.sol` with a different engine.
/// Foundry's invariant runner samples fresh call sequences each run; Echidna
/// mutates a corpus it keeps on disk across runs (`corpusDir`, emitted per
/// contract by `just _echidna-config`), so sequences that reached deep states
/// remain available as mutation bases. The properties restate the Foundry
/// ones; the persistent corpus is what this target adds.
///
/// Differences from the Foundry handlers, required by hevm's smaller cheatcode
/// set:
///
///  - The tree-update verifier is `MockTreeUpdateVerifier`, a real contract,
///    where the Foundry suites use `vm.mockCall`. hevm has no `mockCall`.
///  - The payer is `EchidnaMaspPayer`, a deployed contract that originates its
///    own calls, where the Foundry suites `vm.etch` a stub and `vm.prank` it.
///  - Block advancement comes from Echidna's per-call block delay rather than
///    a `vm.roll` past `cancelDelay`. The Foundry handlers roll past the delay
///    unconditionally, so every cancel succeeds and the `cancelDelay` guard is
///    never exercised; here the guard is live and Echidna must find the
///    timing. `maxBlockDelay` in `echidna.yaml` is sized against
///    `CANCEL_DELAY_DEFAULT` (7_200 blocks) to make that reachable.
///
/// Ghost bookkeeping is updated only after the pool call returns. A reverting
/// handler call rolls the whole transaction back, ghosts included, so a
/// rejected deposit or an early cancel cannot desynchronise the shadow state.
contract EchidnaMasp {
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;

    MASP public masp;
    /// The same contract as `masp`, at its proxy-side type: `pauseSpends` and
    /// the upgrade surface live on the proxy, not on the implementation ABI.
    DelayedUpgradeProxy public proxy;
    MockERC20 public token;
    EchidnaMaspPayer internal payer;
    address internal permit2;

    /// All deposit ids ever submitted, in submit order.
    uint256[] internal allIds;

    enum Status {
        Unknown,
        Pending,
        Flushed,
        Cancelled
    }

    mapping(uint256 => Status) internal status;
    /// id -> principal locked at submit (asset-units * scale).
    mapping(uint256 => uint256) internal principalAt;
    /// id -> protocol fee locked at submit.
    mapping(uint256 => uint256) internal feeAt;
    /// id -> token amount backing the relayer's fee note. Distinct from
    /// `feeAt`: this never accrues, it becomes shielded principal at flush.
    mapping(uint256 => uint256) internal relayerFeeAt;
    mapping(uint256 => uint64) internal relayerFeeIn;
    /// Off-chain preimage shadow. The escrow slot stores only a digest, so
    /// flush and cancel have to resupply every field it was built from.
    mapping(uint256 => uint48) internal preimagePublicIn;
    mapping(uint256 => bytes32) internal preimageCm0;
    mapping(uint256 => uint32) internal preimageSubmittedAt;

    /// Sum of `principal + fee + relayerFee` over ids still `Pending`.
    uint256 internal ghostPendingTotal;
    /// Sum of `principal + relayerFee` over ids that reached `Flushed`.
    uint256 internal ghostShieldedPrincipal;
    /// Mirrors `masp.accruedFee(token)`: += fee at flush and withdraw, zeroed
    /// by sweep.
    uint256 internal ghostAccrued;
    /// Most recent `newRoot` written by a landed flush, withdraw or transfer;
    /// genesis before the first.
    bytes32 internal ghostLastRoot;
    /// Leaves inserted by landed calls: `LEAVES_PER_DEPOSIT` per flushed
    /// deposit plus `TRANSACT_OUT` per withdraw or transfer.
    uint64 internal ghostInserted;

    /// Landed-call counters. Public because they are the only externally
    /// visible evidence that a handler reached the pool rather than one of its
    /// early returns; `EchidnaMaspReachability.t.sol` gates on them.
    uint256 public flushCount;
    uint256 public cancelCount;
    uint256 public submitCount;

    /// Negative-space violation flags. Each is set by a handler whose call the
    /// contract must reject but which succeeded. Flags latch and are never
    /// cleared, so a later well-behaved sequence cannot hide a breach.
    bool internal cancelDigestBreached;
    bool internal flushDigestBreached;
    bool internal earlyCancelAccepted;
    bool internal doubleDrainAccepted;
    bool internal payerGuardBreached;

    /// Attempt counters for the same handlers. An unset violation flag reads
    /// the same whether the guard held or the call was never reached; these
    /// distinguish the two, and `EchidnaMaspReachability.t.sol` gates on them.
    uint256 public cancelTamperAttempts;
    uint256 public flushTamperAttempts;
    uint256 public earlyCancelAttempts;
    uint256 public doubleDrainAttempts;
    uint256 public strangerCancelAttempts;

    /// Running total of everything `sweep` has moved to the treasury.
    uint256 internal ghostSwept;

    // --- withdraw leg ---

    /// Where every withdrawal is sent. Fixed so the recipient's balance is a
    /// running total that can be compared against the ghost.
    address internal constant RECIPIENT = address(0xbe11e);

    /// Gross withdrawn (`publicOut * SCALE`), summed. This is the amount
    /// removed from shielded principal; the pool's balance falls by the net
    /// and the difference stays behind as accrued fee.
    uint256 internal ghostWithdrawnGross;
    /// Net actually transferred to `RECIPIENT`, summed.
    uint256 internal ghostWithdrawnNet;
    /// Withdraw fees accrued, summed. Also folded into `ghostAccrued`.
    uint256 internal ghostWithdrawFees;

    /// Nullifiers consumed by a landed withdraw or transfer, and the set of
    /// them.
    bytes32[] internal spentNullifiers;
    mapping(bytes32 => bool) internal ghostSpent;

    /// Monotonic source of never-before-used nullifiers; see
    /// `_nextNullifierSeed`. Started high so it cannot collide with the small
    /// commitment seeds the deposit path uses.
    uint256 internal nullifierCursor = 1 << 128;

    uint256 public withdrawCount;

    /// Set if a `transfer` changed the pool's token balance. A shielded
    /// transfer must move no tokens.
    bool internal transferMovedTokens;
    uint256 public transferCount;

    /// Multi-deposit flush counters. `flushOne` passes a single id, so these
    /// track the n > 1 path through the `flushBatch` loop and its per-token fee
    /// accumulator.
    uint256 public batchFlushCount;
    /// Set if a batch naming the same deposit twice was accepted.
    bool internal duplicateIdAccepted;
    uint256 public duplicateIdAttempts;

    // --- root ring ---

    /// Mirrors `CommitmentTree.ROOT_HISTORY`, an `internal constant` that can be
    /// neither read nor imported from here. `EchidnaMaspReachability.t.sol`
    /// pins the two together by asserting that `roots(ROOT_HISTORY - 1)` reads
    /// and `roots(ROOT_HISTORY)` does not, so a ring-size change fails an
    /// assertion instead of leaving the eviction properties on the wrong slot.
    uint256 internal constant ROOT_HISTORY = 64;

    /// The most recently evicted roots, newest last, capped so the property
    /// that reads them does bounded work regardless of run length.
    ///
    /// `CommitmentTree` keeps `ROOT_HISTORY` roots in a ring, each push
    /// overwrites the oldest, and spends name their anchor by slot. These
    /// handlers push past the wrap at pool level, exercising the eviction
    /// branch and whether a spend can prove inclusion in a forgotten tree.
    uint256 internal constant EVICTED_TRACKED = 16;
    bytes32[EVICTED_TRACKED] internal evictedRoots;
    uint256 internal evictedCount;

    /// Set if a withdrawal against a root known to have been evicted landed.
    bool internal evictedRootAccepted;
    uint256 public evictedRootAttempts;

    // --- guardian pause ---

    /// Timestamp the single guardian pause runs until, 0 before it is used.
    /// `DelayedUpgradeProxy` allows exactly one pause until governance clears
    /// the flag, so this is set at most once.
    uint256 public pausedUntil;

    /// Set if a paused pool accepted a deposit or a spend.
    bool internal pausedDepositAccepted;
    bool internal pausedSpendAccepted;
    /// Set if a paused pool rejected a cancel it must honour: a pause must not
    /// trap escrowed funds.
    bool internal pausedCancelRejected;
    uint256 public pausedDepositAttempts;
    uint256 public pausedSpendAttempts;
    uint256 public pausedCancelAttempts;

    bool internal nullifierReuseAccepted;
    bool internal unknownRootAccepted;
    uint256 public nullifierReuseAttempts;
    uint256 public unknownRootAttempts;

    uint256 internal nonce;

    constructor() {
        ISignatureTransfer p2 = ISignatureTransfer(new DeployPermit2().deployPermit2());
        permit2 = address(p2);

        // Both verifier slots must hold code (`MASP.initialize` rejects a
        // codeless verifier) and both accept, because the subject is the state
        // machine, not the pairings.
        //
        // With the spend verifier accepting, the fuzzer supplies public inputs
        // a circuit would otherwise constrain, and could withdraw value no
        // deposit funded. Value conservation across a spend is the circuit's
        // invariant, not MASP's, and is not observable here. `withdrawOne`
        // therefore bounds itself to the shielded principal the ghost knows was
        // deposited, and the withdraw properties assert only what MASP owns:
        // nullifier uniqueness, root membership, and exact fee-split
        // arithmetic.
        IVerifier tub = IVerifier(address(new MockTreeUpdateVerifier(true)));
        MockBatchVerifier bv = new MockBatchVerifier();
        bv.setResult(true);

        token = new MockERC20("M", "M", 18);
        payer = new EchidnaMaspPayer();

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        // Deployed directly rather than through `deployPoolUniform`, which pins
        // the proxy admin to `TEST_PROXY_ADMIN`. The guardian pause is
        // `onlyAdmin` and Echidna cannot impersonate an address, so this
        // contract must be the admin to reach `pauseSpends`.
        proxy = DelayedUpgradeProxy(
            payable(address(
                    new DelayedUpgradeProxy(
                        address(newPoolImplementation()),
                        poolInitCalldata(
                            tub,
                            IBatchVerifier(address(bv)),
                            p2,
                            ids,
                            tokens,
                            scales,
                            uniformBps(ids.length, FEE_BPS),
                            uniformBps(ids.length, FEE_BPS),
                            address(0xfee),
                            address(this)
                        ),
                        address(this),
                        TEST_UPGRADE_DELAY,
                        TEST_MAX_PAUSE
                    )
                ))
        );
        masp = MASP(address(proxy));

        // One unlimited standing approval, granted by the payer itself, so
        // submits need no per-call approval.
        payer.exec(address(token), abi.encodeCall(IERC20.approve, (permit2, type(uint256).max)));

        ghostLastRoot = masp.currentRoot();
    }

    // -----------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------

    /// Submit a fresh deposit.
    ///
    /// `feeIn` is forced non-zero: a zero-value relayer note has no tokens
    /// behind it, so solvency would hold under any accounting of the split.
    function submit(uint64 publicInSeed, uint64 feeInSeed) public {
        uint64 publicIn = uint64(1 + (publicInSeed % 1_000));
        uint64 feeIn = uint64(1 + (feeInSeed % 100));

        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;
        uint256 relayerFee = uint256(feeIn) * SCALE;
        token.mint(address(payer), inAmt + fee + relayerFee);

        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = address(payer);
        d.recipient = address(0xb0b);
        d.outCm = bytes32(uint256(0x1000 + nonce));
        d.feeCm = bytes32(uint256(0xfee));
        d.feeIn = feeIn;
        d.feeAssetId = ASSET_ID;

        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: nonce++, deadline: type(uint256).max, maxTotal: type(uint256).max, maxFee: 0, signature: hex"00"
        });

        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        uint256 id = masp.deposit(d, sig, aux[0], aux[1]);

        allIds.push(id);
        status[id] = Status.Pending;
        principalAt[id] = inAmt;
        feeAt[id] = fee;
        relayerFeeAt[id] = relayerFee;
        relayerFeeIn[id] = feeIn;
        preimagePublicIn[id] = uint48(publicIn);
        preimageCm0[id] = d.outCm;
        preimageSubmittedAt[id] = uint32(block.number);
        ghostPendingTotal += inAmt + fee + relayerFee;
        submitCount += 1;
    }

    /// Flush one pending deposit through `flushBatch`.
    function flushOne(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        // Unconstrained (the SNARK is stubbed) but derived from live state, so
        // each flush publishes a distinct root. `EchidnaRoots.fresh` documents
        // the required field reduction.
        tpi.newRoot = EchidnaRoots.fresh(abi.encode("flushed", id, block.number));
        tpi.startIndex = masp.committedCount();
        // A deposit occupies LEAVES_PER_DEPOSIT (= 2) adjacent leaves: the
        // principal, then the note paying the flusher. `_validateBatchHeader`
        // requires `actualCount == n * LEAVES_PER_DEPOSIT` (else
        // `BatchMisaligned`) and `_drainDeposit` rebuilds the escrow digest
        // from leaf `p + 1`, so both leaves must be populated.
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        _fillDepositLeaves(tpi, 0, id);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: address(payer), submittedAt: preimageSubmittedAt[id], fbps: FEE_BPS });

        MASP.Proof memory proof;
        bytes32 willEvict = _pendingEviction();
        masp.flushBatch(ids, meta, proof, tpi);

        _recordEviction(willEvict, tpi.newRoot);
        _recordFlushed(id);
        ghostLastRoot = tpi.newRoot;
        ghostInserted += uint64(PubInputs.LEAVES_PER_DEPOSIT);
        flushCount += 1;
    }

    /// Cancel one pending deposit, refunding the payer.
    ///
    /// Does not roll past `cancelDelay`: the timing guard stays live, so an
    /// early call reverts and only cancels after the delay are counted.
    function cancelOne(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;
        _cancel(id);
    }

    /// The cancel itself, shared by `cancelOne` and `cancelAt` so the two
    /// cannot drift.
    function _cancel(uint256 id) internal {
        uint256[2] memory zCv;
        payer.exec(
            address(masp),
            abi.encodeCall(
                MASP.cancelDeposit,
                (
                    id,
                    preimagePublicIn[id],
                    preimageCm0[id],
                    zCv,
                    ASSET_ID,
                    FEE_BPS,
                    address(payer),
                    preimageSubmittedAt[id],
                    PubInputs.FeeNote({
                        feeIn: uint48(relayerFeeIn[id]),
                        feeAssetId: relayerFeeIn[id] == 0 ? 0 : ASSET_ID,
                        feeCm: bytes32(uint256(0xfee)),
                        feeCvDep: zCv
                    })
                )
            )
        );

        status[id] = Status.Cancelled;
        ghostPendingTotal -= principalAt[id] + feeAt[id] + relayerFeeAt[id];
        cancelCount += 1;
    }

    /// `cancelOne` for a caller that has already chosen the deposit.
    ///
    /// Public so `pausedCancelHonoured` can wrap it in try/catch, and by id so
    /// the deposit that caller verified is the one cancelled. `cancelOne`'s
    /// scan could select a different deposit and turn an unrelated rejection
    /// into a false trapped-refund report.
    function cancelAt(uint256 id) public {
        if (status[id] != Status.Pending) return;
        _cancel(id);
    }

    /// Drain accrued fees to the treasury.
    function sweep() public {
        uint256 before = masp.accruedFee(IERC20(address(token)));
        masp.sweep(IERC20(address(token)));
        ghostAccrued = 0;
        ghostSwept += before;
    }

    /// Write deposit `id`'s pair of leaves into batch slot `slot`.
    ///
    /// Deposit `i` owns leaves `2i` (principal) and `2i + 1` (the note paying
    /// the flusher), and `_drainDeposit` rebuilds the escrow digest from both.
    /// Shared so single- and multi-deposit batches are assembled identically.
    function _fillDepositLeaves(PubInputs.TreeUpdateBatch memory tpi, uint256 slot, uint256 id) internal view {
        uint256 pIdx = slot * PubInputs.LEAVES_PER_DEPOSIT;
        tpi.cms[pIdx] = preimageCm0[id];
        tpi.leafAsset[pIdx] = ASSET_ID;
        tpi.leafPublicIn[pIdx] = uint64(preimagePublicIn[id]);
        tpi.isDeposit[pIdx] = 1;
        tpi.cms[pIdx + 1] = bytes32(uint256(0xfee));
        // Zero-value leaves declare asset 0: `tree_update_batch.circom` step 6a
        // canonicalises the asset of a leaf whose Pedersen binding cannot see
        // it, and `_drainDeposit` requires the match.
        tpi.leafAsset[pIdx + 1] = relayerFeeIn[id] == 0 ? 0 : ASSET_ID;
        tpi.leafPublicIn[pIdx + 1] = relayerFeeIn[id];
        tpi.isDeposit[pIdx + 1] = 1;
    }

    /// Header shared by the multi-deposit flush handlers.
    function _batchHeader(uint256 nDeposits, uint256 salt)
        internal
        view
        returns (PubInputs.TreeUpdateBatch memory tpi)
    {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = EchidnaRoots.fresh(abi.encode("batch", salt, block.number));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(nDeposits * PubInputs.LEAVES_PER_DEPOSIT);
    }

    /// Flush two distinct pending deposits in one batch.
    ///
    /// Exercises the `flushBatch` loop at n > 1. Accrual is summed across the
    /// batch and settled once per token, a different code path from two
    /// single-deposit flushes.
    function flushMany(uint256 idxSeed) public {
        uint256 first = _firstWithStatus(idxSeed, Status.Pending);
        if (status[first] != Status.Pending) return;
        uint256 second = _nextPendingAfter(first, idxSeed);
        if (second == first || status[second] != Status.Pending) return;

        PubInputs.TreeUpdateBatch memory tpi = _batchHeader(2, first);
        _fillDepositLeaves(tpi, 0, first);
        _fillDepositLeaves(tpi, 1, second);

        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](2);
        meta[0] = MASP.DepositMeta({ payer: address(payer), submittedAt: preimageSubmittedAt[first], fbps: FEE_BPS });
        meta[1] = MASP.DepositMeta({ payer: address(payer), submittedAt: preimageSubmittedAt[second], fbps: FEE_BPS });

        MASP.Proof memory proof;
        bytes32 willEvict = _pendingEviction();
        masp.flushBatch(ids, meta, proof, tpi);

        _recordEviction(willEvict, tpi.newRoot);
        _recordFlushed(first);
        _recordFlushed(second);
        ghostLastRoot = tpi.newRoot;
        ghostInserted += uint64(2 * PubInputs.LEAVES_PER_DEPOSIT);
        flushCount += 2;
        batchFlushCount += 1;
    }

    /// Attempt a batch that names the same pending deposit twice.
    ///
    /// `_drainDeposit` clears `escrowed[id]` as it goes, and zero means
    /// "nothing pending", so the second slot must find the entry gone.
    /// Accepting it would mint two commitments and pay two relayer notes
    /// against one deposit. This is the drain-once rule within a single
    /// transaction; `drainTwice` covers it across transactions.
    function flushDuplicateId(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;

        PubInputs.TreeUpdateBatch memory tpi = _batchHeader(2, id);
        _fillDepositLeaves(tpi, 0, id);
        _fillDepositLeaves(tpi, 1, id);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](2);
        meta[0] = MASP.DepositMeta({ payer: address(payer), submittedAt: preimageSubmittedAt[id], fbps: FEE_BPS });
        meta[1] = meta[0];

        MASP.Proof memory proof;
        duplicateIdAttempts += 1;
        try masp.flushBatch(ids, meta, proof, tpi) {
            duplicateIdAccepted = true;
            // Keep the ghosts in step with the landed batch so the bookkeeping
            // properties do not fail for an unrelated reason.
            _recordFlushed(id);
            ghostLastRoot = tpi.newRoot;
            ghostInserted += uint64(2 * PubInputs.LEAVES_PER_DEPOSIT);
        } catch { }
    }

    /// Ghost updates for one deposit moving Pending -> Flushed.
    ///
    /// The relayer's note is principal, not an accrual: the pool must keep
    /// holding the tokens behind it or the note is unspendable. Only the
    /// protocol fee moves into `accruedFee`.
    function _recordFlushed(uint256 id) internal {
        status[id] = Status.Flushed;
        ghostPendingTotal -= principalAt[id] + feeAt[id] + relayerFeeAt[id];
        ghostShieldedPrincipal += principalAt[id] + relayerFeeAt[id];
        ghostAccrued += feeAt[id];
    }

    /// First pending id that is not `exclude`.
    function _nextPendingAfter(uint256 exclude, uint256 seed) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return type(uint256).max;
        uint256 start = seed % n;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = allIds[(start + k) % n];
            if (id != exclude && status[id] == Status.Pending) return id;
        }
        return exclude;
    }

    // -----------------------------------------------------------------------
    // Withdraw leg
    //
    // Fuzzes the real spend path (`withdraw`, `transfer`) against a pool whose
    // deposit history is itself fuzzed. The Foundry nullifier invariants drive
    // `MASPHarness.consumeNullifierExternal`, i.e. `NullifierSet` in isolation.
    // -----------------------------------------------------------------------

    /// Build the spend/tree-update pair for a withdrawal of `publicOut`.
    ///
    /// Shared so the spend handlers differ in exactly one field each, making a
    /// rejection attributable to the guard under test.
    function _spendRequest(uint64 publicOut, uint256 nfSeed, uint256 cmSeed)
        internal
        view
        returns (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi)
    {
        pi.merkleRoot = masp.currentRoot();
        pi.publicAssetId = ASSET_ID;
        pi.publicIn = 0; // `withdraw` reverts MustNotHaveDeposit otherwise
        pi.publicOut = publicOut;
        pi.recipient = RECIPIENT;
        pi.chainId = block.chainid;
        pi.payer = address(payer);
        pi.relayer = address(this); // _validateRequest pins relayer == msg.sender
        SpendFixture.fillOutputs(pi, nfSeed, cmSeed);

        tpi = SpendFixture.spendTree(
            EchidnaRoots.fresh(abi.encode("spent", nfSeed, block.number)),
            masp.committedCount(),
            uint8(masp.rootIndex())
        );
    }

    /// Shielded principal still available to withdraw.
    function _shieldedAvailable() internal view returns (uint256) {
        return ghostShieldedPrincipal - ghostWithdrawnGross;
    }

    /// A `publicOut` the pool can actually pay, or 0 when it can pay nothing.
    ///
    /// With the spend verifier stubbed to accept, an unbounded `publicOut`
    /// would drain escrowed deposits and `echidna_solvency` would report an
    /// insolvency caused by the stub rather than by MASP. Every withdrawing
    /// handler uses this bound.
    ///
    /// Zero signals "nothing to withdraw"; a valid amount is at least 1.
    function _boundedPublicOut(uint64 seed) internal view returns (uint64) {
        uint256 maxOut = _shieldedAvailable() / SCALE;
        if (maxOut == 0) return 0;
        if (maxOut > 1_000) maxOut = 1_000;
        return uint64(1 + (seed % maxOut));
    }

    /// The next block of `TRANSACT_IN` never-before-used nullifiers.
    ///
    /// `_validateRequest` rejects a repeat within one call and
    /// `_consumeNullifier` rejects one across calls, so the happy path uses a
    /// supply that is fresh by construction; fuzzer-chosen nullifiers would
    /// make landed spends rare. `withdrawReplay` drives reuse.
    function _nextNullifierSeed() internal returns (uint256 s) {
        s = nullifierCursor;
        nullifierCursor += PubInputs.TRANSACT_IN;
    }

    /// Withdraw shielded funds to `RECIPIENT`.
    ///
    /// Bounded by the shielded principal the ghost knows was deposited; see
    /// `_boundedPublicOut`.
    function withdrawOne(uint64 outSeed, uint256 cmSeed) public {
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) =
            _spendRequest(publicOut, _nextNullifierSeed(), cmSeed);

        uint256 outAmt = uint256(publicOut) * SCALE;
        uint256 fee = (outAmt * FEE_BPS) / 10_000;

        MASP.Proof memory p;
        MASP.Proof memory tp;
        bytes32 willEvict = _pendingEviction();
        masp.withdraw(p, pi, tp, tpi, SpendFixture.validAux());

        _recordEviction(willEvict, tpi.newRoot);

        for (uint256 k = 0; k < PubInputs.TRANSACT_IN; k++) {
            ghostSpent[pi.nullifier[k]] = true;
            spentNullifiers.push(pi.nullifier[k]);
        }
        ghostWithdrawnGross += outAmt;
        ghostWithdrawnNet += outAmt - fee;
        ghostWithdrawFees += fee;
        ghostAccrued += fee;
        ghostLastRoot = tpi.newRoot;
        ghostInserted += uint64(PubInputs.TRANSACT_OUT);
        withdrawCount += 1;
    }

    /// Shielded transfer: consume notes, mint notes, move no tokens.
    ///
    /// `transfer` takes the same proofs and tree update as `withdraw`, runs the
    /// same nullifier consumption and root advance, and must leave
    /// `balanceOf(masp)` unchanged. A per-call balance check attributes any
    /// token movement to this path, which a balance-sum property cannot.
    function transferShielded(uint256 cmSeed) public {
        // publicOut = 0 makes this a transfer; `_spendRequest` sets publicIn
        // to 0.
        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) = _spendRequest(0, _nextNullifierSeed(), cmSeed);

        uint256 balanceBefore = token.balanceOf(address(masp));

        MASP.Proof memory p;
        MASP.Proof memory tp;
        bytes32 willEvict = _pendingEviction();
        masp.transfer(p, pi, tp, tpi, SpendFixture.validAux());

        _recordEviction(willEvict, tpi.newRoot);
        if (token.balanceOf(address(masp)) != balanceBefore) transferMovedTokens = true;

        for (uint256 k = 0; k < PubInputs.TRANSACT_IN; k++) {
            ghostSpent[pi.nullifier[k]] = true;
            spentNullifiers.push(pi.nullifier[k]);
        }
        ghostLastRoot = tpi.newRoot;
        ghostInserted += uint64(PubInputs.TRANSACT_OUT);
        transferCount += 1;
    }

    /// Attempt a withdrawal that reuses a nullifier already consumed.
    ///
    /// Checks the double-spend guard on the real entrypoint, including
    /// everything `withdraw` does before reaching `_consumeNullifier`.
    function withdrawReplay(uint256 nfIdxSeed, uint64 outSeed, uint256 cmSeed) public {
        if (spentNullifiers.length == 0) return;
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) =
            _spendRequest(publicOut, _nextNullifierSeed(), cmSeed);

        // Exactly one slot is swapped for a spent nullifier and the rest stay
        // fresh, so only `DoubleSpend` can reject this, not the within-call
        // `DuplicateNullifier` check.
        pi.nullifier[nfIdxSeed % PubInputs.TRANSACT_IN] = spentNullifiers[nfIdxSeed % spentNullifiers.length];

        MASP.Proof memory p;
        MASP.Proof memory tp;
        nullifierReuseAttempts += 1;
        try masp.withdraw(p, pi, tp, tpi, SpendFixture.validAux()) {
            nullifierReuseAccepted = true;
        } catch { }
    }

    /// Attempt a withdrawal against a Merkle root the pool never committed.
    ///
    /// Root membership ties a spend to state the tree-update circuit produced.
    /// Accepting an unknown root would let a spend prove inclusion in a tree of
    /// the caller's own construction.
    function withdrawUnknownRoot(uint64 outSeed, uint256 cmSeed, uint256 rootSeed) public {
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) =
            _spendRequest(publicOut, _nextNullifierSeed(), cmSeed);

        bytes32 bogus = EchidnaRoots.fresh(abi.encode("unknown-root", rootSeed));
        if (masp.isKnownRoot(bogus)) return; // collision; skip rather than misreport
        pi.merkleRoot = bogus;
        // Any slot, in range or not: none holds the bogus root.
        tpi.anchorIndex = uint8(rootSeed >> 8);

        MASP.Proof memory p;
        MASP.Proof memory tp;
        unknownRootAttempts += 1;
        try masp.withdraw(p, pi, tp, tpi, SpendFixture.validAux()) {
            unknownRootAccepted = true;
        } catch { }
    }

    // -----------------------------------------------------------------------
    // Root ring
    // -----------------------------------------------------------------------

    /// The root the next push will displace, or zero if that slot is empty.
    ///
    /// Read before a root-advancing call so the eviction can be recorded
    /// afterwards. If the displaced entry equals the incoming root, the slot
    /// still holds that root after `CommitmentTree._advanceRoot` overwrites it,
    /// so callers compare against `newRoot` before recording.
    function _pendingEviction() internal view returns (bytes32) {
        uint32 next = uint32((uint256(masp.rootIndex()) + 1) & (ROOT_HISTORY - 1));
        return masp.roots(next);
    }

    /// Record a root the pool has just forgotten.
    ///
    /// Called from every root-advancing handler: both flush paths, withdraw
    /// and transfer. A missed call leaves the property sound but gives
    /// `withdrawEvictedRoot` fewer targets.
    ///
    /// Roots are keccak images reduced into the scalar field, so a root
    /// re-entering the ring after eviction is not handled; if it occurred, the
    /// result would be a false breach rather than a missed one.
    function _recordEviction(bytes32 evicted, bytes32 newRoot) internal {
        if (evicted == bytes32(0) || evicted == newRoot) return;
        evictedRoots[evictedCount % EVICTED_TRACKED] = evicted;
        evictedCount += 1;
    }

    /// Advance the root many times in one call.
    ///
    /// Reachability device. The ring holds 64 roots and evicts nothing until
    /// full, so the eviction properties need 64+ landed root advances within a
    /// single sequence (Echidna resets state between sequences). Spread across
    /// the handler set at `seqLen: 400`, individual advances rarely reach the
    /// wrap; looping brings it within a few calls.
    ///
    /// Uses transfers because they need neither a pending deposit nor shielded
    /// funds, so they do not early-return for reasons unrelated to the ring.
    function churnRoots(uint8 nSeed, uint256 cmSeed) public {
        uint256 n = 1 + (uint256(nSeed) % 16);
        for (uint256 i = 0; i < n; i++) {
            transferShielded(cmSeed + i);
        }
    }

    /// Attempt a withdrawal proving inclusion in a root the ring has evicted.
    ///
    /// Distinct from `withdrawUnknownRoot`, which uses a root that was never
    /// committed. An evicted root was valid pool state, which makes it the
    /// harder case for a stale-root check.
    function withdrawEvictedRoot(uint64 outSeed, uint256 cmSeed, uint256 pickSeed) public {
        if (evictedCount == 0) return;
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        uint256 tracked = evictedCount < EVICTED_TRACKED ? evictedCount : EVICTED_TRACKED;
        bytes32 stale = evictedRoots[pickSeed % tracked];

        (PubInputs.Transact memory pi, PubInputs.SpendTree memory tpi) =
            _spendRequest(publicOut, _nextNullifierSeed(), cmSeed);
        pi.merkleRoot = stale;
        // Any slot, including the one the root was evicted from.
        tpi.anchorIndex = uint8(pickSeed >> 8);

        MASP.Proof memory p;
        MASP.Proof memory tp;
        evictedRootAttempts += 1;
        try masp.withdraw(p, pi, tp, tpi, SpendFixture.validAux()) {
            evictedRootAccepted = true;
        } catch { }
    }

    // -----------------------------------------------------------------------
    // Guardian pause
    //
    // `whenNotPaused` guards five entry points (withdraw, transfer, deposit,
    // depositAuthorized, flushBatch) and not `cancelDeposit` or `sweep`, so
    // escrowed funds stay recoverable. Property: a pause stops the pool taking
    // on or settling obligations without trapping funds already in escrow.
    // -----------------------------------------------------------------------

    /// Trip the guardian pause. Reachable once: the proxy sets
    /// `guardianPauseUsed` and refuses a second pause until governance clears
    /// it.
    ///
    /// The duration (60_000s to 199_999s) is sized against `maxTimeDelay`
    /// (15_000s) in `echidna.yaml`: the pause spans several calls, so a block
    /// delay can cross the 7_200-block cancel delay while it is live, as
    /// `pausedCancelHonoured` requires. It stays well under `MAX_PAUSE`
    /// (7 days), which would outlast the sequence and freeze other handlers.
    function pauseSpends(uint32 durSeed) public {
        if (pausedUntil != 0) return;
        // Requires at least two pending deposits. `pausedCancelHonoured` needs
        // a deposit still pending during the pause, but cancels are not
        // blocked, so `cancelOne` and the cancel negative handlers keep
        // draining escrow while `submit` is frozen and cannot replace it.
        if (_countPending() < 2) return;
        uint256 duration = 60_000 + (uint256(durSeed) % 140_000);
        proxy.pauseSpends(duration);
        pausedUntil = block.timestamp + duration;
    }

    /// While paused, a deposit must be refused.
    function pausedDepositRejected(uint64 publicInSeed) public {
        if (block.timestamp >= pausedUntil) return;
        pausedDepositAttempts += 1;
        try this.submit(publicInSeed, 1) {
            pausedDepositAccepted = true;
        } catch { }
    }

    /// While paused, a spend must be refused.
    function pausedSpendRejected(uint256 cmSeed) public {
        if (block.timestamp >= pausedUntil) return;
        if (_shieldedAvailable() < SCALE) return;
        pausedSpendAttempts += 1;
        try this.withdrawOne(1, cmSeed) {
            pausedSpendAccepted = true;
        } catch { }
    }

    /// While paused, a cancel whose delay has elapsed must still be honoured.
    ///
    /// If a pause could block refunds, an admin could hold depositors' escrow
    /// for the length of the pause.
    function pausedCancelHonoured(uint256 idxSeed) public {
        if (block.timestamp >= pausedUntil) return;
        // Scans for a pending deposit that is also past its delay. The first
        // pending deposit is often the newest and still inside its window, so
        // taking it would make this handler rarely reach the pool.
        uint256 id = _firstCancellablePending(idxSeed);
        if (id == type(uint256).max) return;

        pausedCancelAttempts += 1;
        try this.cancelAt(id) { }
        catch {
            pausedCancelRejected = true;
        }
    }

    /// Number of ids still escrowed.
    function _countPending() internal view returns (uint256 n) {
        for (uint256 i = 0; i < allIds.length; i++) {
            if (status[allIds[i]] == Status.Pending) n++;
        }
    }

    /// First pending id whose cancel delay has already elapsed, or
    /// `type(uint256).max` if there is none.
    function _firstCancellablePending(uint256 seed) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return type(uint256).max;
        uint256 delay = masp.cancelDelay();
        uint256 start = seed % n;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = allIds[(start + k) % n];
            if (status[id] == Status.Pending && block.number >= uint256(preimageSubmittedAt[id]) + delay) {
                return id;
            }
        }
        return type(uint256).max;
    }

    // -----------------------------------------------------------------------
    // Negative-space handlers
    //
    // The handlers above drive the pool as an honest caller and so only
    // confirm that correct input is accepted. These make calls the pool must
    // reject and record any that succeed. The Foundry handlers always supply a
    // correct preimage, so across sequences the digest binding, the payer
    // restriction and the drain-once rule are covered only here.
    //
    // Each handler swallows the revert it expects. This is safe because the
    // calls must have no effect: if one succeeds, its state change lands, the
    // ghosts go stale, and the bookkeeping properties fail alongside the
    // specific flag.
    // -----------------------------------------------------------------------

    /// Derive a guaranteed-different value for one digest field.
    ///
    /// XOR with a non-zero mask rather than a fuzzer-chosen replacement, which
    /// could equal the original and be correctly accepted, then recorded as a
    /// breach. `| 1` keeps the mask non-zero under truncation to any width, so
    /// the difference survives the cast to uint16/uint32/uint48.
    function _mask(uint256 mutation) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(mutation))) | 1;
    }

    /// Attempt `cancelDeposit` with exactly one digest field corrupted.
    ///
    /// Every field folded into `_depositDigest` is reachable through
    /// `fieldSeed`, so this checks the whole binding. A success means a caller
    /// can cancel a deposit on terms other than those it was escrowed under:
    /// a different amount, asset, or payer.
    ///
    /// Skipped while the deposit is inside its cancel window, where the call
    /// reverts `CancelTooEarly` before the digest is compared. `cancelTooEarly`
    /// covers that guard.
    function cancelTampered(uint256 idxSeed, uint8 fieldSeed, uint256 mutation) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;
        if (block.number < uint256(preimageSubmittedAt[id]) + masp.cancelDelay()) return;

        uint256 m = _mask(mutation);
        uint256[2] memory cv;
        uint256[2] memory feeCv;

        // Honest values; exactly one is overwritten below.
        uint48 publicIn = preimagePublicIn[id];
        bytes32 cm = preimageCm0[id];
        uint64 assetId = ASSET_ID;
        uint16 fbps = FEE_BPS;
        address who = address(payer);
        uint32 submittedAt = preimageSubmittedAt[id];
        uint48 feeIn = uint48(relayerFeeIn[id]);
        bytes32 feeCm = bytes32(uint256(0xfee));
        uint64 feeAssetId = feeIn == 0 ? 0 : ASSET_ID;

        uint8 field = uint8(fieldSeed % 11);
        if (field == 0) cm = bytes32(uint256(cm) ^ m);
        else if (field == 1) cv[0] ^= m;
        else if (field == 2) assetId = uint64(uint64(assetId) ^ uint64(m));
        else if (field == 3) publicIn = uint48(uint48(publicIn) ^ uint48(m));
        else if (field == 4) fbps = uint16(uint16(fbps) ^ uint16(m));
        else if (field == 5) who = address(uint160(uint160(who) ^ uint160(m)));
        else if (field == 6) submittedAt = uint32(uint32(submittedAt) ^ uint32(m));
        else if (field == 7) feeIn = uint48(uint48(feeIn) ^ uint48(m));
        else if (field == 8) feeCm = bytes32(uint256(feeCm) ^ m);
        else if (field == 9) feeAssetId = uint64(feeAssetId ^ uint64(m));
        else feeCv[0] ^= m;

        cancelTamperAttempts += 1;
        try payer.exec(
            address(masp),
            abi.encodeCall(
                MASP.cancelDeposit,
                (
                    id,
                    publicIn,
                    cm,
                    cv,
                    assetId,
                    fbps,
                    who,
                    submittedAt,
                    PubInputs.FeeNote({ feeIn: feeIn, feeAssetId: feeAssetId, feeCm: feeCm, feeCvDep: feeCv })
                )
            )
        ) returns (
            bytes memory
        ) {
            cancelDigestBreached = true;
        } catch { }
    }

    /// Attempt `flushBatch` with one field of the escrow preimage corrupted.
    ///
    /// The flush leg rebuilds the same digest from `tpi` plus `DepositMeta`
    /// rather than from call arguments, an independent reconstruction. A
    /// success means a flusher can mint a commitment for a deposit escrowed on
    /// different terms.
    function flushTampered(uint256 idxSeed, uint8 fieldSeed, uint256 mutation) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;

        uint256 m = _mask(mutation);
        uint8 field = uint8(fieldSeed % 8);

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = EchidnaRoots.fresh(abi.encode("tampered", id, block.number));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);
        tpi.cms[0] = preimageCm0[id];
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafPublicIn[0] = uint64(preimagePublicIn[id]);
        tpi.isDeposit[0] = 1;
        tpi.cms[1] = bytes32(uint256(0xfee));
        // Zero-value leaves declare asset 0: `tree_update_batch.circom` step 6a
        // canonicalises the asset of a leaf whose Pedersen binding cannot see
        // it, and `_drainDeposit` requires the match.
        tpi.leafAsset[1] = relayerFeeIn[id] == 0 ? 0 : ASSET_ID;
        tpi.leafPublicIn[1] = relayerFeeIn[id];
        tpi.isDeposit[1] = 1;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: address(payer), submittedAt: preimageSubmittedAt[id], fbps: FEE_BPS });

        if (field == 0) tpi.cms[0] = bytes32(uint256(tpi.cms[0]) ^ m);
        else if (field == 1) tpi.leafPublicIn[0] = uint64(uint48(uint48(tpi.leafPublicIn[0]) ^ uint48(m)));
        else if (field == 2) tpi.leafAsset[0] = uint64(tpi.leafAsset[0] ^ uint64(m));
        else if (field == 3) tpi.cms[1] = bytes32(uint256(tpi.cms[1]) ^ m);
        else if (field == 4) tpi.leafPublicIn[1] = uint64(uint48(uint48(tpi.leafPublicIn[1]) ^ uint48(m)));
        else if (field == 5) meta[0].payer = address(uint160(uint160(meta[0].payer) ^ uint160(m)));
        // The fee leaf's asset: bound only through the digest's `feeAssetId`.
        else if (field == 6) tpi.leafAsset[1] = uint64(tpi.leafAsset[1] ^ uint64(m));
        else meta[0].fbps = uint16(uint16(meta[0].fbps) ^ uint16(m));

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        MASP.Proof memory proof;

        flushTamperAttempts += 1;
        try masp.flushBatch(ids, meta, proof, tpi) {
            flushDigestBreached = true;
        } catch { }
    }

    /// Attempt an honest `cancelDeposit` before the delay has elapsed.
    ///
    /// The preimage is correct, so only the timing guard can reject this.
    /// `cancelOne` shows a cancel eventually succeeds; this shows it cannot
    /// succeed early, which protects the flusher's window.
    function cancelTooEarly(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;
        if (block.number >= uint256(preimageSubmittedAt[id]) + masp.cancelDelay()) return;

        uint256[2] memory zCv;
        earlyCancelAttempts += 1;
        try payer.exec(address(masp), _honestCancelCalldata(id, zCv)) returns (bytes memory) {
            earlyCancelAccepted = true;
        } catch { }
    }

    /// Attempt to drain a deposit that has already been flushed or cancelled.
    ///
    /// Both paths clear `escrowed[id]`, and zero means "nothing pending", so
    /// this checks the replay guard against a double refund or a second
    /// commitment from one deposit.
    function drainTwice(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Flushed);
        if (status[id] != Status.Flushed) {
            id = _firstWithStatus(idxSeed, Status.Cancelled);
            if (status[id] != Status.Cancelled) return;
        }

        uint256[2] memory zCv;
        doubleDrainAttempts += 1;
        try payer.exec(address(masp), _honestCancelCalldata(id, zCv)) returns (bytes memory) {
            doubleDrainAccepted = true;
        } catch { }
    }

    /// Attempt an honest `cancelDeposit` sent by someone other than the payer.
    ///
    /// The payer is a contract, and MASP restricts cancellation to the payer
    /// itself whenever `payer.code.length != 0`: a contract payer must observe
    /// its refund arriving, because a refund delivered by a third-party call is
    /// indistinguishable on-chain from a flush and would strand the funder's
    /// claim. This handler calls the pool directly rather than through
    /// `payer.exec`.
    function cancelAsStranger(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;
        if (block.number < uint256(preimageSubmittedAt[id]) + masp.cancelDelay()) return;

        uint256[2] memory zCv;
        strangerCancelAttempts += 1;
        (bool ok,) = address(masp).call(_honestCancelCalldata(id, zCv));
        if (ok) payerGuardBreached = true;
    }

    /// The correct cancel preimage for `id`. Used by handlers testing a guard
    /// other than the digest, so a rejection can only come from that guard.
    function _honestCancelCalldata(uint256 id, uint256[2] memory zCv) internal view returns (bytes memory) {
        return abi.encodeCall(
            MASP.cancelDeposit,
            (
                id,
                preimagePublicIn[id],
                preimageCm0[id],
                zCv,
                ASSET_ID,
                FEE_BPS,
                address(payer),
                preimageSubmittedAt[id],
                PubInputs.FeeNote({
                    feeIn: uint48(relayerFeeIn[id]),
                    feeAssetId: relayerFeeIn[id] == 0 ? 0 : ASSET_ID,
                    feeCm: bytes32(uint256(0xfee)),
                    feeCvDep: zCv
                })
            )
        );
    }

    function _firstWithStatus(uint256 seed, Status want) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return type(uint256).max;
        uint256 start = seed % n;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = allIds[(start + k) % n];
            if (status[id] == want) return id;
        }
        return allIds[start]; // none in `want`; caller short-circuits
    }

    // -----------------------------------------------------------------------
    // Bookkeeping
    //
    // Mirrors test/invariant/: the pool's ledger checked against a shadow the
    // handlers maintain.
    // -----------------------------------------------------------------------

    /// Solvency: the pool holds every still-escrowed total, every flushed
    /// principal not yet withdrawn (including relayer notes), and the fee
    /// claimable by sweep, and nothing else. Neither sweep nor a withdrawal can
    /// reach escrowed funds.
    ///
    /// A withdrawal removes `outAmt` from shielded principal but only `net`
    /// from the balance; the fee stays in `accruedFee`. Both sides move by
    /// `net`.
    function echidna_solvency() public view returns (bool) {
        return token.balanceOf(address(masp))
            == ghostPendingTotal + _shieldedAvailable() + masp.accruedFee(IERC20(address(token)));
    }

    /// Fee accrual is fully accounted: `accruedFee` moves only where the ghost
    /// says it does — up at flush by the deposit's submit-time fee, up at
    /// withdraw by the unshield fee, and to zero at sweep.
    ///
    /// Submit and cancel never accrue: escrowed fees are not yet earned and
    /// must stay refundable. An accrual on either path appears as ghost
    /// divergence.
    function echidna_feeAccrualAccounted() public view returns (bool) {
        return masp.accruedFee(IERC20(address(token))) == ghostAccrued;
    }

    /// Root coherence: the live root is the last one a root-advancing call
    /// wrote, it is inside the known-roots ring, and the committed leaf count
    /// equals the leaves inserted by flushes (two per deposit) and spends.
    function echidna_rootCoherence() public view returns (bool) {
        return masp.currentRoot() == ghostLastRoot && masp.isKnownRoot(masp.currentRoot())
            && masp.committedCount() == ghostInserted;
    }

    /// Lifecycle exclusivity: every submitted id sits in exactly one of
    /// {Pending, Flushed, Cancelled}, and the terminal buckets match the
    /// counters incremented at the call sites that filled them.
    function echidna_lifecycleExclusivity() public view returns (bool) {
        uint256 n = allIds.length;
        uint256 pending;
        uint256 flushed;
        uint256 cancelled;
        for (uint256 i = 0; i < n; i++) {
            Status s = status[allIds[i]];
            if (s == Status.Pending) pending++;
            else if (s == Status.Flushed) flushed++;
            else if (s == Status.Cancelled) cancelled++;
            else return false; // Unknown after submit
        }
        return pending + flushed + cancelled == n && flushCount == flushed && cancelCount == cancelled;
    }

    /// Escrow storage agrees with the lifecycle ghost: `escrowed[id]` is
    /// non-zero for exactly the ids this handler believes are pending.
    ///
    /// Compares per-deposit storage, not balances, against the ghost. Catches
    /// a drain that moved funds without clearing the slot (leaving it
    /// replayable) or a clear that did not move funds (stranding them);
    /// neither appears as a balance discrepancy on its own.
    function echidna_escrowMatchesLifecycle() public view returns (bool) {
        uint256 n = allIds.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = allIds[i];
            if ((masp.escrowed(id) != bytes32(0)) != (status[id] == Status.Pending)) return false;
        }
        return true;
    }

    /// Conservation across the pool boundary: every token that has left the
    /// pool via `sweep` is sitting in the treasury, and nothing else ever
    /// reached it.
    ///
    /// `echidna_solvency` sees only the pool's side, so a sweep that moved more
    /// than `accruedFee`, or moved it elsewhere, passes it if the pool's
    /// arithmetic is self-consistent. This checks the receiving end.
    function echidna_treasuryConservation() public view returns (bool) {
        return token.balanceOf(address(0xfee)) == ghostSwept;
    }

    // -----------------------------------------------------------------------
    // Guards
    //
    // Negative space: calls the pool must refuse are refused.
    // -----------------------------------------------------------------------

    /// The escrow digest binds every field it commits to: no `cancelDeposit`
    /// with a corrupted preimage is accepted.
    function echidna_cancelDigestBinds() public view returns (bool) {
        return !cancelDigestBreached;
    }

    /// The same binding on the flush leg, which rebuilds the digest from the
    /// batch rather than from call arguments.
    function echidna_flushDigestBinds() public view returns (bool) {
        return !flushDigestBreached;
    }

    /// No deposit is cancelled before `cancelDelay` elapses.
    function echidna_cancelDelayEnforced() public view returns (bool) {
        return !earlyCancelAccepted;
    }

    /// No deposit is drained twice.
    function echidna_noDoubleDrain() public view returns (bool) {
        return !doubleDrainAccepted;
    }

    /// A contract payer's deposit is never cancelled by anyone else.
    function echidna_payerGuardEnforced() public view returns (bool) {
        return !payerGuardBreached;
    }

    /// No `flushBatch` naming the same deposit twice is accepted.
    function echidna_noDuplicateIdInBatch() public view returns (bool) {
        return !duplicateIdAccepted;
    }

    // -----------------------------------------------------------------------
    // Withdraw and transfer
    //
    // The legs that move funds out of the pool, and the one that must not.
    // -----------------------------------------------------------------------

    /// No nullifier is consumed twice through `withdraw`: the double-spend
    /// guard on the real entrypoint rather than on `NullifierSet` in isolation.
    function echidna_noNullifierReuse() public view returns (bool) {
        return !nullifierReuseAccepted;
    }

    /// No withdrawal is accepted against a root the pool never committed.
    function echidna_unknownRootRejected() public view returns (bool) {
        return !unknownRootAccepted;
    }

    /// Every nullifier consumed by a landed spend (withdraw or transfer) still
    /// reads as spent.
    ///
    /// The bitmap packs 256 nullifiers per slot, so a write that clobbered its
    /// neighbours would retire one note and un-retire another. Checking the
    /// whole set on every call detects that.
    function echidna_spentNullifiersStaySpent() public view returns (bool) {
        uint256 n = spentNullifiers.length;
        for (uint256 i = 0; i < n; i++) {
            if (!masp.spent(spentNullifiers[i])) return false;
        }
        return true;
    }

    /// The unshield fee split is exact: net plus fee is the gross, to the wei.
    ///
    /// `_unshieldLeg` computes `fee = outAmt * bps / 10_000` and sends
    /// `outAmt - fee`; any unaccounted wei left shielded principal without
    /// reaching the recipient or the accrued fee. Summed across all
    /// withdrawals, so a residue at particular amounts still appears.
    function echidna_withdrawFeeSplitExact() public view returns (bool) {
        return ghostWithdrawnNet + ghostWithdrawFees == ghostWithdrawnGross;
    }

    /// The recipient holds exactly the net of every withdrawal, and nothing
    /// else.
    ///
    /// The pool-side view cannot distinguish a correctly sized transfer to the
    /// wrong address from a correct one; this checks the receiving end.
    function echidna_recipientCredited() public view returns (bool) {
        return token.balanceOf(RECIPIENT) == ghostWithdrawnNet;
    }

    /// A shielded transfer never changes the pool's token balance.
    ///
    /// Checked inside the handler across the single call rather than as a
    /// standing sum, because other handlers move the balance; only a per-call
    /// comparison attributes a movement to `transfer`.
    function echidna_transferMovesNoTokens() public view returns (bool) {
        return !transferMovedTokens;
    }

    // -----------------------------------------------------------------------
    // Root ring and pause
    //
    // Root eviction and the guardian pause.
    // -----------------------------------------------------------------------

    /// Every root the ring buffer holds reads as known, and `rootIndexOf`
    /// names a slot holding it (the index a relayer passes as `anchorIndex`).
    /// Work is bounded by `ROOT_HISTORY` slots.
    function echidna_rootRingConsistent() public view returns (bool) {
        for (uint256 j = 0; j < ROOT_HISTORY; j++) {
            bytes32 r = masp.roots(j);
            if (r == bytes32(0)) continue;
            (bool found, uint256 index) = masp.rootIndexOf(r);
            if (!found || masp.roots(index) != r || !masp.isKnownRoot(r)) return false;
        }
        return true;
    }

    /// No root the ring has evicted still reads as known.
    ///
    /// A root still found after eviction would let a relayer anchor a spend to
    /// a tree state the pool has forgotten.
    function echidna_evictedRootsUnknown() public view returns (bool) {
        uint256 tracked = evictedCount < EVICTED_TRACKED ? evictedCount : EVICTED_TRACKED;
        for (uint256 i = 0; i < tracked; i++) {
            if (masp.isKnownRoot(evictedRoots[i])) return false;
        }
        return true;
    }

    /// No withdrawal against an evicted root is accepted.
    function echidna_evictedRootRejected() public view returns (bool) {
        return !evictedRootAccepted;
    }

    /// A pause stops the pool taking on new obligations.
    function echidna_pauseBlocksDeposits() public view returns (bool) {
        return !pausedDepositAccepted;
    }

    /// A pause stops the pool settling spends.
    function echidna_pauseBlocksSpends() public view returns (bool) {
        return !pausedSpendAccepted;
    }

    /// A pause never traps escrowed funds: a cancel past its delay is still
    /// honoured while the pool is paused.
    ///
    /// `cancelDeposit` and `sweep` are excluded from `whenNotPaused`. If
    /// `cancelDeposit` were paused, an admin could freeze depositors' funds for
    /// the length of a pause.
    function echidna_pauseCannotTrapFunds() public view returns (bool) {
        return !pausedCancelRejected;
    }

    // -----------------------------------------------------------------------
    // Optimization targets
    //
    // Used only under `testMode: optimization` (`just echidna-optimize`), where
    // Echidna maximises the returned value. The properties above check whether
    // an invariant breaks; these measure how far it drifts, which separates a
    // bounded rounding residue from a leak that grows with volume. Both are
    // expected to report 0.
    // -----------------------------------------------------------------------

    /// Largest shortfall between what the pool owes and what it holds.
    ///
    /// Signed; positive means insolvent (the pool cannot cover escrowed
    /// deposits, shielded principal and claimable fees). `echidna_solvency`
    /// fails on any non-zero deviation; this value measures the magnitude.
    function optimize_solvencyDeficit() public view returns (int256) {
        uint256 owed = ghostPendingTotal + _shieldedAvailable() + masp.accruedFee(IERC20(address(token)));
        return int256(owed) - int256(token.balanceOf(address(masp)));
    }

    /// Largest divergence, either direction, between the pool's `accruedFee`
    /// and the value implied by the flush/withdraw/sweep history.
    ///
    /// Absolute deviation: over-accrual takes fees from funds still refundable
    /// to a depositor and under-accrual strands them in the pool, so neither
    /// direction is benign.
    function optimize_feeAccrualDrift() public view returns (int256) {
        uint256 actual = masp.accruedFee(IERC20(address(token)));
        uint256 delta = actual > ghostAccrued ? actual - ghostAccrued : ghostAccrued - actual;
        return int256(delta);
    }
}
