// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { MockTreeUpdateVerifier } from "../mocks/MockTreeUpdateVerifier.sol";
import { deployBehindProxyAs, newPoolImplementation, poolInitCalldata, singleAsset } from "../utils/PoolDeployer.sol";
import { uniformBps } from "../utils/FeeArrays.sol";
import { DelayedUpgradeProxy } from "../../src/DelayedUpgradeProxy.sol";
import { EchidnaMaspPayer } from "./EchidnaMaspPayer.sol";

import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

/// Setup and shadow state for `EchidnaMasp`: constants, ghost bookkeeping, the
/// constructor that deploys the pool and its mocks, and helpers shared by more
/// than one handler module. See `EchidnaMasp.sol` for the target as a whole.
///
/// Split out of `EchidnaMasp.sol` for size only. All state lives here, in its
/// original declaration order, so the storage layout and the constructor's
/// deployment order (and hence every created address) are unchanged.
abstract contract EchidnaMaspBase {
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

        // The proxy admin is this contract rather than `TEST_PROXY_ADMIN`: the
        // guardian pause is `onlyAdmin` and Echidna cannot impersonate an
        // address, so this contract must be the admin to reach `pauseSpends`.
        bytes memory initData = poolInitCalldata(
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
        );
        proxy = DelayedUpgradeProxy(
            payable(deployBehindProxyAs(address(newPoolImplementation()), initData, address(this)))
        );
        masp = MASP(address(proxy));

        // One unlimited standing approval, granted by the payer itself, so
        // submits need no per-call approval.
        payer.exec(address(token), abi.encodeCall(IERC20.approve, (permit2, type(uint256).max)));

        ghostLastRoot = masp.currentRoot();
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
}
