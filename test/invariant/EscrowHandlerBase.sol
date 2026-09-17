// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { deployPoolUniform, realVerifierStack, singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// Shared handler for the escrow invariant suites (`MASP.flow.invariant.t.sol`,
/// `MASPPendingFee.invariant.t.sol`).
///
/// Both drive the same deposit / flushBatch / cancelDeposit / sweep / advance
/// surface against one pending escrow at a time, and both must replay the
/// escrow preimage off-chain: the 1-slot escrow stores only its digest, so
/// flush and cancel resupply every field and the on-chain digest check binds
/// them. That replay and the id selection live here; what each suite shadows
/// (lifecycle buckets, per-token books) lives behind the hooks.
///
/// `submit` stays in each handler: its fuzzed signature differs, and it is the
/// first selector of each suite's `targetSelector` set.
abstract contract EscrowHandlerBase is Test {
    MASP public masp;
    address public permit2;
    MockERC20 public token;
    address public payer;

    uint64 public constant ASSET_ID = TestConstants.ASSET_ID;
    uint256 public constant SCALE = TestConstants.SCALE;
    uint16 public constant FEE_BPS = TestConstants.FEE_BPS;
    /// Not `TestConstants.RECIPIENT`: the recipient is part of the escrow
    /// digest, and these suites have always escrowed to this address.
    address internal constant ESCROW_RECIPIENT = address(0xb0b);

    /// All deposit ids ever submitted (pending or cleared).
    uint256[] public allIds;
    /// id → principal locked at submit (asset-units * scale).
    mapping(uint256 => uint256) public principalAt;
    /// id → treasury fee locked at submit. Not part of `accruedFee` until flush.
    mapping(uint256 => uint256) public feeAt;
    /// Off-chain preimage shadow of the principal leaf. The remaining preimage
    /// fields (payer, fbps, submittedAt, fee note) are constants or come from
    /// the hooks.
    mapping(uint256 => uint48) public preimagePublicIn;
    mapping(uint256 => bytes32) public preimageCm0;

    uint256 internal _nonce;

    constructor(MASP m, address p2, MockERC20 t, address payer_) {
        masp = m;
        permit2 = p2;
        token = t;
        payer = payer_;
    }

    // ============== Hooks ====================================================

    /// Whether `id` is still escrowed, per the handler's lifecycle shadow.
    /// Must be false for the `type(uint256).max` sentinel of an empty id list.
    function _isPending(uint256 id) internal view virtual returns (bool);

    /// The `submittedAt` block `id` was escrowed at, as the digest binds it.
    function _submittedAt(uint256 id) internal view virtual returns (uint32);

    /// The batch's new root. The SNARK is mocked, so any in-field value works;
    /// each suite keeps its own choice so root-tracking ghosts are unchanged.
    function _newRoot(uint256 id) internal view virtual returns (bytes32);

    /// Ghost updates after a landed `flushBatch` of `id` with `newRoot`.
    function _onFlushed(uint256 id, bytes32 newRoot) internal virtual;

    /// Ghost updates (and post-call checks) after a landed `cancelDeposit`.
    function _onCancelled(uint256 id) internal virtual;

    /// Extra work after sweeping `token`, such as sweeping other tokens.
    function _afterSweep() internal virtual { }

    /// The relayer fee note's (asset, value) for `id`, used for both its leaf at
    /// flush and its `FeeNote` at cancel. Defaults to the fixture's zero-value
    /// note, whose asset is 0 (see `DepositFixture.setDepositLeaves`).
    function _feeLeaf(uint256) internal view virtual returns (uint64 assetId, uint64 feeIn) {
        return (0, 0);
    }

    // ============== Submit helpers ===========================================

    /// The fixture request for `publicIn`, with an out commitment unique to the
    /// current nonce. Callers set any relayer fee fields before `_escrow`.
    function _request(uint64 publicIn) internal view returns (PubInputs.DepositRequest memory) {
        return DepositFixture.request(ASSET_ID, publicIn, payer, ESCROW_RECIPIENT, bytes32(uint256(0x1000 + _nonce)));
    }

    /// Deposits `d` under the next nonce and records the preimage and amounts
    /// both handlers shadow. The payer must already be funded and approved.
    function _escrow(PubInputs.DepositRequest memory d, uint256 maxFee, uint256 inAmt, uint256 fee)
        internal
        returns (uint256 id)
    {
        MASP.Permit2Sig memory sig = DepositFixture.sig(_nonce++, type(uint256).max, maxFee);
        id = masp.deposit(d, sig, SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
        allIds.push(id);
        principalAt[id] = inAmt;
        feeAt[id] = fee;
        // forge-lint: disable-next-line(unsafe-typecast)
        preimagePublicIn[id] = uint48(d.publicIn);
        preimageCm0[id] = d.outCm;
    }

    // ============== Fuzz targets =============================================

    /// Handler: flush one pending deposit (uses mocked SNARK verify).
    ///
    /// Rebuilds the batch from the preimage shadow. A deposit occupies
    /// `PubInputs.LEAVES_PER_DEPOSIT` (= 2) adjacent leaves, its principal then
    /// the relayer note; `_validateBatchHeader` requires the count and
    /// `_drainDeposit` rebuilds the digest from both, so a missing fee leaf
    /// reverts `BatchMisaligned` before touching state.
    function flushOne(uint256 idxSeed) external {
        uint256 id = _firstPendingFrom(idxSeed);
        if (!_isPending(id)) return;

        PubInputs.TreeUpdateBatch memory tpi =
            DepositFixture.batch(masp.currentRoot(), _newRoot(id), masp.committedCount(), 1);
        DepositFixture.setDepositLeaves(tpi, 0, preimageCm0[id], ASSET_ID, uint64(preimagePublicIn[id]));
        (tpi.leafAsset[1], tpi.leafPublicIn[1]) = _feeLeaf(id);

        MASP.DepositMeta[] memory meta = DepositFixture.metas(1, payer, _submittedAt(id), FEE_BPS);
        MASP.Proof memory proof;
        masp.flushBatch(DepositFixture.ids(id), meta, proof, tpi);

        _onFlushed(id, tpi.newRoot);
    }

    /// Handler: cancel one pending deposit, rolling past `cancelDelay` first so
    /// the on-chain guard permits the call.
    function cancelOne(uint256 idxSeed) external {
        uint256 id = _firstPendingFrom(idxSeed);
        if (!_isPending(id)) return;

        vm.roll(block.number + masp.cancelDelay());

        uint256[2] memory zCv;
        (uint64 feeAsset, uint64 feeIn) = _feeLeaf(id);
        PubInputs.FeeNote memory note = DepositFixture.feeNote();
        // forge-lint: disable-next-line(unsafe-typecast)
        note.feeIn = uint48(feeIn);
        note.feeAssetId = feeAsset;
        uint32 submittedAt = _submittedAt(id);

        // The payer is `vm.etch`ed with MockERC1271 so Permit2's ERC-1271
        // check passes at submit. That gives it code, and MASP restricts
        // cancel to the payer itself whenever `payer.code.length != 0` (a
        // contract payer must observe its own refund). The prank satisfies
        // that restriction; without it every cancel reverts `PayerNotSender`.
        // The prank sits directly before the pool call so nothing consumes it.
        vm.prank(payer);
        masp.cancelDeposit(id, preimagePublicIn[id], preimageCm0[id], zCv, ASSET_ID, FEE_BPS, payer, submittedAt, note);

        _onCancelled(id);
    }

    /// Handler: sweep accrued fees to treasury.
    function sweep() external {
        masp.sweep(IERC20(address(token)));
        _afterSweep();
    }

    /// Handler: advance the block number without touching pool state.
    function advanceBlocks(uint16 n) external {
        n = uint16(bound(n, 1, 200));
        vm.roll(block.number + n);
    }

    /// First pending id at or after `seed % len`, wrapping. If none is pending,
    /// returns the id at `seed % len` (or `type(uint256).max` when no id
    /// exists), which the caller detects through `_isPending` and skips.
    function _firstPendingFrom(uint256 seed) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return type(uint256).max;
        uint256 start = seed % n;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = allIds[(start + k) % n];
            if (_isPending(id)) return id;
        }
        return allIds[start];
    }
}

/// Shared `setUp` for the escrow invariant suites: a single-asset pool on the
/// real verifier stack, a permissive ERC-1271 payer, and tree-update proofs
/// accepted, the only `flushBatch` dependency that needs a depth-10 proof.
///
/// Each suite deploys its own handler after `_setUpPool` and registers it with
/// `_targetHandler`, keeping the fuzz surface to the five handler paths.
abstract contract EscrowInvariantTestBase is Test {
    IVerifier internal tubVerifier;
    IBatchVerifier internal batchVerifier;
    address internal permit2;
    MockERC20 internal token;
    MASP internal masp;

    address internal payer = TestConstants.ESCROW_PAYER;

    function _setUpPool() internal {
        ISignatureTransfer p2;
        (tubVerifier, batchVerifier, p2) = realVerifierStack();
        permit2 = address(p2);
        token = new MockERC20("M", "M", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), TestConstants.ASSET_ID, TestConstants.SCALE);

        masp = deployPoolUniform(
            tubVerifier,
            batchVerifier,
            p2,
            ids,
            tokens,
            scales,
            TestConstants.FEE_BPS,
            TestConstants.TREASURY,
            address(this)
        );
        _afterPoolDeployed();

        Stubs.installPermissiveERC1271(payer);
        Stubs.acceptTreeUpdateProofs(tubVerifier, true);
    }

    /// Runs between pool deployment and the stubs. Contracts created here keep
    /// the addresses they had before this base existed, since the stubs also
    /// deploy from this contract and advance its nonce.
    function _afterPoolDeployed() internal virtual { }

    /// Targets `h`, restricted to its five handler paths. `submitSelector` is
    /// passed in because each suite fuzzes a different `submit` signature.
    function _targetHandler(EscrowHandlerBase h, bytes4 submitSelector) internal {
        targetContract(address(h));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = submitSelector;
        selectors[1] = h.flushOne.selector;
        selectors[2] = h.cancelOne.selector;
        selectors[3] = h.sweep.selector;
        selectors[4] = h.advanceBlocks.selector;
        targetSelector(FuzzSelector({ addr: address(h), selectors: selectors }));
    }
}
