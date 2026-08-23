// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { CommitmentTree } from "./CommitmentTree.sol";
import { AssetRegistry } from "./AssetRegistry.sol";
import { NullifierSet } from "./NullifierSet.sol";
import { FeeConfig } from "./FeeConfig.sol";
import { IVerifier } from "./interfaces/IVerifier.sol";
import { IBatchVerifier } from "./interfaces/IBatchVerifier.sol";
import { PubInputs } from "./libs/PubInputs.sol";
import { AuxValidation } from "./libs/AuxValidation.sol";

/// Multi-Asset Shielded Pool. Entry points:
/// * `deposit` — escrow funds via Permit2; no SNARK at submit.
/// * `flushBatch` — insert up to `PubInputs.MAX_L_BATCH` escrowed deposits
///   under one `tree_update_batch` SNARK.
/// * `cancelDeposit` — refund the digest-bound payer after `cancelDelay`.
/// * `transfer` / `withdraw` — spend operations; verify
///   `(transact_3x3, tree_update_batch)`.
///
/// Token movement binds to `payer` (signature- or SNARK-bound), not
/// `msg.sender`, so any relayer may submit for a user. ERC-20 only; native-coin
/// wrapping and unwrapping live in `NativeAdapter`.
contract MASP is CommitmentTree, AssetRegistry, NullifierSet, FeeConfig {
    using SafeERC20 for IERC20;
    using PubInputs for PubInputs.Transact;
    using PubInputs for PubInputs.TreeUpdateBatch;

    /// Verifier for `tree_update_batch.circom` (MAX_L = `PubInputs.MAX_L_BATCH`).
    /// Used by `flushBatch`, which carries a lone tree-update proof. A spend's
    /// tree-update proof is checked by `SPEND_VERIFIER` instead.
    ///
    /// The "batch" here is a batch of leaves, not the batched pairing
    /// `SPEND_VERIFIER` performs.
    IVerifier public immutable TREE_UPDATE_BATCH_VERIFIER;

    /// Checks the `(transact_3x3, tree_update_batch)` proof pair a spend
    /// carries, in one BN254 pairing call. Argument order is load-bearing:
    /// transact first, tree-update second.
    ///
    /// This is the entirety of a spend's proof check; the pool holds no
    /// standalone `transact_3x3` verifier. Attributing a rejection to one of
    /// the two proofs is a submitter-side concern, handled off-chain.
    IBatchVerifier public immutable SPEND_VERIFIER;

    /// Width of the per-token fee accumulators in `flushBatch`. Solidity does
    /// not accept a library constant as a memory-array length, so the value is
    /// duplicated here; the constructor asserts it equals
    /// `PubInputs.MAX_L_BATCH`.
    uint256 private constant FEE_ACC_SLOTS = 4;

    /// Output leaves per spend, i.e. `N_OUT` of the deployed transact shape.
    /// `tpi.actualCount` counts leaves, so the spend path pins it to this.
    uint64 private constant TRANSACT_OUT_LEAVES = uint64(PubInputs.TRANSACT_OUT);
    /// Uniswap Permit2. Constructor reverts if the address holds no code.
    ISignatureTransfer public immutable PERMIT2;

    struct Proof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
    }

    /// Permit2 signature plus the payer's signed ceiling. `maxTotal` caps
    /// `inAmt + fee`, bounding fee changes between submit and pull.
    struct Permit2Sig {
        uint256 nonce;
        uint256 deadline;
        uint256 maxTotal;
        bytes signature;
    }

    /// Permit2 witness binding. `piHash = keccak256(abi.encode(d, aux))`.
    /// The inner `MASPDeposit(bytes32 piHash)` of the type string must match
    /// the typehash.
    bytes32 public constant DEPOSIT_WITNESS_TYPEHASH = keccak256("MASPDeposit(bytes32 piHash)");
    string public constant DEPOSIT_WITNESS_TYPE_STRING =
        "MASPDeposit witness)MASPDeposit(bytes32 piHash)TokenPermissions(address token,uint256 amount)";

    // ============== Escrow state =============================================

    /// Per-deposit escrow digest (see `_depositDigest`). Pending iff nonzero.
    /// All submit-time fields fold into the digest; flush and cancel resupply
    /// the preimage from `DepositEscrowed`, and keccak equality binds it.
    mapping(uint256 id => bytes32 digest) public escrowed;
    uint256 public nextDepositId;

    /// Digest fields not carried in `tpi`; verified against `escrowed[id]`
    /// in `_drainDeposit`. Sourced from the deposit's `DepositEscrowed` event
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
    event AssetMoved(uint64 indexed assetId, IERC20 indexed token, uint256 inAmount, uint256 outAmount);

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
    /// commitment `cvDep` and its blinder `rcv`. `NotePayload` is not emitted on
    /// this path.
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
        bytes ciphertext
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
        uint16 feeBps_,
        address treasury_,
        address owner_
    ) Ownable(owner_) {
        if (address(treeUpdateBatchVerifier_).code.length == 0) revert ZeroVerifier();
        if (address(spendVerifier_).code.length == 0) revert ZeroVerifier();
        _probeSpendVerifier(spendVerifier_);
        if (address(permit2_).code.length == 0) revert ZeroPermit2();
        // Deploy-time guard for the duplicated batch width; see FEE_ACC_SLOTS.
        if (FEE_ACC_SLOTS != PubInputs.MAX_L_BATCH) revert BadBatchSize();
        TREE_UPDATE_BATCH_VERIFIER = treeUpdateBatchVerifier_;
        SPEND_VERIFIER = spendVerifier_;
        PERMIT2 = permit2_;
        _initFee(feeBps_, treasury_);
        _writeAssets(ids, tokens, scales);
        cancelDelay = CANCEL_DELAY_DEFAULT;
    }

    function setCancelDelay(uint32 newDelay) external onlyOwner {
        if (newDelay < CANCEL_DELAY_MIN || newDelay > CANCEL_DELAY_MAX) revert BadCancelDelay();
        emit CancelDelayUpdated(cancelDelay, newDelay);
        cancelDelay = newDelay;
    }

    /// ERC-20 unshield. Pool pushes `outAmt - fee` to `pi.recipient`.
    function withdraw(
        Proof calldata p,
        PubInputs.Transact calldata pi,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[3] calldata aux
    ) external nonReentrant {
        if (pi.publicIn != 0) revert MustNotHaveDeposit();
        if (pi.publicOut == 0) revert MustHaveWithdraw();
        AssetEntry memory a = _preflight(pi, tpi, aux);
        _finalize(p, pi, tp, tpi, aux);
        uint256 outAmt = uint256(pi.publicOut) * a.scale;
        _unshieldLeg(a.token, pi.recipient, outAmt);
        emit AssetMoved(pi.publicAssetId, a.token, 0, outAmt);
        _emitNotes(pi, aux);
    }

    /// Internal transfer between shielded notes. No token movement.
    function transfer(
        Proof calldata p,
        PubInputs.Transact calldata pi,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[3] calldata aux
    ) external nonReentrant {
        if (pi.publicIn != 0) revert MustNotHaveDeposit();
        if (pi.publicOut != 0) revert MustNotHaveWithdraw();
        _validateRequest(pi, tpi, aux);
        // No tokens move, so neither `token` nor `scale` is read; only the
        // registry existence check applies. `_requireAssetKnown` touches slot 0
        // alone, avoiding the cold SLOAD of the `scale` slot performed by
        // `_getAsset`.
        _requireAssetKnown(pi.publicAssetId);
        _finalize(p, pi, tp, tpi, aux);
        _emitNotes(pi, aux);
    }

    // ============== Escrow flow ==============================================

    /// Pull funds into escrow via Permit2; no SNARK at submit. Relayers read
    /// `DepositEscrowed` to assemble a `flushBatch`. A commitment that does not
    /// match its preimage costs only the depositor: the leaf carries no
    /// spendable witness.
    function deposit(PubInputs.DepositRequest calldata d, Permit2Sig calldata sig, AuxValidation.Output calldata aux)
        external
        nonReentrant
        returns (uint256 id)
    {
        AssetEntry memory a = _validateDeposit(d, aux);
        uint16 fbps = feeBps;
        (uint256 inAmt, uint256 fee) = _computeAmounts(d.publicIn, a.scale, fbps);
        _permit2Pull(a.token, d.payer, sig, inAmt + fee, keccak256(abi.encode(d, aux)));
        id = _finalizeDeposit(d, aux, a, inAmt, fbps);
    }

    /// Permit2 AllowanceTransfer deposit. The user pre-signs a `PermitSingle`
    /// covering N future deposits; each pulls via `transferFrom` with no
    /// per-transaction signature. Requires `msg.sender == d.payer`; Permit2
    /// enforces the signed cap and expiration.
    function depositAuthorized(PubInputs.DepositRequest calldata d, AuxValidation.Output calldata aux)
        external
        nonReentrant
        returns (uint256 id)
    {
        AssetEntry memory a = _validateDeposit(d, aux);
        if (msg.sender != d.payer) revert PayerNotSender();

        uint16 fbps = feeBps;
        (uint256 inAmt, uint256 fee) = _computeAmounts(d.publicIn, a.scale, fbps);
        uint256 total = inAmt + fee;
        if (total > type(uint160).max) revert AmountOverflowsAllowance();

        // forge-lint: disable-next-line(unsafe-typecast)
        IAllowanceTransfer(address(PERMIT2)).transferFrom(d.payer, address(this), uint160(total), address(a.token));
        id = _finalizeDeposit(d, aux, a, inAmt, fbps);
    }

    /// Shared validation for `deposit*`. Returns resolved asset entry.
    function _validateDeposit(PubInputs.DepositRequest calldata d, AuxValidation.Output calldata aux)
        private
        view
        returns (AssetEntry memory a)
    {
        if (d.chainId != block.chainid) revert BadChainId();
        if (d.publicIn == 0) revert MustHaveDeposit();
        if (d.publicIn > type(uint48).max) revert PublicInTooLarge();
        if (d.payer == address(0)) revert ZeroPayer();
        if (d.recipient == address(0)) revert ZeroRecipient();
        if (d.outCm == bytes32(0)) revert ZeroCm();

        a = _getAsset(d.publicAssetId);
        if (address(a.token) == address(0)) revert UnknownAsset(d.publicAssetId);
        if (a.disabled) revert AssetDisabled(d.publicAssetId);
        AuxValidation.validate(aux);
    }

    /// Shared escrow record and event emit for `deposit*`. The caller must have
    /// already pulled `inAmt + fee` of `a.token` into the pool. The fee accrues
    /// at flush.
    function _finalizeDeposit(
        PubInputs.DepositRequest calldata d,
        AuxValidation.Output calldata aux,
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
            uint32(block.number)
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
            aux.ciphertext
        );
        emit AssetMoved(d.publicAssetId, a.token, inAmt, 0);
    }

    /// Insert up to `PubInputs.MAX_L_BATCH` escrowed deposits under one batched
    /// SNARK. `tpi` and `meta` mirror the per-deposit payloads in `ids` order;
    /// the circuit enforces `isDeposit[i] == 1` for active slots and zeros for
    /// padding. A deposit occupies exactly one leaf, so slot `i` is leaf `i` and
    /// the batch advances the tree by `n` leaves, odd `n` included.
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
            _advanceRoot(tpi.newRoot, uint64(n), tpi.oldRoot);
        }
    }

    /// Batch-level header checks: size, count alignment, tree position.
    function _validateBatchHeader(uint256 n, PubInputs.TreeUpdateBatch calldata tpi) private view {
        if (n == 0 || n > PubInputs.MAX_L_BATCH) revert BadBatchSize();
        if (uint256(tpi.actualCount) != n) revert BatchMisaligned();
        if (tpi.oldRoot != currentRoot()) revert StaleOldRoot();
        uint64 cc = committedCount;
        if (tpi.startIndex != cc) revert BatchMisaligned();
        if (uint256(cc) + n > MAX_LEAVES) revert TreeFull();
    }

    /// Validate one deposit against its `tpi` slot and `meta`, accumulate its
    /// fee under its token, then emit and delete the escrow. Returns the updated
    /// unique-token count. Digest equality binds every calldata field, asset
    /// included.
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
        // Zero is the sentinel for "no pending deposit". The slot otherwise
        // holds a keccak digest, so this is a presence test, not arithmetic on
        // an attacker-movable quantity. The `delete` below restores the
        // sentinel, which rejects a repeated id within one batch.
        // slither-disable-next-line incorrect-equality
        if (stored == bytes32(0)) revert DepositNotPending(id);
        if (tpi.isDeposit[i] != 1) revert BadDepositMode();
        if (tpi.leafPublicIn[i] > type(uint48).max) revert PublicInTooLarge();

        // Reconstruct the submit-time digest; one equality binds all fields.
        uint64 assetId = tpi.leafAsset[i];
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 expected = _depositDigest(
            id, tpi.cms[i], tpi.cvDeps[i], assetId, uint48(tpi.leafPublicIn[i]), m.fbps, m.payer, m.submittedAt
        );
        if (expected != stored) revert DigestMismatch(id);

        AssetEntry memory a = _getAsset(assetId);
        (, uint256 fee) = _computeAmounts(uint256(tpi.leafPublicIn[i]), a.scale, uint256(m.fbps));

        (uint256 slot, uint256 newCount) = _findOrAppendToken(tokens, nUnique, a.token);
        fees[slot] += fee;

        emit DepositFlushed(id, tpi.cms[i]);
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
        uint32 submittedAt
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this), block.chainid, id, cm, cvDep, publicAssetId, publicIn, feeBpsAtSubmit, payer, submittedAt
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

    /// Refund after `cancelDelay`. The funds go to the digest-bound payer. The
    /// caller resupplies the digest preimage from the deposit's
    /// `DepositEscrowed` event (`submittedAt` = its block number), and keccak
    /// equality binds every value to submit time.
    ///
    /// Permissionless for EOA payers: `deposit` is Permit2-signature based, so
    /// a payer may be an address that never sends a transaction and depends on
    /// a relayer to cancel for it. A *contract* payer is different — it can
    /// always transact for itself, and it is the party that must observe the
    /// refund arriving, since the coin is returned to it rather than to whoever
    /// funded it. `NativeAdapter` is exactly that: settled by a third party, its
    /// refund lands on the adapter with nothing left on-chain to distinguish it
    /// from a flushed deposit, stranding the funder's claim. Requiring contract
    /// payers to drive their own cancel removes that state entirely.
    function cancelDeposit(
        uint256 id,
        uint48 publicIn,
        bytes32 cm,
        uint256[2] calldata cvDep,
        uint64 publicAssetId,
        uint16 fbps,
        address payer,
        uint32 submittedAt
    ) external nonReentrant {
        bytes32 stored = escrowed[id];
        if (stored == bytes32(0)) revert DepositNotPending(id);

        bytes32 expected = _depositDigest(id, cm, cvDep, publicAssetId, publicIn, fbps, payer, submittedAt);
        if (expected != stored) revert DigestMismatch(id);

        // `payer` is digest-verified above, so this reads the real payer, not a
        // caller-chosen one. Note an EIP-7702 delegated EOA carries code and is
        // therefore treated as a contract payer; it can transact for itself, so
        // it loses relayed cancellation but never access.
        if (payer.code.length != 0 && msg.sender != payer) revert PayerNotSender();

        // `submittedAt` is digest-verified, so it is sound for the delay check.
        uint256 unlockBlock = uint256(submittedAt) + uint256(cancelDelay);
        if (block.number < unlockBlock) revert CancelTooEarly(id, unlockBlock);

        AssetEntry memory a = _getAsset(publicAssetId);
        (uint256 inAmt, uint256 fee) = _computeAmounts(uint256(publicIn), a.scale, uint256(fbps));
        uint256 total = inAmt + fee;

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
        AuxValidation.Output[3] calldata aux
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
        AuxValidation.Output[3] calldata aux
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
    /// `tpi.cvDeps`, and pins `tpi.isDeposit` to 0. `actualCount` counts leaves,
    /// so it is pinned to `TRANSACT_OUT_LEAVES`.
    function _validateRequest(
        PubInputs.Transact calldata pi,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[3] calldata aux
    ) private view {
        if (pi.chainId != block.chainid) revert BadChainId();
        if (pi.recipient == address(0)) revert ZeroRecipient();
        if (pi.payer == address(0)) revert ZeroPayer();
        if (pi.relayer != msg.sender) revert BadRelayer();
        // Pairwise across all inputs: a single `[0] != [1]` check would let a
        // caller repeat a nullifier in a later slot and spend one note twice
        // within the same transaction.
        for (uint256 a = 0; a < PubInputs.TRANSACT_IN; ++a) {
            for (uint256 b = a + 1; b < PubInputs.TRANSACT_IN; ++b) {
                if (pi.nullifier[a] == pi.nullifier[b]) revert DuplicateNullifier();
            }
        }
        if (pi.publicOut > type(uint48).max) revert PublicOutTooLarge();
        // Cross-bind the separate Groth16 proofs: the spend's `pi` against the
        // tree-update's `tpi`.
        if (tpi.actualCount != TRANSACT_OUT_LEAVES) revert BatchMisaligned();
        // Both arrays are indexed by output, so both are checked over the full
        // shape. `cv_dep` is part of the leaf preimage
        // (`leaf = Poseidon(TAG_LEAF, cm, cv_dep_x, cv_dep_y)`) and
        // `spent.circom` recomputes it from the note's own (asset, value, rcv).
        // An unbound output index would let a relayer insert a leaf under a
        // `cv_dep` the recipient cannot reproduce: the inputs are consumed, the
        // note's Merkle path does not exist, and the output is permanently
        // unspendable.
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; ++k) {
            if (pi.outCm[k] != tpi.cms[k]) revert CmMismatch();
            if (pi.outCvDep[k][0] != tpi.cvDeps[k][0] || pi.outCvDep[k][1] != tpi.cvDeps[k][1]) {
                revert CvDepMismatch();
            }
        }
        // The batch circuit cannot distinguish a spend leaf from a deposit leaf,
        // so it does not force `is_deposit = 0`. Deposit binding is per-leaf
        // (`cv_dep == leaf_public_in·V^leaf_asset + rcv·H`), so a spend output
        // could satisfy it by declaring its own (asset, value), publishing the
        // note's opening in the compressed public inputs. Pinned on-chain here.
        for (uint256 k = 0; k < TRANSACT_OUT_LEAVES; ++k) {
            if (tpi.isDeposit[k] != 0) revert BadDepositMode();
        }
        AuxValidation.validate(aux);

        if (!isKnownRoot[pi.merkleRoot]) revert UnknownRoot();
        if (tpi.oldRoot != currentRoot()) revert StaleOldRoot();
        uint64 cc = committedCount;
        if (tpi.startIndex != cc) revert BatchMisaligned();
        if (uint256(cc) + TRANSACT_OUT_LEAVES > MAX_LEAVES) revert TreeFull();
    }

    /// Reverts unless `bv` answers `verifyBatch`.
    ///
    /// The slot is immutable and a wrong address fails closed, so every spend
    /// would revert with nothing identifying the cause. An address without a
    /// matching `verifyBatch` reverts into the `catch`.
    ///
    /// The return value is ignored: this establishes the interface, not the
    /// verdict on the probe instance.
    function _probeSpendVerifier(IBatchVerifier bv) private view {
        uint256[2] memory g1;
        uint256[2][2] memory g2;
        try bv.verifyBatch(g1, g2, g1, g1, g1, g2, g1, g1) returns (bool) { }
        catch {
            revert BadSpendVerifier();
        }
    }

    /// Verify both Groth16 proofs (`transact_3x3` and `tree_update_batch`) in a
    /// single pairing check. Public inputs are Fiat-Shamir-compressed to
    /// `(y, z)` before pairing.
    ///
    /// `verifyBatch` returns one bool for both proofs, so a rejection is not
    /// attributable to either on-chain and always surfaces as `ProofRejected`.
    /// `TreeUpdateRejected` is the flush-path error.
    ///
    /// The call must stay high-level with these exact static parameters:
    /// `BatchedGroth16Verifier` pins `calldatasize` to `4 + 20 * 32` and hashes
    /// that calldata verbatim as its transcript. Slot order is load-bearing —
    /// transact first, tree-update second.
    ///
    function _verifyProofs(
        Proof calldata p,
        PubInputs.Transact calldata pi,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[3] calldata aux
    ) private view {
        if (!SPEND_VERIFIER.verifyBatch(p.a, p.b, p.c, PubInputs.compress(pi, aux), tp.a, tp.b, tp.c, tpi.compress())) {
            revert ProofRejected();
        }
    }

    /// Spend-path note emit, common to every entry point. `AssetMoved` is
    /// emitted by the unshield paths themselves: every spend entry point forces
    /// `publicIn == 0`, so the shield side is always zero and `transfer` moves
    /// no tokens.
    function _emitNotes(PubInputs.Transact calldata pi, AuxValidation.Output[3] calldata aux) private {
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

    /// Send `outAmt - fee` to `recipient`; accrue `fee`.
    function _unshieldLeg(IERC20 token, address recipient, uint256 outAmt) private {
        uint256 fee = (outAmt * feeBps) / BPS_DENOMINATOR;
        uint256 net = outAmt - fee;
        _accrueFee(token, fee);
        token.safeTransfer(recipient, net);
    }
}
