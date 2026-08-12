// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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
import { IWrappedNative } from "./interfaces/IWrappedNative.sol";
import { PubInputs } from "./libs/PubInputs.sol";
import { AuxValidation } from "./libs/AuxValidation.sol";

/// Multi-Asset Shielded Pool. Entry points:
/// * `submitIntent` — escrow funds via Permit2; no SNARK at submit.
/// * `flushBatch` — insert up to MAX_N escrowed intents under one
///   `tree_update_batch` SNARK.
/// * `cancelIntent` — refund the digest-bound payer after `cancelDelay`.
/// * `transfer` / `withdraw` / `withdrawNative` — spend ops; verify
///   `(transact_3x3, tree_update_batch)`.
///
/// Token movement binds to `payer` (sig- or SNARK-bound), not `msg.sender`,
/// so any relayer may submit for a user. Native unshield wraps via
/// WRAPPED_NATIVE.
contract MASP is CommitmentTree, AssetRegistry, NullifierSet, FeeConfig {
    using SafeERC20 for IERC20;
    using PubInputs for PubInputs.Transact;
    using PubInputs for PubInputs.TreeUpdateBatch;

    IVerifier public immutable VERIFIER;
    /// Verifier for `tree_update_batch.circom` (MAX_L = `PubInputs.MAX_L_BATCH`);
    /// used by flush (that many single-leaf deposits) and by spends
    /// (`TRANSACT_OUT_LEAVES` output leaves).
    IVerifier public immutable TREE_UPDATE_BATCH_VERIFIER;

    /// Width of the per-token fee accumulators in `flushBatch`. Must equal
    /// `PubInputs.MAX_L_BATCH`; Solidity will not accept a library constant as a
    /// memory-array length, so the value is duplicated here and the constructor
    /// asserts the two agree. A silent drift between them is exactly the bug this
    /// guards: the accumulators would be too small for the batch they serve.
    uint256 private constant FEE_ACC_SLOTS = 8;

    /// Output leaves per spend, i.e. `N_OUT` of the deployed transact shape
    /// (`3x3.circom`). `tpi.actualCount` counts leaves, so the spend path pins
    /// it to this. Must track `PubInputs.TRANSACT_OUT`.
    uint64 private constant TRANSACT_OUT_LEAVES = uint64(PubInputs.TRANSACT_OUT);
    /// Uniswap Permit2. Constructor reverts if no code at the address.
    ISignatureTransfer public immutable PERMIT2;
    /// Wrapped native coin. `address(0)` disables `withdrawNative` /
    /// `submitIntentNative`.
    IWrappedNative public immutable WRAPPED_NATIVE;

    enum NativeBridge {
        None, // ERC-20 safeTransfer
        WithdrawUnwrap // IWrappedNative.withdraw + raw native call
    }

    struct Proof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
    }

    /// Permit2 sig + payer's signed ceiling. `maxTotal` caps `inAmt + fee`,
    /// bounding fee bumps between submit and pull.
    struct Permit2Sig {
        uint256 nonce;
        uint256 deadline;
        uint256 maxTotal;
        bytes signature;
    }

    /// Permit2 witness binding. `piHash = keccak256(abi.encode(d, aux))`.
    /// TYPE_STRING inner `MASPDeposit(bytes32 piHash)` must match TYPEHASH.
    bytes32 public constant DEPOSIT_WITNESS_TYPEHASH = keccak256("MASPDeposit(bytes32 piHash)");
    string public constant DEPOSIT_WITNESS_TYPE_STRING =
        "MASPDeposit witness)MASPDeposit(bytes32 piHash)TokenPermissions(address token,uint256 amount)";

    // ============== Escrow state =============================================

    /// Per-intent escrow digest (see `_intentDigest`). Pending iff nonzero.
    /// All submit-time fields fold into the digest; flush/cancel resupply
    /// the preimage from `IntentEscrowed` and keccak equality binds it.
    mapping(uint256 id => bytes32 digest) public escrowed;
    uint256 public nextIntentId;

    /// Digest fields not carried in `tpi`; verified against `escrowed[id]`
    /// in `_drainIntent`. Sourced from the intent's `IntentEscrowed` event
    /// (`submittedAt` = its block number).
    struct IntentMeta {
        address payer;
        uint32 submittedAt;
        uint16 fbps;
    }

    /// Blocks before `cancelIntent` is allowed. Owner-tunable within
    /// `[CANCEL_DELAY_MIN, CANCEL_DELAY_MAX]`.
    uint32 public cancelDelay;
    uint32 internal constant CANCEL_DELAY_MIN = 3_600; // ~12h on 12s blocks
    uint32 internal constant CANCEL_DELAY_MAX = 50_400; // ~7d on 12s blocks
    uint32 internal constant CANCEL_DELAY_DEFAULT = 7_200; // ~24h on 12s blocks

    /// Emitted on shield + unshield; skipped for pure transfers (in==out==0).
    event AssetMoved(uint64 indexed assetId, IERC20 indexed token, uint256 inAmount, uint256 outAmount);

    /// Encrypted-note payload for spend flows (FMD clue, ephemeral pubkey,
    /// ciphertext, Pedersen value commitment). Emitted once per output leaf,
    /// so the shape matches `IntentEscrowed` and does not have to change again
    /// when `N_OUT` does. `cm` is indexed, so this also serves as the
    /// note-creation signal for indexers that track commitments only.
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

    /// Escrow-flow note signal. Carries the per-intent payload relayers need
    /// to assemble a `flushBatch`: the single deposit leaf's Pedersen value
    /// commitment `cvDep` and its blinder `rcv`. `NotePayload` is NOT emitted
    /// on this path.
    event IntentEscrowed(
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

    event IntentFlushed(uint256 indexed id, bytes32 cm);
    event IntentCanceled(uint256 indexed id, address indexed payer, uint256 refunded);
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
    error ZeroPermit2();
    error ProofRejected();
    error TreeUpdateRejected();
    // --- native bridge guards -----------------------------------------------
    error AssetNotWrappedNative();
    error WrappedNativeNotConfigured();
    error NativeTransferFailed();
    error NotAWithdraw();
    error UnauthorizedNativeSender();
    // --- escrow flow ---------------------------------------------------------
    error PublicInTooLarge();
    error PublicOutTooLarge();
    error ZeroCm();
    error IntentNotPending(uint256 id);
    error BadBatchSize();
    error CancelTooEarly(uint256 id, uint256 unlockBlock);
    error BadCancelDelay();
    error PayerNotSender();
    error MsgValueMismatch();
    error AmountOverflowsAllowance();
    error CvDepMismatch();
    error BadDepositMode();
    /// Caller-supplied digest preimage mismatch on flush/cancel.
    error DigestMismatch(uint256 id);

    constructor(
        IVerifier verifier_,
        IVerifier treeUpdateBatchVerifier_,
        ISignatureTransfer permit2_,
        IWrappedNative wrappedNative_,
        uint64[] memory ids,
        IERC20[] memory tokens,
        uint256[] memory scales,
        uint16 feeBps_,
        address treasury_,
        address owner_
    ) Ownable(owner_) {
        if (address(verifier_).code.length == 0) revert ZeroVerifier();
        if (address(treeUpdateBatchVerifier_).code.length == 0) revert ZeroVerifier();
        if (address(permit2_).code.length == 0) revert ZeroPermit2();
        // Deploy-time guard for the duplicated batch width — see FEE_ACC_SLOTS.
        if (FEE_ACC_SLOTS != PubInputs.MAX_L_BATCH) revert BadBatchSize();
        VERIFIER = verifier_;
        TREE_UPDATE_BATCH_VERIFIER = treeUpdateBatchVerifier_;
        PERMIT2 = permit2_;
        WRAPPED_NATIVE = wrappedNative_; // address(0) disables withdrawNative
        _initFee(feeBps_, treasury_);
        _writeAssets(ids, tokens, scales);
        cancelDelay = CANCEL_DELAY_DEFAULT;
    }

    function setCancelDelay(uint32 newDelay) external onlyOwner {
        if (newDelay < CANCEL_DELAY_MIN || newDelay > CANCEL_DELAY_MAX) revert BadCancelDelay();
        emit CancelDelayUpdated(cancelDelay, newDelay);
        cancelDelay = newDelay;
    }

    /// Only the wrapped-native contract may push raw native coin (via
    /// `IWrappedNative.withdraw`).
    receive() external payable {
        if (msg.sender != address(WRAPPED_NATIVE)) revert UnauthorizedNativeSender();
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
        _unshieldLeg(a.token, pi.recipient, outAmt, NativeBridge.None);
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
        // alone, avoiding the cold SLOAD of the `scale` slot that `_getAsset`
        // performs.
        _requireAssetKnown(pi.publicAssetId);
        _finalize(p, pi, tp, tpi, aux);
        _emitNotes(pi, aux);
    }

    /// Unshield to native coin: unwrap `outAmt - fee` and forward raw native;
    /// fee accrues in the wrapped-native token.
    function withdrawNative(
        Proof calldata p,
        PubInputs.Transact calldata pi,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[3] calldata aux
    ) external nonReentrant {
        if (pi.publicIn != 0) revert NotAWithdraw();
        if (pi.publicOut == 0) revert MustHaveWithdraw();
        if (address(WRAPPED_NATIVE) == address(0)) revert WrappedNativeNotConfigured();
        AssetEntry memory a = _preflight(pi, tpi, aux);
        if (address(a.token) != address(WRAPPED_NATIVE)) revert AssetNotWrappedNative();
        _finalize(p, pi, tp, tpi, aux);
        uint256 outAmt = uint256(pi.publicOut) * a.scale;
        _unshieldLeg(a.token, pi.recipient, outAmt, NativeBridge.WithdrawUnwrap);
        emit AssetMoved(pi.publicAssetId, a.token, 0, outAmt);
        _emitNotes(pi, aux);
    }

    // ============== Escrow flow ==============================================

    /// Pull funds into escrow via Permit2; no SNARK at submit. Relayer reads
    /// `IntentEscrowed` to assemble a `flushBatch`. A bad-preimage cm only
    /// costs the depositor (leaf has no spendable witness).
    function submitIntent(
        PubInputs.DepositIntent calldata d,
        Permit2Sig calldata sig,
        AuxValidation.Output calldata aux
    ) external nonReentrant returns (uint256 id) {
        AssetEntry memory a = _validateIntent(d, aux);
        uint16 fbps = feeBps;
        (uint256 inAmt, uint256 fee) = _computeAmounts(d.publicIn, a.scale, fbps);
        _permit2Pull(a.token, d.payer, sig, inAmt + fee, keccak256(abi.encode(d, aux)));
        id = _finalizeIntent(d, aux, a, inAmt, fbps);
    }

    /// Permit2 AllowanceTransfer deposit. User pre-signs a `PermitSingle`
    /// covering N future deposits; each pulls via `transferFrom` with no
    /// per-tx sig. `msg.sender == d.payer` required; Permit2 enforces the
    /// signed cap and expiration.
    function submitIntentAuthorized(PubInputs.DepositIntent calldata d, AuxValidation.Output calldata aux)
        external
        nonReentrant
        returns (uint256 id)
    {
        AssetEntry memory a = _validateIntent(d, aux);
        if (msg.sender != d.payer) revert PayerNotSender();

        uint16 fbps = feeBps;
        (uint256 inAmt, uint256 fee) = _computeAmounts(d.publicIn, a.scale, fbps);
        uint256 total = inAmt + fee;
        if (total > type(uint160).max) revert AmountOverflowsAllowance();

        // forge-lint: disable-next-line(unsafe-typecast)
        IAllowanceTransfer(address(PERMIT2)).transferFrom(d.payer, address(this), uint160(total), address(a.token));
        id = _finalizeIntent(d, aux, a, inAmt, fbps);
    }

    /// Native-coin deposit. Pool wraps `msg.value`. Asset must be the
    /// wrapped-native token; `msg.sender == d.payer` authorizes (funds arrive
    /// with the call, no Permit2).
    function submitIntentNative(PubInputs.DepositIntent calldata d, AuxValidation.Output calldata aux)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (address(WRAPPED_NATIVE) == address(0)) revert WrappedNativeNotConfigured();
        AssetEntry memory a = _validateIntent(d, aux);
        if (address(a.token) != address(WRAPPED_NATIVE)) revert AssetNotWrappedNative();
        if (msg.sender != d.payer) revert PayerNotSender();

        uint16 fbps = feeBps;
        (uint256 inAmt, uint256 fee) = _computeAmounts(d.publicIn, a.scale, fbps);
        if (msg.value != inAmt + fee) revert MsgValueMismatch();

        WRAPPED_NATIVE.deposit{ value: msg.value }();
        id = _finalizeIntent(d, aux, a, inAmt, fbps);
    }

    /// Shared validation for `submitIntent*`. Returns resolved asset entry.
    function _validateIntent(PubInputs.DepositIntent calldata d, AuxValidation.Output calldata aux)
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

    /// Shared escrow record + event emit for `submitIntent*`. Caller must
    /// have already pulled `inAmt + fee` of `a.token` into the pool. Fee
    /// accrues at flush.
    function _finalizeIntent(
        PubInputs.DepositIntent calldata d,
        AuxValidation.Output calldata aux,
        AssetEntry memory a,
        uint256 inAmt,
        uint16 fbps
    ) private returns (uint256 id) {
        unchecked {
            id = nextIntentId++;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        escrowed[id] = _intentDigest(
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

        emit IntentEscrowed(
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

    /// Insert up to MAX_L_BATCH escrowed intents under one batched SNARK.
    /// `tpi` and `meta` mirror per-intent payloads in `ids` order; circuit
    /// enforces `isDeposit[i]==1` for active slots and zeros padding.
    /// A deposit occupies exactly one leaf, so slot `i` is leaf `i` and the
    /// batch advances the tree by `n` leaves — odd `n` included.
    function flushBatch(
        uint256[] calldata ids,
        IntentMeta[] calldata meta,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi
    ) external nonReentrant {
        uint256 n = ids.length;
        if (meta.length != n) revert BadBatchSize();
        _validateBatchHeader(n, tpi);

        // Per-token fee accumulator, sized off PubInputs.MAX_L_BATCH directly so a
        // change to the batch width cannot leave these arrays behind.
        // slither-disable-next-line uninitialized-local
        IERC20[FEE_ACC_SLOTS] memory tokens;
        // slither-disable-next-line uninitialized-local
        uint256[FEE_ACC_SLOTS] memory fees;
        uint256 nUnique = 0;

        // Phase 1: drain each active slot, accumulate fee per token.
        for (uint256 i = 0; i < n; ++i) {
            nUnique = _drainIntent(ids[i], i, tpi, meta[i], tokens, fees, nUnique);
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

    /// Validate one intent against its tpi slot + meta, accumulate fee under
    /// its token, emit + delete. Returns updated unique-token count. Digest
    /// equality binds every calldata field, asset included.
    function _drainIntent(
        uint256 id,
        uint256 i,
        PubInputs.TreeUpdateBatch calldata tpi,
        IntentMeta calldata m,
        IERC20[FEE_ACC_SLOTS] memory tokens,
        uint256[FEE_ACC_SLOTS] memory fees,
        uint256 nUnique
    ) private returns (uint256) {
        bytes32 stored = escrowed[id];
        // Exact zero is the sentinel for "no pending intent". The slot holds a
        // keccak digest, so zero is unreachable for a live escrow: this is a
        // presence test, not arithmetic on an attacker-movable quantity.
        // `flushBatch` relies on `delete` restoring it, which is what rejects a
        // repeated id within one batch.
        // slither-disable-next-line incorrect-equality
        if (stored == bytes32(0)) revert IntentNotPending(id);
        if (tpi.isDeposit[i] != 1) revert BadDepositMode();
        if (tpi.leafPublicIn[i] > type(uint48).max) revert PublicInTooLarge();

        // Reconstruct submit-time digest; one equality binds all fields.
        uint64 assetId = tpi.leafAsset[i];
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 expected = _intentDigest(
            id, tpi.cms[i], tpi.cvDeps[i], assetId, uint48(tpi.leafPublicIn[i]), m.fbps, m.payer, m.submittedAt
        );
        if (expected != stored) revert DigestMismatch(id);

        AssetEntry memory a = _getAsset(assetId);
        (, uint256 fee) = _computeAmounts(uint256(tpi.leafPublicIn[i]), a.scale, uint256(m.fbps));

        (uint256 slot, uint256 newCount) = _findOrAppendToken(tokens, nUnique, a.token);
        fees[slot] += fee;

        emit IntentFlushed(id, tpi.cms[i]);
        delete escrowed[id];
        return newCount;
    }

    /// Preimage for `escrowed[id]`, shared by submit/flush/cancel.
    /// `(address(this), block.chainid, id)` is the anti-replay prefix.
    function _intentDigest(
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

    /// Refund after `cancelDelay`. Anyone may call; funds go to the
    /// digest-bound payer. Caller resupplies the digest preimage from the
    /// intent's `IntentEscrowed` event (`submittedAt` = its block number);
    /// keccak equality binds every value to submit time.
    function cancelIntent(
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
        if (stored == bytes32(0)) revert IntentNotPending(id);

        bytes32 expected = _intentDigest(id, cm, cvDep, publicAssetId, publicIn, fbps, payer, submittedAt);
        if (expected != stored) revert DigestMismatch(id);

        // `submittedAt` is digest-verified; safe for the delay check.
        uint256 unlockBlock = uint256(submittedAt) + uint256(cancelDelay);
        if (block.number < unlockBlock) revert CancelTooEarly(id, unlockBlock);

        AssetEntry memory a = _getAsset(publicAssetId);
        (uint256 inAmt, uint256 fee) = _computeAmounts(uint256(publicIn), a.scale, uint256(fbps));
        uint256 total = inAmt + fee;

        // CEI: clear escrow before external transfer.
        delete escrowed[id];

        a.token.safeTransfer(payer, total);
        emit IntentCanceled(id, payer, total);
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

    /// Wrap Permit2 `permitWitnessTransferFrom` with the deposit witness.
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

    /// Spend-side preflight: validate request shape + resolve asset.
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

    /// Spend-side request validation. This function — not the circuit — is what
    /// cross-binds the two independent Groth16 proofs: it equates the spend's
    /// `pi.outCm` / `pi.outCvDep` with the tree-update's `tpi.cms` / `tpi.cvDeps`,
    /// and pins `tpi.isDeposit` to 0. `actualCount` counts LEAVES, so a 2-output
    /// transact shape pins it to 2 (N_OUT of `2x2.circom`).
    function _validateRequest(
        PubInputs.Transact calldata pi,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[3] calldata aux
    ) private view {
        if (pi.chainId != block.chainid) revert BadChainId();
        if (pi.recipient == address(0)) revert ZeroRecipient();
        if (pi.payer == address(0)) revert ZeroPayer();
        if (pi.relayer != msg.sender) revert BadRelayer();
        // Pairwise across all inputs: at N_IN = 3 a single [0]!=[1] check
        // would let a caller repeat a nullifier in the third slot and spend
        // one note twice within the same transaction.
        for (uint256 a = 0; a < PubInputs.TRANSACT_IN; ++a) {
            for (uint256 b = a + 1; b < PubInputs.TRANSACT_IN; ++b) {
                if (pi.nullifier[a] == pi.nullifier[b]) revert DuplicateNullifier();
            }
        }
        if (pi.publicOut > type(uint48).max) revert PublicOutTooLarge();
        // Cross-bind separate Groth16 proofs: spend's pi vs tree-update's tpi.
        if (tpi.actualCount != TRANSACT_OUT_LEAVES) revert BatchMisaligned();
        for (uint256 k = 0; k < PubInputs.TRANSACT_OUT; ++k) {
            if (pi.outCm[k] != tpi.cms[k]) revert CmMismatch();
        }
        if (
            pi.outCvDep[0][0] != tpi.cvDeps[0][0] || pi.outCvDep[0][1] != tpi.cvDeps[0][1]
                || pi.outCvDep[1][0] != tpi.cvDeps[1][0] || pi.outCvDep[1][1] != tpi.cvDeps[1][1]
        ) revert CvDepMismatch();
        // The batch circuit does NOT force is_deposit=0 here — it cannot tell a
        // spend leaf from a deposit leaf. Since deposit binding is per-leaf
        // (`cv_dep == leaf_public_in·V^leaf_asset + rcv·H`), a spend output can
        // satisfy it by declaring its own (asset, value), which would publish the
        // note's opening in the compressed public inputs. Pin it on-chain.
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

    /// Verify both Groth16s (transact_2x2 + tree_update_batch). PIs are
    /// Fiat-Shamir-compressed to `(y, z)` before pairing.
    function _verifyProofs(
        Proof calldata p,
        PubInputs.Transact calldata pi,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[3] calldata aux
    ) private view {
        if (!VERIFIER.verifyProof(p.a, p.b, p.c, PubInputs.compress(pi, aux))) {
            revert ProofRejected();
        }
        if (!TREE_UPDATE_BATCH_VERIFIER.verifyProof(tp.a, tp.b, tp.c, tpi.compress())) {
            revert TreeUpdateRejected();
        }
    }

    /// Spend-path note emit, common to every entry point. `AssetMoved` is
    /// emitted by the unshield paths themselves: every spend entry point forces
    /// `publicIn == 0`, so its shield side is always zero and `transfer` moves
    /// no tokens at all.
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

    /// Send `outAmt - fee` to `recipient`; accrue `fee`. Native path unwraps
    /// then sends raw native.
    function _unshieldLeg(IERC20 token, address recipient, uint256 outAmt, NativeBridge bridge) private {
        uint256 fee = (outAmt * feeBps) / BPS_DENOMINATOR;
        uint256 net = outAmt - fee;
        _accrueFee(token, fee);
        if (bridge == NativeBridge.WithdrawUnwrap) {
            WRAPPED_NATIVE.withdraw(net);
            _sendNative(recipient, net);
        } else {
            token.safeTransfer(recipient, net);
        }
    }

    function _sendNative(address to, uint256 amount) private {
        // slither-disable-next-line arbitrary-send-eth,low-level-calls
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
    }

    /// Off-chain dry-run helper for `transact_2x2`.
    function verifyProof(Proof calldata p, PubInputs.Transact calldata pi, AuxValidation.Output[3] calldata aux)
        external
        view
        returns (bool)
    {
        return VERIFIER.verifyProof(p.a, p.b, p.c, PubInputs.compress(pi, aux));
    }

    /// Pure tree-update-batch verification helper.
    function verifyTreeUpdateBatch(Proof calldata tp, PubInputs.TreeUpdateBatch calldata tpi)
        external
        view
        returns (bool)
    {
        return TREE_UPDATE_BATCH_VERIFIER.verifyProof(tp.a, tp.b, tp.c, tpi.compress());
    }
}
