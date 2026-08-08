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
///   `(transact_2x2, tree_update_batch[N=1])`.
///
/// Token movement binds to `payer` (sig- or SNARK-bound), not `msg.sender`,
/// so any relayer may submit for a user. Native unshield wraps via
/// WRAPPED_NATIVE.
contract MASP is CommitmentTree, AssetRegistry, NullifierSet, FeeConfig {
    using SafeERC20 for IERC20;
    using PubInputs for PubInputs.Transact;
    using PubInputs for PubInputs.TreeUpdateBatch;

    IVerifier public immutable VERIFIER;
    /// Verifier for `tree_update_batch.circom` (MAX_N=8); used by flush (N≤8)
    /// and spends (N=1).
    IVerifier public immutable TREE_UPDATE_BATCH_VERIFIER;
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
    /// ciphertext, Pedersen value commitments). `cm0`/`cm1` are indexed, so
    /// this also serves as the note-creation signal for indexers that track
    /// commitments only and ignore the data.
    event NotePayload(
        bytes32 indexed cm0,
        bytes32 indexed cm1,
        uint256 clueRx0,
        uint256 clueRy0,
        uint256 ephPubX0,
        uint256 ephPubY0,
        bytes ciphertext0,
        uint256 clueRx1,
        uint256 clueRy1,
        uint256 ephPubX1,
        uint256 ephPubY1,
        bytes ciphertext1,
        uint256 cvDep0X,
        uint256 cvDep0Y,
        uint256 cvDep1X,
        uint256 cvDep1Y
    );

    /// Escrow-flow note signal. Carries the per-intent payload relayers need
    /// to assemble a `flushBatch`, including Pedersen value commitments
    /// (cvDep0, cvDep1) and `rcvTotal = rcv_dep_0 + rcv_dep_1`. `NotePayload`
    /// is NOT emitted on this path.
    event IntentEscrowed(
        uint256 indexed id,
        address indexed payer,
        address indexed recipient,
        uint64 publicAssetId,
        uint64 publicIn,
        uint16 feeBpsAtSubmit,
        bytes32 cm0,
        bytes32 cm1,
        uint256 cvDep0X,
        uint256 cvDep0Y,
        uint256 cvDep1X,
        uint256 cvDep1Y,
        uint256 rcvTotal,
        uint256 clueRx0,
        uint256 clueRy0,
        uint256 ephPubX0,
        uint256 ephPubY0,
        bytes ciphertext0,
        uint256 clueRx1,
        uint256 clueRy1,
        uint256 ephPubX1,
        uint256 ephPubY1,
        bytes ciphertext1
    );

    event IntentFlushed(uint256 indexed id, bytes32 cm0, bytes32 cm1);
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
        AuxValidation.Output[2] calldata aux
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
        AuxValidation.Output[2] calldata aux
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
        AuxValidation.Output[2] calldata aux
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
        AuxValidation.Output[2] calldata aux
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
    function submitIntentAuthorized(PubInputs.DepositIntent calldata d, AuxValidation.Output[2] calldata aux)
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
    function submitIntentNative(PubInputs.DepositIntent calldata d, AuxValidation.Output[2] calldata aux)
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
    function _validateIntent(PubInputs.DepositIntent calldata d, AuxValidation.Output[2] calldata aux)
        private
        view
        returns (AssetEntry memory a)
    {
        if (d.chainId != block.chainid) revert BadChainId();
        if (d.publicIn == 0) revert MustHaveDeposit();
        if (d.publicIn > type(uint48).max) revert PublicInTooLarge();
        if (d.payer == address(0)) revert ZeroPayer();
        if (d.recipient == address(0)) revert ZeroRecipient();
        if (d.outCm[0] == bytes32(0) || d.outCm[1] == bytes32(0)) revert ZeroCm();

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
        AuxValidation.Output[2] calldata aux,
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
            d.outCm[0],
            d.outCm[1],
            d.cvDep0,
            d.cvDep1,
            d.publicAssetId,
            uint48(d.publicIn),
            fbps,
            d.payer,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32(block.number)
        );

        AuxValidation.Output calldata a0 = aux[0];
        AuxValidation.Output calldata a1 = aux[1];
        emit IntentEscrowed(
            id,
            d.payer,
            d.recipient,
            d.publicAssetId,
            d.publicIn,
            fbps,
            d.outCm[0],
            d.outCm[1],
            d.cvDep0[0],
            d.cvDep0[1],
            d.cvDep1[0],
            d.cvDep1[1],
            d.rcvTotal,
            a0.clueRx,
            a0.clueRy,
            a0.ephPubX,
            a0.ephPubY,
            a0.ciphertext,
            a1.clueRx,
            a1.clueRy,
            a1.ephPubX,
            a1.ephPubY,
            a1.ciphertext
        );
        emit AssetMoved(d.publicAssetId, a.token, inAmt, 0);
    }

    /// Insert up to MAX_N_BATCH escrowed intents under one batched SNARK.
    /// `tpi` and `meta` mirror per-intent payloads in `ids` order; circuit
    /// enforces `isDeposit[i]==1` for active slots and zeros padding.
    function flushBatch(
        uint256[] calldata ids,
        IntentMeta[] calldata meta,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi
    ) external nonReentrant {
        uint256 n = ids.length;
        if (meta.length != n) revert BadBatchSize();
        _validateBatchHeader(n, tpi);

        // Per-token fee accumulator. Size mirrors PubInputs.MAX_N_BATCH.
        // slither-disable-next-line uninitialized-local
        IERC20[8] memory tokens;
        // slither-disable-next-line uninitialized-local
        uint256[8] memory fees;
        uint256 nUnique = 0;

        // Phase 1: drain each active slot, accumulate fee per token.
        for (uint256 i = 0; i < n; ++i) {
            nUnique = _drainIntent(ids[i], i, tpi, meta[i], tokens, fees, nUnique);
        }

        // Phase 2: accrue fees, one SSTORE per unique token.
        for (uint256 j = 0; j < nUnique; ++j) {
            _accrueFee(tokens[j], fees[j]);
        }

        // Phase 3: verify batched SNARK and advance tree by 2*n leaves.
        if (!TREE_UPDATE_BATCH_VERIFIER.verifyProof(tp.a, tp.b, tp.c, tpi.compress())) {
            revert TreeUpdateRejected();
        }
        unchecked {
            _advanceRoot(tpi.newRoot, uint64(2 * n), tpi.oldRoot);
        }
    }

    /// Batch-level header checks: size, count alignment, tree position.
    function _validateBatchHeader(uint256 n, PubInputs.TreeUpdateBatch calldata tpi) private view {
        if (n == 0 || n > PubInputs.MAX_N_BATCH) revert BadBatchSize();
        if (uint256(tpi.actualCount) != n) revert BatchMisaligned();
        if (tpi.oldRoot != currentRoot()) revert StaleOldRoot();
        uint64 cc = committedCount;
        if (tpi.startIndex != cc) revert BatchMisaligned();
        if (uint256(cc) + 2 * n > MAX_LEAVES) revert TreeFull();
    }

    /// Validate one intent against its tpi slot + meta, accumulate fee under
    /// its token, emit + delete. Returns updated unique-token count. Digest
    /// equality binds every calldata field, asset included.
    function _drainIntent(
        uint256 id,
        uint256 i,
        PubInputs.TreeUpdateBatch calldata tpi,
        IntentMeta calldata m,
        IERC20[8] memory tokens,
        uint256[8] memory fees,
        uint256 nUnique
    ) private returns (uint256) {
        bytes32 stored = escrowed[id];
        if (stored == bytes32(0)) revert IntentNotPending(id);
        if (tpi.isDeposit[i] != 1) revert BadDepositMode();
        if (tpi.pairPublicIn[i] > type(uint48).max) revert PublicInTooLarge();

        // Reconstruct submit-time digest; one equality binds all fields.
        uint64 assetId = tpi.pairAsset[i];
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 expected = _intentDigest(
            id,
            tpi.cms[2 * i],
            tpi.cms[2 * i + 1],
            tpi.cvDeps[2 * i],
            tpi.cvDeps[2 * i + 1],
            assetId,
            uint48(tpi.pairPublicIn[i]),
            m.fbps,
            m.payer,
            m.submittedAt
        );
        if (expected != stored) revert DigestMismatch(id);

        AssetEntry memory a = _getAsset(assetId);
        (, uint256 fee) = _computeAmounts(uint256(tpi.pairPublicIn[i]), a.scale, uint256(m.fbps));

        (uint256 slot, uint256 newCount) = _findOrAppendToken(tokens, nUnique, a.token);
        fees[slot] += fee;

        emit IntentFlushed(id, tpi.cms[2 * i], tpi.cms[2 * i + 1]);
        delete escrowed[id];
        return newCount;
    }

    /// Preimage for `escrowed[id]`, shared by submit/flush/cancel.
    /// `(address(this), block.chainid, id)` is the anti-replay prefix.
    function _intentDigest(
        uint256 id,
        bytes32 cm0,
        bytes32 cm1,
        uint256[2] memory cvDep0,
        uint256[2] memory cvDep1,
        uint64 publicAssetId,
        uint48 publicIn,
        uint16 feeBpsAtSubmit,
        address payer,
        uint32 submittedAt
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                id,
                cm0,
                cm1,
                cvDep0,
                cvDep1,
                publicAssetId,
                publicIn,
                feeBpsAtSubmit,
                payer,
                submittedAt
            )
        );
    }

    function _findOrAppendToken(IERC20[8] memory tokens, uint256 nUnique, IERC20 token)
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
        bytes32 cm0,
        bytes32 cm1,
        uint256[2] calldata cvDep0,
        uint256[2] calldata cvDep1,
        uint64 publicAssetId,
        uint16 fbps,
        address payer,
        uint32 submittedAt
    ) external nonReentrant {
        bytes32 stored = escrowed[id];
        if (stored == bytes32(0)) revert IntentNotPending(id);

        bytes32 expected =
            _intentDigest(id, cm0, cm1, cvDep0, cvDep1, publicAssetId, publicIn, fbps, payer, submittedAt);
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
        AuxValidation.Output[2] calldata aux
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
        AuxValidation.Output[2] calldata aux
    ) private {
        _verifyProofs(p, pi, tp, tpi, aux);
        _consumeNullifier(pi.nullifier[0]);
        _consumeNullifier(pi.nullifier[1]);
        _advanceRoot(tpi.newRoot, 2, tpi.oldRoot);
    }

    /// Spend-side request validation. Circuit binds outCm/outCvDep to
    /// tpi.cms/tpi.cvDeps, isDeposit[0]==0, and actualCount==1.
    function _validateRequest(
        PubInputs.Transact calldata pi,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[2] calldata aux
    ) private view {
        if (pi.chainId != block.chainid) revert BadChainId();
        if (pi.recipient == address(0)) revert ZeroRecipient();
        if (pi.payer == address(0)) revert ZeroPayer();
        if (pi.relayer != msg.sender) revert BadRelayer();
        if (pi.nullifier[0] == pi.nullifier[1]) revert DuplicateNullifier();
        if (pi.publicOut > type(uint48).max) revert PublicOutTooLarge();
        // Cross-bind separate Groth16 proofs: spend's pi vs tree-update's tpi.
        if (tpi.actualCount != 1) revert BatchMisaligned();
        if (pi.outCm[0] != tpi.cms[0] || pi.outCm[1] != tpi.cms[1]) revert CmMismatch();
        if (
            pi.outCvDep[0][0] != tpi.cvDeps[0][0] || pi.outCvDep[0][1] != tpi.cvDeps[0][1]
                || pi.outCvDep[1][0] != tpi.cvDeps[1][0] || pi.outCvDep[1][1] != tpi.cvDeps[1][1]
        ) revert CvDepMismatch();
        AuxValidation.validate(aux);

        if (!isKnownRoot[pi.merkleRoot]) revert UnknownRoot();
        if (tpi.oldRoot != currentRoot()) revert StaleOldRoot();
        uint64 cc = committedCount;
        if (tpi.startIndex != cc) revert BatchMisaligned();
        if (uint256(cc) + 2 > MAX_LEAVES) revert TreeFull();
    }

    /// Verify both Groth16s (transact_2x2 + tree_update_batch). PIs are
    /// Fiat-Shamir-compressed to `(y, z)` before pairing.
    function _verifyProofs(
        Proof calldata p,
        PubInputs.Transact calldata pi,
        Proof calldata tp,
        PubInputs.TreeUpdateBatch calldata tpi,
        AuxValidation.Output[2] calldata aux
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
    function _emitNotes(PubInputs.Transact calldata pi, AuxValidation.Output[2] calldata aux) private {
        AuxValidation.Output calldata a0 = aux[0];
        AuxValidation.Output calldata a1 = aux[1];
        emit NotePayload(
            pi.outCm[0],
            pi.outCm[1],
            a0.clueRx,
            a0.clueRy,
            a0.ephPubX,
            a0.ephPubY,
            a0.ciphertext,
            a1.clueRx,
            a1.clueRy,
            a1.ephPubX,
            a1.ephPubY,
            a1.ciphertext,
            pi.outCvDep[0][0],
            pi.outCvDep[0][1],
            pi.outCvDep[1][0],
            pi.outCvDep[1][1]
        );
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
    function verifyProof(Proof calldata p, PubInputs.Transact calldata pi, AuxValidation.Output[2] calldata aux)
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
