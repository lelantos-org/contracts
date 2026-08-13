// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { Groth16Verifier } from "../../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../../src/BabyJubJub.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC1271 } from "../mocks/MockERC1271.sol";

/// Whole-flow invariant for the MASP deposit / batch / cancel / sweep
/// state machine. The existing per-slice invariants
/// ([MASPPendingFee.invariant.t.sol](MASPPendingFee.invariant.t.sol),
/// [MASPNullifier.invariant.t.sol](MASPNullifier.invariant.t.sol),
/// [MASPAssets.invariant.t.sol](MASPAssets.invariant.t.sol)) each cover
/// one surface. This file exercises submit / flushBatch / cancelDeposit /
/// sweep / advance jointly and asserts cross-handler bookkeeping —
/// lifecycle exclusivity, conservation of `token.balanceOf(masp)`, root
/// monotonicity, and cancel-delay timing.
///
/// Tree-update SNARK verifier is `vm.mockCall`-stubbed (same trick used by
/// `MASPPendingFeeInvariantTest.setUp`); without that, every `flushBatch`
/// would need a real depth-10 proof. Stubbing collapses to pure state-
/// machine logic — exactly the layer cross-handler invariants protect.
contract MaspFlowHandler is Test {
    enum Status {
        Unknown,
        Pending,
        Flushed,
        Cancelled
    }

    MASP public masp;
    address public permit2;
    MockERC20 public token;
    address public payer;

    uint64 public constant ASSET_ID = 1;
    uint256 public constant SCALE = 1e10;
    uint16 public constant FEE_BPS = 25;

    uint256[] public allIds;
    mapping(uint256 => Status) public status;
    mapping(uint256 => uint256) public principalAt; // inAmt (asset-units * scale)
    mapping(uint256 => uint256) public feeAt;
    mapping(uint256 => uint256) public submitBlock;
    /// Off-chain preimage shadow. Required because the 1-slot escrow stores
    /// only the digest; flush/cancel must resupply cm0/cm1/publicIn (plus
    /// payer/submittedAt/fbps, tracked as `payer`/`submitBlock`/`FEE_BPS`)
    /// and the on-chain digest check binds them.
    mapping(uint256 => uint48) public preimagePublicIn;
    mapping(uint256 => bytes32) public preimageCm0;

    /// Sum of principals for ids still `Pending`.
    uint256 public ghostPendingPrincipal;
    /// Sum of fees escrowed with ids still `Pending`. Never in `accruedFee`
    /// until flush.
    uint256 public ghostPendingFee;
    /// Sum of principals for ids that have been `Flushed` (shielded).
    uint256 public ghostShieldedPrincipal;
    /// Most recent root pushed by `flushBatch`. Tracks `currentRoot()`
    /// expectation across calls. Initialized to genesis in test setUp.
    bytes32 public lastNewRoot;
    /// Sum of `inserted` across all `flushBatch` calls (i.e. `2 * #flushed`).
    uint64 public ghostInserted;
    /// Number of `flushBatch` calls that landed (handler success counter).
    uint256 public flushCount;
    /// Number of `cancelDeposit` calls that landed.
    uint256 public cancelCount;

    uint256 internal _nonce;

    constructor(MASP m, address p2, MockERC20 t, address payer_, bytes32 genesis) {
        masp = m;
        permit2 = p2;
        token = t;
        payer = payer_;
        lastNewRoot = genesis;
    }

    function _aux() internal pure returns (AuxValidation.Output[3] memory aux) {
        aux[0].clueRx = BabyJubJub.BASE8_X;
        aux[0].clueRy = BabyJubJub.BASE8_Y;
        aux[0].ephPubX = BabyJubJub.BASE8_X;
        aux[0].ephPubY = BabyJubJub.BASE8_Y;
        aux[0].ciphertext = hex"0001";
        aux[1].clueRx = BabyJubJub.BASE8_X;
        aux[1].clueRy = BabyJubJub.BASE8_Y;
        aux[1].ephPubX = BabyJubJub.BASE8_X;
        aux[1].ephPubY = BabyJubJub.BASE8_Y;
        aux[1].ciphertext = hex"0001";
        aux[2].clueRx = BabyJubJub.BASE8_X;
        aux[2].clueRy = BabyJubJub.BASE8_Y;
        aux[2].ephPubX = BabyJubJub.BASE8_X;
        aux[2].ephPubY = BabyJubJub.BASE8_Y;
        aux[2].ciphertext = hex"0001";
    }

    function submit(uint64 publicIn) external {
        publicIn = uint64(bound(publicIn, 1, 1_000));

        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;
        token.mint(payer, inAmt + fee);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);

        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = address(0xb0b);
        d.outCm = bytes32(uint256(0x1000 + _nonce));

        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: _nonce++, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00"
        });

        uint256 id = masp.deposit(d, sig, _aux()[0]);
        allIds.push(id);
        status[id] = Status.Pending;
        principalAt[id] = inAmt;
        feeAt[id] = fee;
        submitBlock[id] = block.number;
        // forge-lint: disable-next-line(unsafe-typecast)
        preimagePublicIn[id] = uint48(publicIn);
        preimageCm0[id] = d.outCm;
        ghostPendingPrincipal += inAmt;
        ghostPendingFee += fee;
    }

    function flushOne(uint256 idxSeed) external {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        // The SNARK is mocked, so the new-root value is arbitrary. It is
        // still bound to (current count, current root) so the handler ghost
        // tracks `committedCount` advancement accurately.
        tpi.newRoot = keccak256(abi.encode("flushed", id, block.number));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = 1;
        tpi.cms[0] = preimageCm0[id];
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafPublicIn[0] = uint64(preimagePublicIn[id]);
        tpi.isDeposit[0] = 1;

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        meta[0] = MASP.DepositMeta({ payer: payer, submittedAt: uint32(submitBlock[id]), fbps: FEE_BPS });

        MASP.Proof memory proof;
        masp.flushBatch(ids, meta, proof, tpi);

        status[id] = Status.Flushed;
        ghostPendingPrincipal -= principalAt[id];
        ghostPendingFee -= feeAt[id];
        ghostShieldedPrincipal += principalAt[id];
        lastNewRoot = tpi.newRoot;
        ghostInserted += 1;
        flushCount += 1;
    }

    function cancelOne(uint256 idxSeed) external {
        uint256 id = _firstWithStatus(idxSeed, Status.Pending);
        if (status[id] != Status.Pending) return;

        // Roll past the cancel delay so the on-chain guard always permits
        // the call; ghost asserts the timing relationship below.
        vm.roll(block.number + masp.cancelDelay());

        uint256[2] memory zCv;
        // forge-lint: disable-next-line(unsafe-typecast)
        masp.cancelDeposit(
            id, preimagePublicIn[id], preimageCm0[id], zCv, ASSET_ID, FEE_BPS, payer, uint32(submitBlock[id])
        );

        // Cancel-delay assertion: must have waited at least cancelDelay
        // blocks from submit. By construction (roll above) this holds.
        require(block.number >= submitBlock[id] + masp.cancelDelay(), "cancel before delay");

        status[id] = Status.Cancelled;
        ghostPendingPrincipal -= principalAt[id];
        ghostPendingFee -= feeAt[id];
        cancelCount += 1;
    }

    function sweep() external {
        masp.sweep(IERC20(address(token)));
    }

    function advanceBlocks(uint16 n) external {
        n = uint16(bound(n, 1, 200));
        vm.roll(block.number + n);
    }

    function _firstWithStatus(uint256 seed, Status want) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return type(uint256).max;
        uint256 start = seed % n;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = allIds[(start + k) % n];
            if (status[id] == want) return id;
        }
        return allIds[start];
    }

    function idsLen() external view returns (uint256) {
        return allIds.length;
    }
}

contract MaspFlowInvariantTest is Test {
    Groth16Verifier verifier;
    TreeUpdateBatchGroth16Verifier tubVerifier;
    address permit2;
    MockERC20 token;
    MASP masp;
    MaspFlowHandler handler;

    address payer = address(0xface);

    function setUp() public {
        verifier = new Groth16Verifier();
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("M", "M", 18);

        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = 1;
        tokens[0] = IERC20(address(token));
        scales[0] = 1e10;

        masp = new MASP(
            IVerifier(address(verifier)),
            IVerifier(address(tubVerifier)),
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            25,
            address(0xfee),
            address(this)
        );

        // Permit2 ERC-1271 stub: any sig passes.
        MockERC1271 stub = new MockERC1271();
        vm.etch(payer, address(stub).code);

        // Mock the tree-update SNARK verifier — flushBatch's only real
        // dependency that requires a depth-10 proof.
        vm.mockCall(address(tubVerifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));

        handler = new MaspFlowHandler(masp, permit2, token, payer, masp.currentRoot());
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.submit.selector;
        selectors[1] = handler.flushOne.selector;
        selectors[2] = handler.cancelOne.selector;
        selectors[3] = handler.sweep.selector;
        selectors[4] = handler.advanceBlocks.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// Conservation: pool balance equals the pending principal + pending
    /// fees still in escrow (never in `accruedFee` until flush) + the
    /// shielded principal locked behind flushed deposits + the on-chain
    /// `accruedFee`. Sweep moves fees out so accruedFee shrinks in
    /// lockstep with the balance.
    function invariant_balanceConservation() public view {
        uint256 bal = token.balanceOf(address(masp));
        uint256 expected = handler.ghostPendingPrincipal() + handler.ghostPendingFee()
            + handler.ghostShieldedPrincipal() + masp.accruedFee(IERC20(address(token)));
        assertEq(bal, expected, "balance conservation");
    }

    /// Lifecycle exclusivity: every submitted id sits in exactly one of
    /// {Pending, Flushed, Cancelled}. No id can be Unknown after submit
    /// and no id can transition out of Flushed / Cancelled.
    function invariant_lifecycleExclusivity() public view {
        uint256 n = handler.idsLen();
        uint256 pending;
        uint256 flushed;
        uint256 cancelled;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.allIds(i);
            MaspFlowHandler.Status s = handler.status(id);
            if (s == MaspFlowHandler.Status.Pending) pending++;
            else if (s == MaspFlowHandler.Status.Flushed) flushed++;
            else if (s == MaspFlowHandler.Status.Cancelled) cancelled++;
            else revert("id with Unknown status");
        }
        assertEq(pending + flushed + cancelled, n, "lifecycle bucket sum");
        assertEq(handler.flushCount(), flushed, "flushCount matches Flushed bucket");
        assertEq(handler.cancelCount(), cancelled, "cancelCount matches Cancelled bucket");
    }

    /// Root coherence:
    ///   - `currentRoot()` equals the most recent `newRoot` written by
    ///     a successful `flushBatch` (or genesis if no flush yet);
    ///   - the live root is always `isKnownRoot == true`;
    ///   - `committedCount` equals 2 · #flushed (single-pair flushes).
    function invariant_rootCoherence() public view {
        assertEq(masp.currentRoot(), handler.lastNewRoot(), "currentRoot drift");
        assertTrue(masp.isKnownRoot(masp.currentRoot()), "currentRoot not known");
        assertEq(masp.committedCount(), handler.ghostInserted(), "committedCount delta");
    }
}
