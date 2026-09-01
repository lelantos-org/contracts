// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { CommitmentTree } from "./CommitmentTree.sol";
import { AssetRegistry } from "./AssetRegistry.sol";
import { NullifierSet } from "./NullifierSet.sol";
import { YieldIndex } from "./yield/YieldIndex.sol";
import { YieldOps } from "./yield/YieldOps.sol";
import { IVerifier } from "./interfaces/IVerifier.sol";
import { IBatchVerifier } from "./interfaces/IBatchVerifier.sol";
import { PubInputs } from "./libs/PubInputs.sol";
import { AuxValidation } from "./libs/AuxValidation.sol";
import { Fees } from "./libs/Fees.sol";

/// Multi-Asset Shielded Pool. Entry points:
///
/// - `deposit` — escrow funds via Permit2; no SNARK at submit.
/// - `flushBatch` — insert up to `MAX_L_BATCH / LEAVES_PER_DEPOSIT` escrowed
///   deposits under one `tree_update_batch` SNARK.
/// - `cancelDeposit` — refund the digest-bound payer after `cancelDelay`.
/// - `transfer` / `withdraw` — spends; verify `(4x6, tree_update_batch)`.
///
/// Token movement binds to `payer` (signature- or SNARK-bound), not
/// `msg.sender`, so any relayer may submit on a user's behalf. ERC-20 only;
/// native-coin wrapping lives in `NativeAdapter`.
contract MASP is CommitmentTree, AssetRegistry, NullifierSet, YieldIndex {
    using SafeERC20 for IERC20;
    using PubInputs for PubInputs.Transact;
    using PubInputs for PubInputs.TreeUpdateBatch;

    /// Verifier for `tree_update_batch.circom` (MAX_L = `PubInputs.MAX_L_BATCH`).
    /// Used by `flushBatch`, which carries a lone tree-update proof; a spend's
    /// tree-update proof is checked by `SPEND_VERIFIER`. "Batch" denotes a batch
    /// of leaves, not a batched pairing.
    IVerifier public immutable TREE_UPDATE_BATCH_VERIFIER;

    /// Checks the `(4x6, tree_update_batch)` proof pair a spend carries in one
    /// BN254 pairing call. Argument order is significant: transact first,
    /// tree-update second. This is the whole of a spend's proof check; the pool
    /// holds no standalone `4x6` verifier, and a rejection is not attributable
    /// to either proof on-chain.
    IBatchVerifier public immutable SPEND_VERIFIER;

    /// Width of the per-token fee accumulators in `flushBatch`: one slot per
    /// deposit, since a batch drains at most `MAX_L_BATCH / LEAVES_PER_DEPOSIT`
    /// deposits and cannot touch more distinct tokens. Duplicated here because
    /// Solidity rejects a library constant as a memory-array length; the
    /// constructor asserts it against the batch width.
    uint256 private constant FEE_ACC_SLOTS = 4;

    /// Output leaves per spend, i.e. `N_OUT` of the deployed transact shape.
    /// `tpi.actualCount` counts leaves, so the spend path pins it to this.
    ///
    /// The spend entry points spell their aux array `Output[6]` rather than
    /// `Output[PubInputs.TRANSACT_OUT]`, as Solidity rejects a library-qualified
    /// constant as an array length. Drift between the two fails to compile at
    /// `PubInputs.compress` and `AuxValidation.validate`.
    uint64 private constant TRANSACT_OUT_LEAVES = uint64(PubInputs.TRANSACT_OUT);
    /// Uniswap Permit2. Constructor reverts if the address holds no code.
    ISignatureTransfer public immutable PERMIT2;

    struct Proof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
    }

    /// Permit2 signature and the payer's signed ceiling. `maxTotal` caps the
    /// whole pull (`inAmt + fee + relayer note value`), bounding fee drift
    /// between signing and execution.
    struct Permit2Sig {
        uint256 nonce;
        uint256 deadline;
        uint256 maxTotal;
        bytes signature;
    }

    /// Permit2 witness binding. `piHash = keccak256(abi.encode(d, aux,
    /// feeAux))`. The inner `MASPDeposit(bytes32 piHash)` of the type string
    /// must match the typehash.
    bytes32 public constant DEPOSIT_WITNESS_TYPEHASH = keccak256("MASPDeposit(bytes32 piHash)");
    string public constant DEPOSIT_WITNESS_TYPE_STRING =
        "MASPDeposit witness)MASPDeposit(bytes32 piHash)TokenPermissions(address token,uint256 amount)";

    // ============== Escrow state =============================================

    /// Per-deposit escrow digest (see `_depositDigest`). Pending iff nonzero.
    /// All submit-time fields fold into the digest; flush and cancel resupply
    /// the preimage from `DepositEscrowed`, and keccak equality binds it.
    mapping(uint256 id => bytes32 digest) public escrowed;
    uint256 public nextDepositId;

    /// Digest fields not carried in `tpi`; verified against `escrowed[id]` in
    /// `_drainDeposit`. Sourced from the deposit's `DepositEscrowed` event
    /// (`submittedAt` = its block number).
    struct DepositMeta {
        address payer;
        uint32 submittedAt;
        uint16 fbps;
    }

    /// Blocks before `cancelDeposit` is allowed. Owner-tunable within
    /// `[CANCEL_DELAY_MIN, CANCEL_DELAY_MAX]`.
    uint32 public cancelDelay;
    uint32 internal constant CANCEL_DELAY_MIN = 3_600; // ~12h on 12s blocks
    uint32 internal constant CANCEL_DELAY_MAX = 50_400; // ~7d on 12s blocks
    uint32 internal constant CANCEL_DELAY_DEFAULT = 7_200; // ~24h on 12s blocks

    /// Emitted on shield and unshield; skipped for pure transfers
    /// (`in == out == 0`).
    ///
    /// `inAmount` / `outAmount` are the ERC-20 base units that moved;
    /// `publicIn` / `publicOut` are the circuit values the SNARK published. For
    /// a plain asset the two differ by `scale`; for a yield asset the conversion
    /// also applies the pool's index.
    event AssetMoved(
        uint64 indexed assetId,
        IERC20 indexed token,
        uint256 inAmount,
        uint256 outAmount,
        uint64 publicIn,
        uint64 publicOut
    );

    /// Encrypted-note payload for spend flows (FMD clue, ephemeral pubkey,
    /// ciphertext, Pedersen value commitment). Emitted once per output leaf.
    /// `cm` is indexed, so this also serves as the note-creation signal for
    /// indexers that track commitments only.
    event NotePayload(
        bytes32 indexed cm,
        uint256 clueRx,
        uint256 clueRy,
        uint256 ephPubX,
        uint256 ephPubY,
        bytes ciphertext,
        uint256 cvDepX,
        uint256 cvDepY
    );

    /// Escrow-flow note signal. Carries the per-deposit payload a relayer needs
    /// to assemble a `flushBatch`, including the deposit leaf's Pedersen value
    /// commitment `cvDep` and its blinder `rcv`. `NotePayload` is not emitted
    /// on this path.
    event DepositEscrowed(
        uint256 indexed id,
        address indexed payer,
        address indexed recipient,
        uint64 publicAssetId,
        uint64 publicIn,
        uint16 feeBpsAtSubmit,
        bytes32 cm,
        uint256 cvDepX,
        uint256 cvDepY,
        uint256 rcv,
        uint256 clueRx,
        uint256 clueRy,
        uint256 ephPubX,
        uint256 ephPubY,
        bytes ciphertext,
        // The relayer's fee note. Non-indexed: the three topic slots are taken,
        // and a relayer locates its note by trial decryption, so indexing would
        // publish the payee without aiding lookup.
        uint64 feeIn,
        bytes32 feeCm,
        uint256 feeCvDepX,
        uint256 feeCvDepY,
        uint256 feeRcv,
        uint256 feeClueRx,
        uint256 feeClueRy,
        uint256 feeEphPubX,
        uint256 feeEphPubY,
        bytes feeCiphertext
    );

    event DepositFlushed(uint256 indexed id, bytes32 cm);
    event DepositCanceled(uint256 indexed id, address indexed payer, uint256 refunded);
    event CancelDelayUpdated(uint32 oldDelay, uint32 newDelay);

    // --- request validation (calldata + storage shape) ----------------------
    error BadChainId();
    error ZeroRecipient();
    error ZeroPayer();
    error BadRelayer();
    error CmMismatch();
    // --- entry-point invariants ---------------------------------------------
    error MustHaveDeposit();
    error MustNotHaveDeposit();
    error MustHaveWithdraw();
    error MustNotHaveWithdraw();
    // --- merkle / batch state ------------------------------------------------
    error UnknownRoot();
    error StaleOldRoot();
    error BatchMisaligned();
    error TreeFull();
    // --- registry / proof verification ---------------------------------------
    error ZeroVerifier();
    /// `spendVerifier_` has code but does not answer `verifyBatch`.
    error BadSpendVerifier();
    error ZeroPermit2();
    error ProofRejected();
    error TreeUpdateRejected();
    // --- escrow flow ---------------------------------------------------------
    error PublicInTooLarge();
    error PublicOutTooLarge();
    error ZeroCm();
    error DepositNotPending(uint256 id);
    error BadBatchSize();
    error CancelTooEarly(uint256 id, uint256 unlockBlock);
    error BadCancelDelay();
    error PayerNotSender();
    error AmountOverflowsAllowance();
    error CvDepMismatch();
    error BadDepositMode();
    /// Caller-supplied digest preimage mismatch on flush/cancel.
    error DigestMismatch(uint256 id);

    constructor(
        IVerifier treeUpdateBatchVerifier_,
        IBatchVerifier spendVerifier_,
        ISignatureTransfer permit2_,
        uint64[] memory ids,
        IERC20[] memory tokens,
        uint256[] memory scales,
        uint16[] memory depositBps,
        uint16[] memory withdrawBps,
        address treasury_,
        address owner_
    ) Ownable(owner_) {
        if (address(treeUpdateBatchVerifier_).code.length == 0) revert ZeroVerifier();
        if (address(spendVerifier_).code.length == 0) revert ZeroVerifier();
        _probeSpendVerifier(spendVerifier_);
        if (address(permit2_).code.length == 0) revert ZeroPermit2();
        // Deploy-time guard for the duplicated batch width; see FEE_ACC_SLOTS.
        if (FEE_ACC_SLOTS * PubInputs.LEAVES_PER_DEPOSIT != PubInputs.MAX_L_BATCH) revert BadBatchSize();
        TREE_UPDATE_BATCH_VERIFIER = treeUpdateBatchVerifier_;
        SPEND_VERIFIER = spendVerifier_;
        PERMIT2 = permit2_;
        _initTreasury(treasury_);
        _writeAssets(ids, tokens, scales, depositBps, withdrawBps);
        cancelDelay = CANCEL_DELAY_DEFAULT;
    }

    function setCancelDelay(uint32 newDelay) external onlyOwner {
        if (newDelay < CANCEL_DELAY_MIN || newDelay > CANCEL_DELAY_MAX) revert BadCancelDelay();
        emit CancelDelayUpdated(cancelDelay, newDelay);
        cancelDelay = newDelay;
    }

    /// The rates `id` charges on each leg. Reverts `UnknownAsset` for an
    /// unregistered id.
    function assetFees(uint64 id) external view returns (uint16 depositBps, uint16 withdrawBps) {
        AssetEntry memory a = _getAsset(id);
        if (address(a.token) == address(0)) revert UnknownAsset(id);
        return (a.depositBps, a.withdrawBps);
    }

    /// Registers an asset whose custody earns in `venue`.
    ///
    /// The venue binding is permanent: `_addAsset` reverts `DuplicateAsset` on
    /// an existing id, so `params[id].venue` is written exactly once, and there
    /// is no `setVenue`. Replacing a venue means registering a new id.
    ///
    /// Yield is a property of the asset id, not of the note: the circuit sees
    /// only `publicAssetId`, and every note under an id shares one index. The
    /// plain id for the same token remains unlent custody, so a depositor opts
    /// in or out by choosing an id.
    ///
    /// Registration is post-deploy because a venue is pinned to this pool.
    function addYieldAsset(
        uint64 id,
        IERC20 token,
        uint256 scale,
        uint16 depositBps,
        uint16 withdrawBps,
        address venue_,
        uint16 bufferBps_,
        uint16 perfBps_
    ) external onlyOwner {
        _addAsset(id, token, scale, depositBps, withdrawBps);
        _initYieldAsset(id, token, venue_, bufferBps_, perfBps_);
    }

    /// `YieldIndex`'s view of the registry, used only by its external entry
    /// points; hot paths pass `scale` down from the `AssetEntry` they hold.
    function _yieldAsset(uint64 id) internal view override returns (IERC20 token, uint256 scale) {
        AssetEntry memory a = _getAsset(id);
        if (address(a.token) == address(0)) revert UnknownAsset(id);
        return (a.token, a.scale);
    }

    /// ERC-20 unshield. Pool pushes `outAmt - fee` to `pi.recipient`.
    function withdraw(
        Proof calldata p,
        PubInputs.Transact calldata pi,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[6] calldata aux
    ) external nonReentrant {
        if (pi.publicIn != 0) revert MustNotHaveDeposit();
        if (pi.publicOut == 0) revert MustHaveWithdraw();
        AssetEntry memory a = _preflight(pi, tpi, aux);
        _finalize(p, pi, tp, tpi, aux);
        uint256 outAmt;
        if (!isYieldAsset(pi.publicAssetId)) {
            outAmt = uint256(pi.publicOut) * a.scale;
            _unshieldLeg(a.token, pi.recipient, outAmt, a.withdrawBps);
        } else {
            outAmt = YieldOps.unshield(
                _y, pi.publicAssetId, a.token, a.scale, a.withdrawBps, pi.recipient, uint256(pi.publicOut)
            );
        }
        emit AssetMoved(pi.publicAssetId, a.token, 0, outAmt, 0, pi.publicOut);
        _emitNotes(pi, aux);
    }

    /// Internal transfer between shielded notes. No token movement.
    function transfer(
        Proof calldata p,
        PubInputs.Transact calldata pi,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[6] calldata aux
    ) external nonReentrant {
        if (pi.publicIn != 0) revert MustNotHaveDeposit();
        if (pi.publicOut != 0) revert MustNotHaveWithdraw();
        _validateRequest(pi, tpi, aux);
        // No tokens move; only the registry existence check applies.
        _requireAssetKnown(pi.publicAssetId);
        _finalize(p, pi, tp, tpi, aux);
        _emitNotes(pi, aux);
    }

    // ============== Escrow flow ==============================================

    /// Pull funds into escrow via Permit2; no SNARK at submit. Relayers read
    /// `DepositEscrowed` to assemble a `flushBatch`. A commitment that does not
    /// match its preimage costs only the depositor: the leaf carries no
    /// spendable witness.
    function deposit(
        PubInputs.DepositRequest calldata d,
        Permit2Sig calldata sig,
        AuxValidation.Output calldata aux,
        AuxValidation.Output calldata feeAux
    ) external nonReentrant returns (uint256 id) {
        AssetEntry memory a = _validateDeposit(d, aux, feeAux);
        Shield memory s = _quoteShield(d, a);
        _permit2Pull(a.token, d.payer, sig, s.total, keccak256(abi.encode(d, aux, feeAux)));
        _settleShield(d.publicAssetId, a.token, s);
        id = _finalizeDeposit(d, aux, feeAux, a, s.inAmt, a.depositBps);
    }

    /// Permit2 AllowanceTransfer deposit. The user pre-signs a `PermitSingle`
    /// covering N future deposits; each pulls via `transferFrom` with no
    /// per-transaction signature. Requires `msg.sender == d.payer`; Permit2
    /// enforces the signed cap and expiration.
    function depositAuthorized(
        PubInputs.DepositRequest calldata d,
        AuxValidation.Output calldata aux,
        AuxValidation.Output calldata feeAux
    ) external nonReentrant returns (uint256 id) {
        AssetEntry memory a = _validateDeposit(d, aux, feeAux);
        if (msg.sender != d.payer) revert PayerNotSender();

        Shield memory s = _quoteShield(d, a);
        if (s.total > type(uint160).max) revert AmountOverflowsAllowance();

        // forge-lint: disable-next-line(unsafe-typecast)
        IAllowanceTransfer(address(PERMIT2)).transferFrom(d.payer, address(this), uint160(s.total), address(a.token));
        _settleShield(d.publicAssetId, a.token, s);
        id = _finalizeDeposit(d, aux, feeAux, a, s.inAmt, a.depositBps);
    }

    /// A priced shield, carried between the quote and the pull. The two deposit
    /// entry points differ only in how tokens move, so pricing and settlement
    /// are shared.
    struct Shield {
        /// What the payer is charged: principal, treasury fee and relayer note.
        uint256 total;
        /// Principal alone, which is what `AssetMoved` reports.
        uint256 inAmt;
        /// Normalized units the pool takes on. Unused for a plain asset.
        uint256 units;
        /// `gross` as of the quote, so settlement need not read the venue
        /// again.
        uint256 grossBefore;
        /// Zero for a plain asset. Carried so settlement branches on the value
        /// the quote already read.
        address venue;
    }

    /// Prices a shield under the asset's arithmetic.
    ///
    /// The indexed branch charges its fee in normalized units and converts once
    /// on the total, rounding on a coarser grid than the plain branch; hence the
    /// unit fee rounds up where the plain fee floors. See `Fees.unitFee`.
    function _quoteShield(PubInputs.DepositRequest calldata d, AssetEntry memory a) private returns (Shield memory s) {
        s.venue = _y.params[d.publicAssetId].venue;
        if (s.venue == address(0)) {
            (uint256 inAmt, uint256 fee) = _computeAmounts(d.publicIn, a.scale, a.depositBps);
            s.inAmt = inAmt;
            s.total = inAmt + fee + _relayerAmount(d.feeIn, a.scale);
        } else {
            (s.total, s.inAmt, s.units, s.grossBefore) =
                YieldOps.quoteShield(_y, d.publicAssetId, a.scale, a.depositBps, d.publicIn, d.feeIn);
        }
    }

    /// Book a pulled shield. A plain asset has nothing to book: its backing is
    /// the pool's balance and its fee does not accrue until flush.
    function _settleShield(uint64 assetId, IERC20 token, Shield memory s) private {
        if (s.venue == address(0)) return;
        YieldOps.settleShield(_y, assetId, token, s.total, s.units, s.grossBefore);
    }

    /// Shared validation for `deposit*`. Returns resolved asset entry.
    function _validateDeposit(
        PubInputs.DepositRequest calldata d,
        AuxValidation.Output calldata aux,
        AuxValidation.Output calldata feeAux
    ) private view returns (AssetEntry memory a) {
        if (d.chainId != block.chainid) revert BadChainId();
        if (d.publicIn == 0) revert MustHaveDeposit();
        if (d.publicIn > type(uint48).max) revert PublicInTooLarge();
        if (d.payer == address(0)) revert ZeroPayer();
        if (d.recipient == address(0)) revert ZeroRecipient();
        if (d.outCm == bytes32(0)) revert ZeroCm();

        // The fee note's value may be zero, but the leaf must be well formed.
        // `_drainDeposit` narrows this to uint48, as it does `publicIn`.
        if (d.feeIn > type(uint48).max) revert PublicInTooLarge();
        if (d.feeCm == bytes32(0)) revert ZeroCm();

        a = _getAsset(d.publicAssetId);
        if (address(a.token) == address(0)) revert UnknownAsset(d.publicAssetId);
        if (a.disabled) revert AssetDisabled(d.publicAssetId);
        AuxValidation.validate(aux);
        AuxValidation.validate(feeAux);
    }

    /// Shared escrow record and event emit for `deposit*`. The caller must
    /// already have pulled `inAmt + fee + relayer note value` of `a.token` into
    /// the pool. Only the treasury's `fee` accrues, and only at flush; the
    /// relayer's portion stays principal backing its note.
    function _finalizeDeposit(
        PubInputs.DepositRequest calldata d,
        AuxValidation.Output calldata aux,
        AuxValidation.Output calldata feeAux,
        AssetEntry memory a,
        uint256 inAmt,
        uint16 fbps
    ) private returns (uint256 id) {
        unchecked {
            id = nextDepositId++;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        escrowed[id] = _depositDigest(
            id,
            d.outCm,
            d.cvDep,
            d.publicAssetId,
            uint48(d.publicIn),
            fbps,
            d.payer,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32(block.number),
            // forge-lint: disable-next-line(unsafe-typecast)
            PubInputs.FeeNote({ feeIn: uint48(d.feeIn), feeCm: d.feeCm, feeCvDep: d.feeCvDep })
        );

        emit DepositEscrowed(
            id,
            d.payer,
            d.recipient,
            d.publicAssetId,
            d.publicIn,
            fbps,
            d.outCm,
            d.cvDep[0],
            d.cvDep[1],
            d.rcv,
            aux.clueRx,
            aux.clueRy,
            aux.ephPubX,
            aux.ephPubY,
            aux.ciphertext,
            d.feeIn,
            d.feeCm,
            d.feeCvDep[0],
            d.feeCvDep[1],
            d.feeRcv,
            feeAux.clueRx,
            feeAux.clueRy,
            feeAux.ephPubX,
            feeAux.ephPubY,
            feeAux.ciphertext
        );
        emit AssetMoved(d.publicAssetId, a.token, inAmt, 0, d.publicIn, 0);
    }

    /// Insert escrowed deposits under one batched SNARK. `tpi` and `meta`
    /// mirror the per-deposit payloads in `ids` order; the circuit enforces
    /// `isDeposit` on active slots and zeros for padding.
    ///
    /// A deposit occupies `LEAVES_PER_DEPOSIT` adjacent leaves — its principal
    /// and the note paying the flusher — so deposit `i` owns leaves `2i` and
    /// `2i + 1` and the batch advances the tree by `2n`. One batch holds
    /// `MAX_L_BATCH / LEAVES_PER_DEPOSIT` deposits.
    function flushBatch(
        uint256[] calldata ids,
        DepositMeta[] calldata meta,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi
    ) external nonReentrant {
        uint256 n = ids.length;
        if (meta.length != n) revert BadBatchSize();
        _validateBatchHeader(n, tpi);

        // Per-token fee accumulator; width is constructor-checked against
        // `PubInputs.MAX_L_BATCH`. See FEE_ACC_SLOTS.
        // slither-disable-next-line uninitialized-local
        IERC20[FEE_ACC_SLOTS] memory tokens;
        // slither-disable-next-line uninitialized-local
        uint256[FEE_ACC_SLOTS] memory fees;
        uint256 nUnique = 0;

        // Phase 1: drain each active slot, accumulate fee per token.
        for (uint256 i = 0; i < n; ++i) {
            nUnique = _drainDeposit(ids[i], i, tpi, meta[i], tokens, fees, nUnique);
        }

        // Phase 2: accrue fees, one SSTORE per unique token.
        for (uint256 j = 0; j < nUnique; ++j) {
            _accrueFee(tokens[j], fees[j]);
        }

        // Phase 3: verify batched SNARK and advance tree by n leaves.
        if (!TREE_UPDATE_BATCH_VERIFIER.verifyProof(tp.a, tp.b, tp.c, tpi.compress())) {
            revert TreeUpdateRejected();
        }
        unchecked {
            _advanceRoot(tpi.newRoot, uint64(n * PubInputs.LEAVES_PER_DEPOSIT), tpi.oldRoot);
        }
    }

    /// Batch-level header checks: size, count alignment, tree position.
    ///
    /// `n` counts deposits; the batch commits `LEAVES_PER_DEPOSIT * n` leaves,
    /// as each deposit mints the depositor's note and the relayer's fee note.
    function _validateBatchHeader(uint256 n, PubInputs.TreeUpdateBatch calldata tpi) private view {
        uint256 leaves = n * PubInputs.LEAVES_PER_DEPOSIT;
        if (n == 0 || leaves > PubInputs.MAX_L_BATCH) revert BadBatchSize();
        if (uint256(tpi.actualCount) != leaves) revert BatchMisaligned();
        _requireTreePosition(tpi, leaves);
    }

    /// Places a batch at the tree's frontier: it must extend the live root,
    /// start where the tree is committed to, and fit. Shared by the spend and
    /// flush paths, which differ only in the leaf count.
    function _requireTreePosition(PubInputs.TreeUpdateBatch calldata tpi, uint256 leaves) private view {
        if (tpi.oldRoot != currentRoot()) revert StaleOldRoot();
        uint64 cc = committedCount;
        if (tpi.startIndex != cc) revert BatchMisaligned();
        if (uint256(cc) + leaves > MAX_LEAVES) revert TreeFull();
    }

    /// Validate one deposit against its `tpi` slot and `meta`, accumulate its
    /// fee under its token, then emit and delete the escrow. Returns the
    /// updated unique-token count. Digest equality binds every calldata field,
    /// asset included.
    function _drainDeposit(
        uint256 id,
        uint256 i,
        PubInputs.TreeUpdateBatch calldata tpi,
        DepositMeta calldata m,
        IERC20[FEE_ACC_SLOTS] memory tokens,
        uint256[FEE_ACC_SLOTS] memory fees,
        uint256 nUnique
    ) private returns (uint256) {
        bytes32 stored = escrowed[id];
        // Zero is the sentinel for "no pending deposit": a presence test, not
        // arithmetic on an attacker-movable quantity. The `delete` below
        // restores it, rejecting a repeated id within one batch.
        // slither-disable-next-line incorrect-equality
        if (stored == bytes32(0)) revert DepositNotPending(id);

        // Deposit `i` owns two adjacent leaves: its principal, then the note
        // paying the flusher. Both are deposit leaves to the circuit, which
        // binds each `cvDep` to its own `leafPublicIn`.
        uint256 p = i * PubInputs.LEAVES_PER_DEPOSIT;
        uint256 f = p + 1;
        if (tpi.isDeposit[p] != 1 || tpi.isDeposit[f] != 1) revert BadDepositMode();
        if (tpi.leafPublicIn[p] > type(uint48).max) revert PublicInTooLarge();
        if (tpi.leafPublicIn[f] > type(uint48).max) revert PublicInTooLarge();
        // The fee note is in the deposit's own asset, so one registry lookup
        // serves both leaves and a mismatched fee asset fails the digest.
        if (tpi.leafAsset[f] != tpi.leafAsset[p]) revert DigestMismatch(id);

        // Reconstruct the submit-time digest; one equality binds all fields.
        uint64 assetId = tpi.leafAsset[p];
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 expected = _depositDigest(
            id,
            tpi.cms[p],
            tpi.cvDeps[p],
            assetId,
            uint48(tpi.leafPublicIn[p]),
            m.fbps,
            m.payer,
            m.submittedAt,
            // forge-lint: disable-next-line(unsafe-typecast)
            PubInputs.FeeNote({ feeIn: uint48(tpi.leafPublicIn[f]), feeCm: tpi.cms[f], feeCvDep: tpi.cvDeps[f] })
        );
        if (expected != stored) revert DigestMismatch(id);

        AssetEntry memory a = _getAsset(assetId);

        // Only the treasury's cut is accrued. The relayer's stays pool
        // principal: a shielded note is spendable only while the pool still
        // holds the tokens behind it.
        uint256 newCount;
        if (!isYieldAsset(assetId)) {
            (, uint256 fee) = _computeAmounts(uint256(tpi.leafPublicIn[p]), a.scale, uint256(m.fbps));
            uint256 slot;
            (slot, newCount) = _findOrAppendToken(tokens, nUnique, a.token);
            fees[slot] += fee;
        } else {
            // Recomputed in normalized units, without `scale` or the index, so
            // it reproduces what submit charged and keeps the index out of the
            // escrow digest.
            //
            // Settled per deposit rather than batched: the accumulator is keyed
            // by ERC-20, and a plain id and a yield id may share one token.
            uint256 nFee = Fees.unitFee(uint256(tpi.leafPublicIn[p]), uint256(m.fbps));
            if (nFee != 0) {
                // Supply-neutral: the units move from holders to the treasury
                // rather than being created.
                _y.totalNormalized[assetId] -= nFee;
                _y.accruedFeeNormalized[assetId] += nFee;
            }
            newCount = nUnique;
        }

        emit DepositFlushed(id, tpi.cms[p]);
        delete escrowed[id];
        return newCount;
    }

    /// Preimage for `escrowed[id]`, shared by submit, flush and cancel.
    /// `(address(this), block.chainid, id)` is the anti-replay prefix.
    function _depositDigest(
        uint256 id,
        bytes32 cm,
        uint256[2] memory cvDep,
        uint64 publicAssetId,
        uint48 publicIn,
        uint16 feeBpsAtSubmit,
        address payer,
        uint32 submittedAt,
        PubInputs.FeeNote memory fee
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                id,
                cm,
                cvDep,
                publicAssetId,
                publicIn,
                feeBpsAtSubmit,
                payer,
                submittedAt,
                // The relayer's leaf is bound like the depositor's:
                // `flushBatch` supplies both from calldata, so an unbound fee
                // note would let a flusher mint itself an arbitrary one.
                // `FeeNote` is static and encodes to four words in place.
                fee
            )
        );
    }

    function _findOrAppendToken(IERC20[FEE_ACC_SLOTS] memory tokens, uint256 nUnique, IERC20 token)
        private
        pure
        returns (uint256 slot, uint256 newCount)
    {
        for (uint256 j = 0; j < nUnique; ++j) {
            if (address(tokens[j]) == address(token)) return (j, nUnique);
        }
        tokens[nUnique] = token;
        return (nUnique, nUnique + 1);
    }

    /// Refunds the digest-bound payer after `cancelDelay`. The caller
    /// resupplies the digest preimage from the deposit's `DepositEscrowed` event
    /// (`submittedAt` = its block number); keccak equality binds every value to
    /// submit time.
    ///
    /// Permissionless for EOA payers, since a Permit2 signer need never send a
    /// transaction itself. Contract payers must call this themselves: the refund
    /// goes to the payer, not to whoever funded it, so the payer must observe it
    /// arriving. `NativeAdapter` is such a payer — a refund delivered by a
    /// third-party call is indistinguishable on-chain from a flushed deposit and
    /// would strand the funder's claim.
    function cancelDeposit(
        uint256 id,
        uint48 publicIn,
        bytes32 cm,
        uint256[2] calldata cvDep,
        uint64 publicAssetId,
        uint16 fbps,
        address payer,
        uint32 submittedAt,
        PubInputs.FeeNote calldata feeNote
    ) external nonReentrant {
        bytes32 stored = escrowed[id];
        if (stored == bytes32(0)) revert DepositNotPending(id);

        bytes32 expected = _depositDigest(id, cm, cvDep, publicAssetId, publicIn, fbps, payer, submittedAt, feeNote);
        if (expected != stored) revert DigestMismatch(id);

        // `payer` is digest-verified above, so this is the real payer, not a
        // caller-chosen one. An EIP-7702 delegated EOA carries code and is
        // treated as a contract payer: it loses relayed cancellation, not
        // access.
        if (payer.code.length != 0 && msg.sender != payer) revert PayerNotSender();

        // `submittedAt` is digest-verified, so it is sound for the delay check.
        uint256 unlockBlock = uint256(submittedAt) + uint256(cancelDelay);
        if (block.number < unlockBlock) revert CancelTooEarly(id, unlockBlock);

        AssetEntry memory a = _getAsset(publicAssetId);
        uint256 total;
        if (!isYieldAsset(publicAssetId)) {
            (uint256 inAmt, uint256 fee) = _computeAmounts(uint256(publicIn), a.scale, uint256(fbps));
            // The relayer's portion refunds with the rest: no leaf was minted,
            // so the fee was never earned.
            total = inAmt + fee + _relayerAmount(uint256(feeNote.feeIn), a.scale);
        } else {
            // Refunded at the current index, including what the escrowed funds
            // earned in the venue, matching the liability released.
            //
            // This external call precedes the `escrowed` clear below. The
            // reentrancy guard is contract-wide, so the cross-function
            // reentrancy slither reports here is unreachable: re-entry through
            // the venue or the token reverts before it can observe the stale
            // entry.
            // slither-disable-next-line reentrancy-no-eth
            total =
                YieldOps.cancel(_y, publicAssetId, a.scale, uint256(publicIn), uint256(fbps), uint256(feeNote.feeIn));
        }

        // CEI: clear escrow before external transfer.
        delete escrowed[id];

        a.token.safeTransfer(payer, total);
        emit DepositCanceled(id, payer, total);
    }

    // ============== Internal helpers =========================================

    /// `inAmt = publicIn * scale`, `fee = inAmt * fbps / BPS`.
    function _computeAmounts(uint256 publicIn, uint256 scale, uint256 fbps)
        private
        pure
        returns (uint256 inAmt, uint256 fee)
    {
        inAmt = publicIn * scale;
        fee = (inAmt * fbps) / BPS_DENOMINATOR;
    }

    /// Token amount backing the relayer's fee note. Never accrued: it stays
    /// pool principal, since a shielded note is spendable only while the pool
    /// holds the tokens behind it. Charged on top of `inAmt + fee`.
    function _relayerAmount(uint256 feeIn, uint256 scale) private pure returns (uint256) {
        return feeIn * scale;
    }

    /// Call Permit2 `permitWitnessTransferFrom` with the deposit witness.
    function _permit2Pull(IERC20 token, address payerAddr, Permit2Sig calldata sig, uint256 total, bytes32 piHash)
        private
    {
        bytes32 witness = keccak256(abi.encode(DEPOSIT_WITNESS_TYPEHASH, piHash));
        PERMIT2.permitWitnessTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({ token: address(token), amount: sig.maxTotal }),
                nonce: sig.nonce,
                deadline: sig.deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: total }),
            payerAddr,
            witness,
            DEPOSIT_WITNESS_TYPE_STRING,
            sig.signature
        );
    }

    /// Spend-side preflight: validate the request shape and resolve the asset.
    function _preflight(
        PubInputs.Transact calldata pi,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[6] calldata aux
    ) private view returns (AssetEntry memory a) {
        _validateRequest(pi, tpi, aux);
        a = _getAsset(pi.publicAssetId);
        if (address(a.token) == address(0)) revert UnknownAsset(pi.publicAssetId);
    }

    function _finalize(
        Proof calldata p,
        PubInputs.Transact calldata pi,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[6] calldata aux
    ) private {
        _verifyProofs(p, pi, tp, tpi, aux);
        for (uint256 k = 0; k < PubInputs.TRANSACT_IN; ++k) {
            _consumeNullifier(pi.nullifier[k]);
        }
        _advanceRoot(tpi.newRoot, TRANSACT_OUT_LEAVES, tpi.oldRoot);
    }

    /// Spend-side request validation. This function, not the circuit,
    /// cross-binds the two independent Groth16 proofs: it equates the spend's
    /// `pi.outCm` and `pi.outCvDep` with the tree-update's `tpi.cms` and
    /// `tpi.cvDeps`, and pins `tpi.isDeposit` to 0. `actualCount` counts
    /// leaves, so it is pinned to `TRANSACT_OUT_LEAVES`.
    function _validateRequest(
        PubInputs.Transact calldata pi,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[6] calldata aux
    ) private view {
        if (pi.chainId != block.chainid) revert BadChainId();
        if (pi.recipient == address(0)) revert ZeroRecipient();
        if (pi.payer == address(0)) revert ZeroPayer();
        if (pi.relayer != msg.sender) revert BadRelayer();
        // Pairwise across all inputs: a nullifier repeated in any two slots
        // would spend one note twice within a single transaction.
        for (uint256 a = 0; a < PubInputs.TRANSACT_IN; ++a) {
            for (uint256 b = a + 1; b < PubInputs.TRANSACT_IN; ++b) {
                if (pi.nullifier[a] == pi.nullifier[b]) revert DuplicateNullifier();
            }
        }
        if (pi.publicOut > type(uint48).max) revert PublicOutTooLarge();
        // Cross-bind the separate Groth16 proofs: the spend's `pi` against the
        // tree-update's `tpi`.
        if (tpi.actualCount != TRANSACT_OUT_LEAVES) revert BatchMisaligned();
        // Both arrays are indexed by output and are checked over the full
        // shape. `cv_dep` is part of the leaf preimage
        // (`leaf = Poseidon(TAG_LEAF, cm, cv_dep_x, cv_dep_y)`) and
        // `spent.circom` recomputes it from the note's own (asset, value, rcv).
        // An unbound output index would let a relayer insert a leaf under a
        // `cv_dep` the recipient cannot reproduce, consuming the inputs and
        // leaving the output permanently unspendable.
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; ++k) {
            if (pi.outCm[k] != tpi.cms[k]) revert CmMismatch();
            if (pi.outCvDep[k][0] != tpi.cvDeps[k][0] || pi.outCvDep[k][1] != tpi.cvDeps[k][1]) {
                revert CvDepMismatch();
            }
        }
        // The batch circuit cannot distinguish a spend leaf from a deposit leaf
        // and does not force `is_deposit = 0`. Deposit binding is per-leaf
        // (`cv_dep == leaf_public_in·V^leaf_asset + rcv·H`), so a spend output
        // could satisfy it by declaring its own (asset, value) and publishing
        // the note's opening in the compressed public inputs. Pinned here.
        for (uint256 k = 0; k < TRANSACT_OUT_LEAVES; ++k) {
            if (tpi.isDeposit[k] != 0) revert BadDepositMode();
        }
        AuxValidation.validate(aux);

        if (!isKnownRoot[pi.merkleRoot]) revert UnknownRoot();
        _requireTreePosition(tpi, TRANSACT_OUT_LEAVES);
    }

    /// Reverts unless `bv` answers `verifyBatch`. The slot is immutable, so a
    /// wrong address would otherwise make every spend revert with nothing
    /// identifying the cause. The return value is ignored: the probe establishes
    /// the interface, not a verdict.
    function _probeSpendVerifier(IBatchVerifier bv) private view {
        // Zero-valued probe arguments; memory is already zeroed.
        // slither-disable-next-line uninitialized-local
        uint256[2] memory g1;
        // slither-disable-next-line uninitialized-local
        uint256[2][2] memory g2;
        // slither-disable-next-line unused-return
        try bv.verifyBatch(g1, g2, g1, g1, g1, g2, g1, g1) returns (bool) { }
        catch {
            revert BadSpendVerifier();
        }
    }

    /// Verifies both Groth16 proofs (`4x6` and `tree_update_batch`) in a single
    /// pairing check. Public inputs are Fiat-Shamir-compressed to `(y, z)`
    /// beforehand.
    ///
    /// `verifyBatch` returns one bool for both proofs, so a rejection always
    /// surfaces as `ProofRejected`; `TreeUpdateRejected` is the flush-path
    /// error.
    ///
    /// The call must stay high-level with these exact static parameters:
    /// `BatchedGroth16Verifier` pins `calldatasize` to `4 + 20 * 32` and hashes
    /// that calldata verbatim as its transcript. Slot order is significant:
    /// transact first, tree-update second.
    function _verifyProofs(
        Proof calldata p,
        PubInputs.Transact calldata pi,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[6] calldata aux
    ) private view {
        if (!SPEND_VERIFIER.verifyBatch(p.a, p.b, p.c, PubInputs.compress(pi, aux), tp.a, tp.b, tp.c, tpi.compress())) {
            revert ProofRejected();
        }
    }

    /// Spend-path note emit, common to every entry point. `AssetMoved` is left
    /// to the unshield paths: every spend forces `publicIn == 0`, so the shield
    /// side is always zero and `transfer` moves no tokens.
    function _emitNotes(PubInputs.Transact calldata pi, AuxValidation.Output[6] calldata aux) private {
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; ++k) {
            AuxValidation.Output calldata a = aux[k];
            emit NotePayload(
                pi.outCm[k],
                a.clueRx,
                a.clueRy,
                a.ephPubX,
                a.ephPubY,
                a.ciphertext,
                pi.outCvDep[k][0],
                pi.outCvDep[k][1]
            );
        }
    }

    /// Sends `outAmt - fee` to `recipient` and accrues `fee`. The rate arrives
    /// as an argument, from the `AssetEntry` `_preflight` already loaded.
    ///
    /// The rate is read at execution and is bound by nothing the spender signed,
    /// so raising `withdrawBps` reaches spends already proven but not yet
    /// mined.
    function _unshieldLeg(IERC20 token, address recipient, uint256 outAmt, uint16 fbps) private {
        uint256 fee = (outAmt * fbps) / BPS_DENOMINATOR;
        uint256 net = outAmt - fee;
        _accrueFee(token, fee);
        token.safeTransfer(recipient, net);
    }
}
