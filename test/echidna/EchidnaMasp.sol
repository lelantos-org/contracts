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
/// This is the same subject as `test/invariant/MASPPendingFee.invariant.t.sol`
/// and `test/invariant/MASP.flow.invariant.t.sol`, driven by a different
/// engine. Foundry's invariant runner samples fresh call sequences each run
/// from a seed corpus; Echidna mutates a corpus it keeps on disk across runs
/// (`corpusDir` in `echidna.yaml`), so the nightly job compounds — a sequence
/// that first reached a deep state months ago stays in the pool as a
/// mutation base. That accumulation, not the property set, is what this file
/// buys: the properties below are the Foundry ones restated.
///
/// Three deliberate differences from the Foundry handlers, all forced by hevm
/// having a smaller cheatcode set than Foundry:
///
///  - The tree-update verifier is `MockTreeUpdateVerifier`, a real contract,
///    where the Foundry suites use `vm.mockCall`. hevm has no `mockCall`.
///  - The payer is `EchidnaMaspPayer`, a deployed contract that originates its
///    own calls, where the Foundry suites `vm.etch` a stub and `vm.prank` it.
///  - Block advancement is left to Echidna's own per-call block delay rather
///    than a `vm.roll` to exactly `cancelDelay`. The Foundry handlers roll
///    past the delay unconditionally, which makes every cancel succeed and so
///    never exercises the `cancelDelay` guard; here the guard is live and
///    Echidna has to find the timing. `maxBlockDelay` in `echidna.yaml` is set
///    against `CANCEL_DELAY_DEFAULT` (7_200 blocks) so it can.
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
    /// Mirrors `masp.accruedFee(token)`: += fee at flush, zeroed by sweep.
    uint256 internal ghostAccrued;
    /// Most recent `newRoot` written by a successful `flushBatch`, genesis
    /// before the first one.
    bytes32 internal ghostLastRoot;
    /// Sum of `actualCount` across landed flushes, i.e. 2 * #flushed.
    uint64 internal ghostInserted;

    /// Landed-call counters. Public because they are the only externally
    /// visible evidence that a handler reached the pool rather than hitting
    /// one of its early returns — `EchidnaMaspReachability.t.sol` gates on
    /// them, and a human reading an Echidna run wants them too.
    uint256 public flushCount;
    uint256 public cancelCount;
    uint256 public submitCount;

    /// Negative-space violation flags. Each is set by a handler that made a
    /// call the contract is required to reject and observed it succeed
    /// instead. They are latched, never cleared: a single breach is the
    /// finding, and clearing one would let a later well-behaved sequence hide
    /// it.
    bool internal cancelDigestBreached;
    bool internal flushDigestBreached;
    bool internal earlyCancelAccepted;
    bool internal doubleDrainAccepted;
    bool internal payerGuardBreached;

    /// Attempt counters for the same handlers. A violation flag that never
    /// gets set proves nothing on its own — it reads identically whether the
    /// guard held or the handler never reached the call. These separate the
    /// two, and `EchidnaMaspReachability.t.sol` gates on them.
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

    /// Nullifiers consumed by a landed withdraw, and the set of them.
    bytes32[] internal spentNullifiers;
    mapping(bytes32 => bool) internal ghostSpent;

    /// Monotonic source of never-before-used nullifiers; see
    /// `_nextNullifierSeed`. Started high so it cannot collide with the small
    /// commitment seeds the deposit path uses.
    uint256 internal nullifierCursor = 1 << 128;

    uint256 public withdrawCount;

    /// Set if a `transfer` changed the pool's token balance. A shielded
    /// transfer moves no tokens by construction, so this can only latch if
    /// that stops being true.
    bool internal transferMovedTokens;
    uint256 public transferCount;

    /// Multi-deposit flush counters. `flushBatch` takes arrays and `flushOne`
    /// only ever passes one id, so the batch loop and its per-token fee
    /// accumulator are exercised at n = 1 and nowhere else.
    uint256 public batchFlushCount;
    /// Set if a batch naming the same deposit twice was accepted.
    bool internal duplicateIdAccepted;
    uint256 public duplicateIdAttempts;

    // --- root ring ---

    /// The most recently evicted roots, newest last, capped so the property
    /// that reads them stays O(1) rather than growing with the run.
    ///
    /// `CommitmentTree` keeps `ROOT_HISTORY` roots in a ring and clears
    /// `isKnownRoot` for whatever the next push displaces. Nothing else in the
    /// repo pushes past the wrap, so the eviction branch — and the question of
    /// whether a spend can still prove inclusion in a tree the pool has
    /// forgotten — is unexercised.
    /// Mirrors `CommitmentTree.ROOT_HISTORY`, which is an `internal constant`
    /// on the contract and so can be neither read from here nor imported.
    /// `EchidnaMaspReachability.t.sol` pins the two together by asserting that
    /// `roots(ROOT_HISTORY - 1)` reads and `roots(ROOT_HISTORY)` does not, so
    /// a change to the ring size fails as an assertion rather than silently
    /// leaving the eviction properties inspecting the wrong slot.
    uint256 internal constant ROOT_HISTORY = 64;

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
    /// Set if a paused pool *rejected* a cancel it should have honoured. This
    /// is the asymmetry that matters: a pause must not be able to trap
    /// escrowed funds.
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

        // Both verifier slots must hold code — `MASP.initialize` rejects a
        // codeless verifier — and both are told to accept, because the state
        // machine is the subject here and the pairings are not.
        //
        // What that costs is worth stating. With the spend verifier accepting,
        // the fuzzer supplies the public inputs a circuit would otherwise have
        // constrained, so it can "withdraw" value no deposit ever funded.
        // Value conservation across a spend is the circuit's invariant, not
        // MASP's, and it is not observable here — `withdrawOne` therefore
        // bounds itself to the shielded principal the ghost knows was
        // deposited, and every withdraw property below asserts something MASP
        // itself owns: nullifier uniqueness, root membership, and the exact
        // arithmetic of the fee split.
        IVerifier tub = IVerifier(address(new MockTreeUpdateVerifier(true)));
        MockBatchVerifier bv = new MockBatchVerifier();
        bv.setResult(true);

        token = new MockERC20("M", "M", 18);
        payer = new EchidnaMaspPayer();

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        // Deployed here rather than through `deployPoolUniform` for one
        // reason: that helper pins the proxy admin to `TEST_PROXY_ADMIN`, and
        // the guardian pause is `onlyAdmin`. Echidna drives every call from
        // its own senders and cannot impersonate an address, so the only way
        // to reach `pauseSpends` at all is for this contract to be the admin.
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

        // One standing approval, granted by the payer itself. The Foundry
        // handlers re-approve on every submit under a prank; there is nothing
        // to re-approve here since the allowance is already unlimited.
        payer.exec(address(token), abi.encodeCall(IERC20.approve, (permit2, type(uint256).max)));

        ghostLastRoot = masp.currentRoot();
    }

    // -----------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------

    /// Submit a fresh deposit.
    ///
    /// `feeIn` is forced non-zero: with a worthless relayer note the pool
    /// holds nothing behind it and solvency would hold however it were
    /// accounted, so the zero case cannot distinguish a correct split from a
    /// broken one.
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

        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: nonce++, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00"
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
        // each flush publishes a distinct root and the ring advances as it
        // would in production. `EchidnaRoots.fresh` carries the reduction and
        // why it is mandatory.
        tpi.newRoot = EchidnaRoots.fresh(abi.encode("flushed", id, block.number));
        tpi.startIndex = masp.committedCount();
        // A deposit occupies LEAVES_PER_DEPOSIT (= 2) adjacent leaves: the
        // principal, then the note paying the flusher. `_validateBatchHeader`
        // requires `actualCount == n * LEAVES_PER_DEPOSIT` and `_drainDeposit`
        // rebuilds the escrow digest from leaf `p + 1`, so both must be
        // populated or the call reverts `BatchMisaligned` before touching
        // state.
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
    /// No roll past `cancelDelay` first: unlike the Foundry handlers this
    /// leaves the timing guard live, so a call Echidna makes too early reverts
    /// and the sequence is only counted when the delay genuinely elapsed.
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
                        feeIn: uint48(relayerFeeIn[id]), feeCm: bytes32(uint256(0xfee)), feeCvDep: zCv
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
    /// External so `pausedCancelHonoured` can wrap it in try/catch, and by-id
    /// so the deposit it verified is the deposit that gets cancelled: routing
    /// back through `cancelOne`'s own scan could land on a different one and
    /// turn an unrelated rejection into a false report of a trapped refund.
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
    /// Deposit `i` owns leaves `2i` and `2i + 1` — the principal, then the
    /// note paying the flusher — and `_drainDeposit` rebuilds the escrow
    /// digest from both. Shared so a multi-deposit batch is assembled the same
    /// way as a single one; a batch that filled only the even slots would
    /// revert for reasons unrelated to whatever the caller meant to test.
    function _fillDepositLeaves(PubInputs.TreeUpdateBatch memory tpi, uint256 slot, uint256 id) internal view {
        uint256 pIdx = slot * PubInputs.LEAVES_PER_DEPOSIT;
        tpi.cms[pIdx] = preimageCm0[id];
        tpi.leafAsset[pIdx] = ASSET_ID;
        tpi.leafPublicIn[pIdx] = uint64(preimagePublicIn[id]);
        tpi.isDeposit[pIdx] = 1;
        tpi.cms[pIdx + 1] = bytes32(uint256(0xfee));
        // Zero-value leaves declare asset 0: `tree_update_batch.circom` step 7a
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
    /// `flushOne` only ever builds a one-deposit batch, so the loop in
    /// `flushBatch` and the per-token fee accumulator behind it run at n = 1
    /// and nowhere else. Accrual is summed across the batch and settled once
    /// per token, which is a different code path from accruing twice.
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
    /// `_drainDeposit` clears `escrowed[id]` as it goes, and zero is the
    /// sentinel for "nothing pending", so the second slot must find the entry
    /// already gone. Accepting it would mint two commitments and pay two
    /// relayer notes against one escrowed deposit — the drain-once rule, but
    /// within a single transaction rather than across two, which is the case
    /// `drainTwice` cannot reach.
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
            // The batch landed, so the ghosts must follow it or every
            // bookkeeping property fails for the wrong reason and buries the
            // finding this handler exists to report.
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
    // `withdraw` is where funds leave the pool, and it is the entrypoint with
    // the least sequence-level coverage in the repo: the unit tests exercise
    // it directly, but the only invariant suite that touches nullifiers drives
    // `MASPHarness.consumeNullifierExternal`, i.e. `NullifierSet` in
    // isolation, never the real spend path. Nothing fuzzes a withdraw against
    // a pool whose deposit history was itself fuzzed.
    // -----------------------------------------------------------------------

    /// Build the spend/tree-update pair for a withdrawal of `publicOut`.
    ///
    /// Split out because `withdrawOne`, `withdrawReplay` and
    /// `withdrawUnknownRoot` must differ in exactly one field each; sharing
    /// the construction is what makes a rejection attributable to the guard
    /// under test rather than to some unrelated malformed field.
    function _spendRequest(uint64 publicOut, uint256 nfSeed, uint256 cmSeed)
        internal
        view
        returns (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi)
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

        tpi = SpendFixture.batchFor(
            pi, masp.currentRoot(), EchidnaRoots.fresh(abi.encode("spent", nfSeed, block.number)), masp.committedCount()
        );
    }

    /// Shielded principal still available to withdraw.
    function _shieldedAvailable() internal view returns (uint256) {
        return ghostShieldedPrincipal - ghostWithdrawnGross;
    }

    /// A `publicOut` the pool can actually pay, or 0 when it can pay nothing.
    ///
    /// The bound is not a convenience. With the spend verifier stubbed to
    /// accept, an unbounded `publicOut` would let the fuzzer drain escrowed
    /// deposits, and `echidna_solvency` would then report an insolvency that
    /// is an artifact of the stub rather than a defect in MASP. Every handler
    /// that spends goes through here so that none of them can forget it.
    ///
    /// Zero doubles as the "nothing to withdraw" signal, which is unambiguous
    /// because a valid amount is always at least 1.
    function _boundedPublicOut(uint64 seed) internal view returns (uint64) {
        uint256 maxOut = _shieldedAvailable() / SCALE;
        if (maxOut == 0) return 0;
        if (maxOut > 1_000) maxOut = 1_000;
        return uint64(1 + (seed % maxOut));
    }

    /// The next block of `TRANSACT_IN` never-before-used nullifiers.
    ///
    /// `_validateRequest` rejects a repeat within one call and
    /// `_consumeNullifier` rejects one across calls, so the happy path needs a
    /// supply that is fresh by construction; letting the fuzzer pick would
    /// make a landed spend rare and the whole leg mostly unreachable. Reuse is
    /// driven deliberately by `withdrawReplay` instead.
    function _nextNullifierSeed() internal returns (uint256 s) {
        s = nullifierCursor;
        nullifierCursor += PubInputs.TRANSACT_IN;
    }

    /// Withdraw shielded funds to `RECIPIENT`.
    ///
    /// Bounded by the shielded principal the ghost knows was actually
    /// deposited. That bound is not a convenience: with the spend verifier
    /// stubbed to accept, an unbounded `publicOut` would let the fuzzer drain
    /// escrowed deposits, and `echidna_solvency` would report an insolvency
    /// that is an artifact of the stub rather than a defect in MASP.
    function withdrawOne(uint64 outSeed, uint256 cmSeed) public {
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) =
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
    /// The third spend mode, and the one with the sharpest property attached.
    /// `transfer` takes the same proofs and the same tree update as
    /// `withdraw`, runs the same nullifier consumption and root advance, and
    /// then must leave `balanceOf(masp)` bit-identical — MASP's own comment on
    /// the branch is "No tokens move". Any leak on this path is unbacked value
    /// leaving the pool, and no balance-sum property elsewhere would attribute
    /// it here.
    function transferShielded(uint256 cmSeed) public {
        // publicOut = 0 is what makes this a transfer rather than a withdraw;
        // `_spendRequest` already leaves publicIn at 0.
        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) =
            _spendRequest(0, _nextNullifierSeed(), cmSeed);

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
    /// This is the double-spend guard on the real entrypoint. The existing
    /// invariant coverage asserts it on `NullifierSet` through a harness; here
    /// it has to survive everything `withdraw` does before reaching
    /// `_consumeNullifier`.
    function withdrawReplay(uint256 nfIdxSeed, uint64 outSeed, uint256 cmSeed) public {
        if (spentNullifiers.length == 0) return;
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) =
            _spendRequest(publicOut, _nextNullifierSeed(), cmSeed);

        // Exactly one slot is swapped for a spent nullifier; the other three
        // stay fresh, so `DuplicateNullifier` (the within-call check) cannot
        // be what rejects this and only `DoubleSpend` can.
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
    /// Root membership is what ties a spend to state the tree-update circuit
    /// actually produced. Accepting an unknown root would let a spend prove
    /// inclusion in a tree of the caller's own construction.
    function withdrawUnknownRoot(uint64 outSeed, uint256 cmSeed, uint256 rootSeed) public {
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) =
            _spendRequest(publicOut, _nextNullifierSeed(), cmSeed);

        bytes32 bogus = EchidnaRoots.fresh(abi.encode("unknown-root", rootSeed));
        if (masp.isKnownRoot(bogus)) return; // astronomically unlikely; skip rather than misreport
        pi.merkleRoot = bogus;

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
    /// afterwards. `CommitmentTree._advanceRoot` leaves the entry alone when
    /// it equals the incoming root, so callers compare against `newRoot`
    /// before recording.
    function _pendingEviction() internal view returns (bytes32) {
        uint32 next = uint32((uint256(masp.rootIndex()) + 1) & (ROOT_HISTORY - 1));
        return masp.roots(next);
    }

    /// Record a root the pool has just forgotten.
    ///
    /// Called from every handler that advances the root — both flush paths,
    /// withdraw and transfer. Missing one would not make the property unsound,
    /// only blind: evictions it caused would go unrecorded and
    /// `withdrawEvictedRoot` would have less to aim at.
    ///
    /// Roots here are keccak images reduced mod the scalar field, so a value
    /// re-entering the ring after eviction is not a case worth handling; if it
    /// somehow did, this would report a false breach rather than miss a real
    /// one, which is the safe direction.
    function _recordEviction(bytes32 evicted, bytes32 newRoot) internal {
        if (evicted == bytes32(0) || evicted == newRoot) return;
        evictedRoots[evictedCount % EVICTED_TRACKED] = evicted;
        evictedCount += 1;
    }

    /// Advance the root many times in one call.
    ///
    /// Purely a reachability device, and it earns its place: the ring holds 64
    /// roots and evicts nothing until it is full, so the eviction properties
    /// need 64+ landed root advances inside a *single* sequence — Echidna
    /// resets state between them. Spread across two dozen handlers at
    /// `seqLen: 400`, transfers land perhaps twenty times, and measurement
    /// confirmed the eviction branch never once executed in 40k calls. Doing
    /// the advances in a loop puts the wrap within reach of a few calls
    /// instead of a few hundred.
    ///
    /// Transfers are the vehicle because they need neither a pending deposit
    /// nor shielded funds, so they cannot early-return for reasons unrelated
    /// to the ring.
    function churnRoots(uint8 nSeed, uint256 cmSeed) public {
        uint256 n = 1 + (uint256(nSeed) % 16);
        for (uint256 i = 0; i < n; i++) {
            transferShielded(cmSeed + i);
        }
    }

    /// Attempt a withdrawal proving inclusion in a root the ring has evicted.
    ///
    /// Distinct from `withdrawUnknownRoot`, which uses a root that was never
    /// committed at all. This one was genuinely the pool's state once, so it
    /// is the case a stale-root check is most likely to get wrong.
    function withdrawEvictedRoot(uint64 outSeed, uint256 cmSeed, uint256 pickSeed) public {
        if (evictedCount == 0) return;
        uint64 publicOut = _boundedPublicOut(outSeed);
        if (publicOut == 0) return;

        uint256 tracked = evictedCount < EVICTED_TRACKED ? evictedCount : EVICTED_TRACKED;
        bytes32 stale = evictedRoots[pickSeed % tracked];

        (PubInputs.Transact memory pi, PubInputs.TreeUpdateBatch memory tpi) =
            _spendRequest(publicOut, _nextNullifierSeed(), cmSeed);
        pi.merkleRoot = stale;

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
    // `whenNotPaused` guards five entry points — withdraw, transfer, deposit,
    // depositAuthorized and flushBatch — and deliberately does not guard
    // `cancelDeposit` or `sweep`, because "escrowed funds must stay
    // recoverable". That asymmetry is the property: a pause must stop the pool
    // taking on or settling obligations without being able to trap money
    // already in escrow.
    // -----------------------------------------------------------------------

    /// Trip the guardian pause. Reachable once, by construction: the proxy
    /// sets `guardianPauseUsed` and refuses a second until governance clears
    /// it.
    ///
    /// The duration is chosen against `maxTimeDelay` in `echidna.yaml`, which
    /// is 15_000s: this spans enough calls for a block delay to cross the
    /// 7_200-block cancel delay while the pause is still live, which is what
    /// `pausedCancelHonoured` needs and what an earlier 3_600s ceiling made
    /// unreachable. It stays well under `MAX_PAUSE` (7 days), which would
    /// outlast the sequence and freeze everything else.
    function pauseSpends(uint32 durSeed) public {
        if (pausedUntil != 0) return;
        // Only trip the pause when there is escrowed money for it to threaten,
        // and enough of it to survive the window. The property here is that a
        // pause cannot trap funds, which needs a deposit still pending when
        // `pausedCancelHonoured` runs — but `cancelDeposit` is exactly what a
        // pause does not block, so `cancelOne` and the cancel-flavoured
        // negative handlers keep draining the escrow while `submit` is frozen
        // and cannot replace it. Two deposits is the headroom that makes the
        // window observable.
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
    /// The one direction of this property that is about funds being stuck
    /// rather than funds moving: if a pause could block refunds, an admin
    /// could hold depositors' escrow indefinitely.
    function pausedCancelHonoured(uint256 idxSeed) public {
        if (block.timestamp >= pausedUntil) return;
        // Scans for a pending deposit that is *also* past its delay, rather
        // than taking the first pending one and giving up when it happens to
        // be too recent. Those are different searches, and the difference is
        // this handler's whole reachability: the first pending deposit is
        // often the newest, and so the one still inside its window.
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
    // Everything above drives the pool the way an honest caller would, and so
    // can only ever confirm that correct input is accepted. These make calls
    // the pool is required to *reject*, and record it when one is not. That is
    // the half of `cancelDeposit`/`flushBatch` no fuzzer in this repo reaches
    // today: the Foundry handlers always resupply a correct preimage, so the
    // digest binding, the payer restriction and the drain-once rule are
    // asserted by unit tests at a handful of points and by nothing at all
    // across sequences.
    //
    // Each handler swallows the revert it expects. That is safe here only
    // because these calls are supposed to have no effect: if one does succeed,
    // the state change lands, the ghosts go stale, and the bookkeeping
    // properties above fail alongside the specific flag set here.
    // -----------------------------------------------------------------------

    /// Derive a guaranteed-different value for one digest field.
    ///
    /// XOR with a non-zero mask rather than a fuzzer-chosen replacement: a
    /// replacement can collide with the original, and a "tampered" call that
    /// carried the original value would be accepted for entirely correct
    /// reasons and be recorded as a breach. `| 1` keeps the mask non-zero
    /// under truncation to any width, so the difference survives the cast to
    /// uint16/uint32/uint48.
    function _mask(uint256 mutation) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(mutation))) | 1;
    }

    /// Attempt `cancelDeposit` with exactly one digest field corrupted.
    ///
    /// Every field folded into `_depositDigest` is reachable through
    /// `fieldSeed`, so this asserts the binding as a whole rather than
    /// spot-checking one argument. A success means a caller can cancel a
    /// deposit on terms other than the ones it was escrowed under — refunding
    /// a different amount, a different asset, or to a different payer.
    ///
    /// Skipped while the deposit is still inside its cancel window: there the
    /// call would revert `CancelTooEarly` before the digest is ever compared,
    /// which proves nothing about the binding. `cancelTooEarly` covers that
    /// guard separately.
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

        uint8 field = uint8(fieldSeed % 10);
        if (field == 0) cm = bytes32(uint256(cm) ^ m);
        else if (field == 1) cv[0] ^= m;
        else if (field == 2) assetId = uint64(uint64(assetId) ^ uint64(m));
        else if (field == 3) publicIn = uint48(uint48(publicIn) ^ uint48(m));
        else if (field == 4) fbps = uint16(uint16(fbps) ^ uint16(m));
        else if (field == 5) who = address(uint160(uint160(who) ^ uint160(m)));
        else if (field == 6) submittedAt = uint32(uint32(submittedAt) ^ uint32(m));
        else if (field == 7) feeIn = uint48(uint48(feeIn) ^ uint48(m));
        else if (field == 8) feeCm = bytes32(uint256(feeCm) ^ m);
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
                    PubInputs.FeeNote({ feeIn: feeIn, feeCm: feeCm, feeCvDep: feeCv })
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
    /// instead of from call arguments, so it is a separate reconstruction with
    /// its own opportunities to drop a field. A success means a flusher can
    /// mint a commitment for a deposit that was escrowed on different terms.
    function flushTampered(uint256 idxSeed, uint8 fieldSeed, uint256 mutation) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;

        uint256 m = _mask(mutation);
        uint8 field = uint8(fieldSeed % 7);

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
        // Zero-value leaves declare asset 0: `tree_update_batch.circom` step 7a
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
    /// The preimage is correct, so the only thing that can reject this is the
    /// timing guard. `cancelOne` establishes that a cancel eventually
    /// succeeds; this establishes that it cannot succeed early, which is the
    /// half that keeps a flusher's window from being stolen out from under it.
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
    /// `escrowed[id]` is cleared on the way out of both, and zero is the
    /// sentinel for "nothing pending", so this is the replay guard for a
    /// double refund or a second commitment minted from one deposit.
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
    /// The payer here is a contract, and MASP restricts cancellation to the
    /// payer itself whenever `payer.code.length != 0` — a contract payer has
    /// to observe its own refund, because a refund delivered by a third party
    /// is indistinguishable on-chain from a flush and would strand whoever
    /// funded it. This handler is that third party: it calls the pool
    /// directly rather than through `payer.exec`.
    function cancelAsStranger(uint256 idxSeed) public {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;
        if (block.number < uint256(preimageSubmittedAt[id]) + masp.cancelDelay()) return;

        uint256[2] memory zCv;
        strangerCancelAttempts += 1;
        (bool ok,) = address(masp).call(_honestCancelCalldata(id, zCv));
        if (ok) payerGuardBreached = true;
    }

    /// The correct cancel preimage for `id`. Shared by the handlers whose
    /// subject is a guard other than the digest, so that a rejection there can
    /// only have come from the guard under test.
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
                PubInputs.FeeNote({ feeIn: uint48(relayerFeeIn[id]), feeCm: bytes32(uint256(0xfee)), feeCvDep: zCv })
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
    // Ported from test/invariant/. The shape of the pool's own ledger, checked
    // against a shadow the handlers maintain.
    // -----------------------------------------------------------------------

    /// Solvency: the pool holds every still-escrowed total, every flushed
    /// principal not yet withdrawn (including the relayer notes minted against
    /// it), and whatever fee is claimable by sweep — and nothing else. Sweep
    /// can never reach escrowed funds, and neither can a withdrawal.
    ///
    /// A withdrawal removes `outAmt` from shielded principal but only `net`
    /// from the balance; the fee stays behind in `accruedFee`. Both sides move
    /// by `net`, so the identity is preserved rather than merely rebased.
    function echidna_solvency() public view returns (bool) {
        return token.balanceOf(address(masp))
            == ghostPendingTotal + _shieldedAvailable() + masp.accruedFee(IERC20(address(token)));
    }

    /// Fee accrual is fully accounted: `accruedFee` moves only where the ghost
    /// says it does — up at flush by the deposit's submit-time fee, up at
    /// withdraw by the unshield fee, and to zero at sweep.
    ///
    /// Submit and cancel are absent from that list on purpose: escrowed fees
    /// have not been earned yet and must stay refundable. An accrual on either
    /// path shows up here as ghost divergence.
    function echidna_feeAccrualAccounted() public view returns (bool) {
        return masp.accruedFee(IERC20(address(token))) == ghostAccrued;
    }

    /// Root coherence: the live root is the last one a flush wrote, it is
    /// always inside the known-roots ring, and the committed leaf count is
    /// exactly two per flushed deposit.
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
    /// The bookkeeping properties compare the pool's balances against ghost
    /// sums; this compares the pool's own per-deposit storage against the
    /// ghost, which is what catches a drain that moved funds without clearing
    /// the slot (leaving it replayable) or a clear that did not move funds
    /// (stranding them). Neither shows up as a balance discrepancy on its own.
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
    /// `echidna_solvency` only sees the pool's side of the transfer, so a
    /// sweep that moved more than `accruedFee`, or moved it somewhere other
    /// than the treasury, satisfies it as long as the pool's own arithmetic is
    /// self-consistent. This pins the other end.
    function echidna_treasuryConservation() public view returns (bool) {
        return token.balanceOf(address(0xfee)) == ghostSwept;
    }

    // -----------------------------------------------------------------------
    // Guards
    //
    // The negative space. Everything the handlers above do, an honest caller
    // could do; these hold that what the pool must refuse, it refuses.
    // -----------------------------------------------------------------------

    /// The escrow digest binds every field it commits to: no `cancelDeposit`
    /// with a corrupted preimage has ever been accepted.
    function echidna_cancelDigestBinds() public view returns (bool) {
        return !cancelDigestBreached;
    }

    /// The same binding on the flush leg, which rebuilds the digest from the
    /// batch rather than from call arguments.
    function echidna_flushDigestBinds() public view returns (bool) {
        return !flushDigestBreached;
    }

    /// No deposit has ever been cancelled before `cancelDelay` elapsed.
    function echidna_cancelDelayEnforced() public view returns (bool) {
        return !earlyCancelAccepted;
    }

    /// No deposit has ever been drained twice.
    function echidna_noDoubleDrain() public view returns (bool) {
        return !doubleDrainAccepted;
    }

    /// A contract payer's deposit has never been cancelled by anyone else.
    function echidna_payerGuardEnforced() public view returns (bool) {
        return !payerGuardBreached;
    }

    /// No `flushBatch` naming the same deposit twice has been accepted.
    function echidna_noDuplicateIdInBatch() public view returns (bool) {
        return !duplicateIdAccepted;
    }

    // -----------------------------------------------------------------------
    // Withdraw and transfer
    //
    // The legs that move funds out of the pool, and the one that must not.
    // -----------------------------------------------------------------------

    /// No nullifier has ever been consumed twice through `withdraw`.
    ///
    /// The double-spend guard on the real entrypoint, as opposed to on
    /// `NullifierSet` in isolation.
    function echidna_noNullifierReuse() public view returns (bool) {
        return !nullifierReuseAccepted;
    }

    /// No withdrawal has ever been accepted against a root the pool never
    /// committed.
    function echidna_unknownRootRejected() public view returns (bool) {
        return !unknownRootAccepted;
    }

    /// Every nullifier a landed withdrawal consumed still reads as spent.
    ///
    /// Consuming is only half of it: the bitmap packs 256 nullifiers per slot,
    /// so a write that clobbered its neighbours would retire a note and then
    /// silently un-retire another. Checking the whole set on every call is
    /// what catches that.
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
    /// `outAmt - fee`, so any wei the split fails to account for is a wei that
    /// left shielded principal and reached neither the recipient nor the
    /// treasury. Summed across every withdrawal, so a residue that only
    /// appears at particular amounts still shows up.
    function echidna_withdrawFeeSplitExact() public view returns (bool) {
        return ghostWithdrawnNet + ghostWithdrawFees == ghostWithdrawnGross;
    }

    /// The recipient received exactly the net of every withdrawal, and nothing
    /// besides.
    ///
    /// The pool-side view cannot tell a transfer of the right size to the
    /// wrong address from a correct one; this is the other end of it.
    function echidna_recipientCredited() public view returns (bool) {
        return token.balanceOf(RECIPIENT) == ghostWithdrawnNet;
    }

    /// A shielded transfer never changes the pool's token balance.
    ///
    /// Checked inside the handler across the single call rather than as a
    /// standing sum, because every other handler moves the balance on purpose
    /// — only a per-call comparison can attribute a movement to `transfer`.
    function echidna_transferMovesNoTokens() public view returns (bool) {
        return !transferMovedTokens;
    }

    // -----------------------------------------------------------------------
    // Root ring and pause
    //
    // State the pool forgets on purpose, and state it freezes on purpose.
    // -----------------------------------------------------------------------

    /// Every root the ring buffer still holds reads as known.
    ///
    /// The buffer and the `isKnownRoot` map are written together but read
    /// apart, so a spend is only as safe as their agreement. Bounded work:
    /// `ROOT_HISTORY` reads regardless of how long the run has gone on.
    function echidna_rootRingConsistent() public view returns (bool) {
        for (uint256 j = 0; j < ROOT_HISTORY; j++) {
            bytes32 r = masp.roots(j);
            if (r != bytes32(0) && !masp.isKnownRoot(r)) return false;
        }
        return true;
    }

    /// No root the ring has evicted still reads as known.
    ///
    /// The other half of the ring's contract. A root that survives eviction in
    /// the map lets a spend prove inclusion in a tree state the pool has
    /// already forgotten.
    function echidna_evictedRootsUnknown() public view returns (bool) {
        uint256 tracked = evictedCount < EVICTED_TRACKED ? evictedCount : EVICTED_TRACKED;
        for (uint256 i = 0; i < tracked; i++) {
            if (masp.isKnownRoot(evictedRoots[i])) return false;
        }
        return true;
    }

    /// No withdrawal against an evicted root has been accepted.
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
    /// `cancelDeposit` and `sweep` are excluded from `whenNotPaused` on
    /// purpose. A deliberate asymmetry is exactly the kind of thing a later
    /// refactor tidies away, at which point an admin could freeze depositors'
    /// money for the length of a pause and nothing else here would notice.
    function echidna_pauseCannotTrapFunds() public view returns (bool) {
        return !pausedCancelRejected;
    }

    // -----------------------------------------------------------------------
    // Optimization targets
    //
    // Only consulted under `testMode: optimization` (`just echidna-optimize`),
    // where Echidna maximises the returned value instead of asserting it. The
    // properties above answer "does this ever break"; these answer "how far
    // can it drift", which is the question that separates a bounded rounding
    // residue from a leak that grows with volume. Both should report 0.
    // -----------------------------------------------------------------------

    /// Largest shortfall between what the pool owes and what it holds.
    ///
    /// Signed and oriented so that positive means insolvent — the pool cannot
    /// cover its escrowed deposits, shielded principal and claimable fees.
    /// `echidna_solvency` already fails on any non-zero deviation, so a run
    /// that reports a maximum above 0 here is reporting a bug the property
    /// suite would also catch; the value is what says how bad.
    function optimize_solvencyDeficit() public view returns (int256) {
        uint256 owed = ghostPendingTotal + _shieldedAvailable() + masp.accruedFee(IERC20(address(token)));
        return int256(owed) - int256(token.balanceOf(address(masp)));
    }

    /// Largest divergence, either direction, between the pool's `accruedFee`
    /// and what the flush/sweep history says it should be.
    ///
    /// Unsigned deviation rather than a signed one: over-accrual takes fees
    /// out of funds that are still refundable to a depositor, under-accrual
    /// strands them in the pool, and neither direction is the benign one.
    function optimize_feeAccrualDrift() public view returns (int256) {
        uint256 actual = masp.accruedFee(IERC20(address(token)));
        uint256 delta = actual > ghostAccrued ? actual - ghostAccrued : ghostAccrued - actual;
        return int256(delta);
    }
}
