// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { deployPoolUniform, realVerifierStack, singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";

/// Handler exercises deposit / flushBatch / cancelDeposit / sweep
/// randomly. Fees accrue only at flush; the handler shadows both the
/// escrowed totals of still-pending deposits and the expected `accruedFee`
/// so the invariants can assert solvency and accrual timing exactly.
///
/// A deposit pays its relayer note either in the deposit token or in a second
/// registered token (`FEE_ASSET_ID`, under its own `scale`). Solvency is
/// shadowed per token, so a note pulled, refunded or backed in the wrong token
/// breaks one side of the books.
contract EscrowFeeHandler is Test {
    MASP public masp;
    address public permit2;
    MockERC20 public token;
    MockERC20 public feeToken;
    address public payer;

    uint64 public constant ASSET_ID = 1;
    uint256 public constant SCALE = 1e10;
    uint16 public constant FEE_BPS = 25;
    uint64 public constant FEE_ASSET_ID = 2;
    uint256 public constant FEE_SCALE = 1e6;

    /// All deposit ids ever submitted (pending OR cleared).
    uint256[] public allIds;
    /// id → fee locked at submit (asset-units * scale).
    mapping(uint256 => uint256) public feeAt;
    /// id → principal locked at submit.
    mapping(uint256 => uint256) public principalAt;
    /// Token amount backing each deposit's relayer fee note. Distinct from
    /// `feeAt`: this one never accrues, it becomes shielded principal.
    mapping(uint256 => uint256) public relayerFeeAt;
    mapping(uint256 => uint64) public relayerFeeIn;
    /// id → the asset the relayer note is paid in: `ASSET_ID` or `FEE_ASSET_ID`.
    mapping(uint256 => uint64) public relayerFeeAsset;
    /// id → still pending?
    mapping(uint256 => bool) public pending;
    /// id → cancel/flush preimage shadow. The 1-slot escrow stores only the
    /// digest, so the handler must remember every preimage field off-chain
    /// to rebuild it at flush/cancel time.
    mapping(uint256 => uint48) public preimagePublicIn;
    mapping(uint256 => bytes32) public preimageCm0;
    mapping(uint256 => uint32) public preimageSubmittedAt;
    /// Sum of `inAmt + fee + relayerFee` for pending ids; escrowed balance not
    /// yet in `accruedFee`.
    uint256 public expectedPendingTotal;
    /// Mirrors masp.accruedFee(token): += fee at flush, reset by sweep.
    uint256 public expectedAccrued;
    /// Sum of principals and relayer fees for flushed ids (held in the pool as
    /// shielded value).
    uint256 public shieldedPrincipal;
    /// The same two books in `feeToken`, which only relayer notes paid in
    /// `FEE_ASSET_ID` fill. Nothing in `feeToken` ever accrues.
    uint256 public expectedPendingFeeToken;
    uint256 public shieldedFeeToken;

    uint256 internal _nonce;

    constructor(MASP m, address p2, MockERC20 t, MockERC20 ft, address payer_) {
        masp = m;
        permit2 = p2;
        token = t;
        feeToken = ft;
        payer = payer_;
    }

    function _aux() internal pure returns (AuxValidation.Output[6] memory aux) {
        return SpendFixture.validAux();
    }

    /// Handler: submit a fresh deposit.
    function submit(uint64 publicIn, uint64 feeIn, bool crossAsset) external {
        publicIn = uint64(bound(publicIn, 1, 1_000));
        // Non-zero: a zero-value fee note would let solvency hold regardless of
        // how the relayer's leg is accounted.
        feeIn = uint64(bound(feeIn, 1, 100));

        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;
        uint64 feeAsset = crossAsset ? FEE_ASSET_ID : ASSET_ID;
        uint256 relayerFee = uint256(feeIn) * (crossAsset ? FEE_SCALE : SCALE);
        if (crossAsset) {
            token.mint(payer, inAmt + fee);
            feeToken.mint(payer, relayerFee);
        } else {
            token.mint(payer, inAmt + fee + relayerFee);
        }
        vm.startPrank(payer);
        token.approve(address(permit2), type(uint256).max);
        feeToken.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = address(0xb0b);
        d.outCm = bytes32(uint256(0x1000 + _nonce));
        d.feeCm = bytes32(uint256(0xfee));
        d.feeIn = feeIn;
        d.feeAssetId = feeAsset;

        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: _nonce++,
            deadline: type(uint256).max,
            maxTotal: type(uint256).max,
            maxFee: crossAsset ? type(uint256).max : 0,
            signature: hex"00"
        });

        uint256 id = masp.deposit(d, sig, _aux()[0], _aux()[1]);
        allIds.push(id);
        feeAt[id] = fee;
        principalAt[id] = inAmt;
        relayerFeeAt[id] = relayerFee;
        relayerFeeIn[id] = feeIn;
        relayerFeeAsset[id] = feeAsset;
        pending[id] = true;
        // forge-lint: disable-next-line(unsafe-typecast)
        preimagePublicIn[id] = uint48(publicIn);
        preimageCm0[id] = d.outCm;
        // forge-lint: disable-next-line(unsafe-typecast)
        preimageSubmittedAt[id] = uint32(block.number);
        if (crossAsset) {
            expectedPendingTotal += inAmt + fee;
            expectedPendingFeeToken += relayerFee;
        } else {
            expectedPendingTotal += inAmt + fee + relayerFee;
        }
    }

    /// Relayer note value owed in `token` and in `feeToken` for `id`.
    function _relayerSplit(uint256 id) internal view returns (uint256 inToken, uint256 inFeeToken) {
        if (relayerFeeAsset[id] == FEE_ASSET_ID) return (0, relayerFeeAt[id]);
        return (relayerFeeAt[id], 0);
    }

    /// Handler: flush one pending deposit (uses mocked SNARK verify).
    function flushOne(uint256 idxSeed) external {
        if (allIds.length == 0) return;
        uint256 id = _firstPendingFrom(idxSeed);
        if (!pending[id]) return; // none pending

        // Rebuild tpi from the off-chain preimage shadow; the digest check
        // in `_drainDeposit` enforces every field matches what was escrowed.
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(masp.committedCount()) + 1); // arbitrary; SNARK is mocked
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = 2;
        tpi.cms[0] = preimageCm0[id];
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafPublicIn[0] = uint64(preimagePublicIn[id]);
        tpi.isDeposit[0] = 1;
        tpi.cms[1] = bytes32(uint256(0xfee));
        // Zero-value leaves declare asset 0: `tree_update_batch.circom` step 6a
        // canonicalises the asset of a leaf whose Pedersen binding cannot see
        // it, and `_drainDeposit` requires the match.
        tpi.leafAsset[1] = relayerFeeIn[id] == 0 ? 0 : relayerFeeAsset[id];
        tpi.leafPublicIn[1] = relayerFeeIn[id];
        tpi.isDeposit[1] = 1;

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: payer, submittedAt: preimageSubmittedAt[id], fbps: FEE_BPS });

        MASP.Proof memory proof;
        masp.flushBatch(ids, meta, proof, tpi);

        pending[id] = false;
        (uint256 rTok, uint256 rFee) = _relayerSplit(id);
        expectedPendingTotal -= principalAt[id] + feeAt[id] + rTok;
        expectedPendingFeeToken -= rFee;
        // The relayer's note is principal, not an accrual: the pool must keep
        // holding the tokens behind it, in the token it was paid in, or the
        // note is unspendable.
        shieldedPrincipal += principalAt[id] + rTok;
        shieldedFeeToken += rFee;
        expectedAccrued += feeAt[id];
    }

    /// Handler: cancel one pending deposit (rolls past cancelDelay first).
    function cancelOne(uint256 idxSeed) external {
        if (allIds.length == 0) return;
        uint256 id = _firstPendingFrom(idxSeed);
        if (!pending[id]) return;

        // Roll past delay.
        vm.roll(block.number + masp.cancelDelay());

        uint256[2] memory zCv;
        // The payer is `vm.etch`ed with MockERC1271 so Permit2's ERC-1271
        // check passes at submit, which gives it code, and MASP restricts
        // cancel to the payer itself when `payer.code.length != 0`. The prank
        // satisfies that restriction; without it every cancel reverts
        // `PayerNotSender`.
        vm.prank(payer);
        masp.cancelDeposit(
            id,
            preimagePublicIn[id],
            preimageCm0[id],
            zCv,
            ASSET_ID,
            FEE_BPS,
            payer,
            preimageSubmittedAt[id],
            PubInputs.FeeNote({
                feeIn: uint48(relayerFeeIn[id]),
                feeAssetId: relayerFeeIn[id] == 0 ? 0 : relayerFeeAsset[id],
                feeCm: bytes32(uint256(0xfee)),
                feeCvDep: zCv
            })
        );
        pending[id] = false;
        (uint256 rTok, uint256 rFee) = _relayerSplit(id);
        expectedPendingTotal -= principalAt[id] + feeAt[id] + rTok;
        expectedPendingFeeToken -= rFee;
    }

    /// Handler: sweep accrued fees to treasury.
    function sweep() external {
        masp.sweep(IERC20(address(token)));
        expectedAccrued = 0;
        // Nothing accrues in the fee token, so its sweep moves nothing.
        masp.sweep(IERC20(address(feeToken)));
    }

    /// Handler: advance the block number without touching pool state.
    function advanceBlocks(uint16 n) external {
        n = uint16(bound(n, 1, 200));
        vm.roll(block.number + n);
    }

    /// First pending id at or after `seed % len`, wrapping. If none is pending,
    /// returns the id at `seed % len`, which the caller detects and skips.
    function _firstPendingFrom(uint256 seed) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return type(uint256).max;
        uint256 start = seed % n;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = allIds[(start + k) % n];
            if (pending[id]) return id;
        }
        return allIds[start]; // none pending; caller checks
    }
}

contract MASPEscrowFeeInvariantTest is Test {
    IVerifier tubVerifier;
    IBatchVerifier batchVerifier;
    address permit2;
    MockERC20 token;
    MockERC20 feeToken;
    MASP masp;
    EscrowFeeHandler handler;

    address payer = address(0xface);

    function setUp() public {
        ISignatureTransfer p2;
        (tubVerifier, batchVerifier, p2) = realVerifierStack();
        permit2 = address(p2);
        token = new MockERC20("M", "M", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), 1, 1e10);

        masp = deployPoolUniform(tubVerifier, batchVerifier, p2, ids, tokens, scales, 25, address(0xfee), address(this));
        feeToken = new MockERC20("F", "F", 6);
        masp.addAsset(2, IERC20(address(feeToken)), 1e6, 25, 25);

        Stubs.installPermissiveERC1271(payer);

        // Accept tree-update proofs: the only flushBatch dependency that needs a depth-10 proof.
        Stubs.acceptTreeUpdateProofs(tubVerifier, true);

        handler = new EscrowFeeHandler(masp, permit2, token, feeToken, payer);
        targetContract(address(handler));

        // Restrict to handler's external functions.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.submit.selector;
        selectors[1] = handler.flushOne.selector;
        selectors[2] = handler.cancelOne.selector;
        selectors[3] = handler.sweep.selector;
        selectors[4] = handler.advanceBlocks.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// Solvency: the pool balance equals every still-escrowed total
    /// (principal + fee + relayer fee, not in `accruedFee` until flush), every
    /// flushed principal including relayer fee notes, and the fee claimable by
    /// sweep. Sweep never touches escrowed funds.
    function invariant_solvency() public view {
        uint256 bal = token.balanceOf(address(masp));
        uint256 owed =
            handler.expectedPendingTotal() + handler.shieldedPrincipal() + masp.accruedFee(IERC20(address(token)));
        assertEq(bal, owed, "pool balance covers escrow + shielded + claimable fee");
    }

    /// Solvency in the relayer fee token: the pool holds exactly the notes paid
    /// in it, pending or flushed, and nothing of it accrues.
    function invariant_solvencyFeeToken() public view {
        assertEq(
            feeToken.balanceOf(address(masp)),
            handler.expectedPendingFeeToken() + handler.shieldedFeeToken(),
            "pool balance covers fee-token notes, pending and shielded"
        );
        assertEq(masp.accruedFee(IERC20(address(feeToken))), 0, "fee token never accrues");
    }

    /// Accrual timing: `accruedFee` moves only at flush (up by the deposit's
    /// submit-time fee) and at sweep (to zero). Submit and cancel do not
    /// touch it.
    function invariant_accrualOnlyAtFlush() public view {
        assertEq(masp.accruedFee(IERC20(address(token))), handler.expectedAccrued(), "accruedFee drift");
    }
}
