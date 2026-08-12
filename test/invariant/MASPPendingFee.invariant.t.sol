// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";
import { Groth16Verifier } from "../../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../../src/BabyJubJub.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC1271 } from "../mocks/MockERC1271.sol";

/// Handler exercises submitIntent / flushBatch / cancelIntent / sweep
/// randomly. Fees accrue only at flush; the handler shadows both the
/// escrowed totals of still-pending intents and the expected `accruedFee`
/// so the invariants can assert solvency and accrual timing exactly.
contract EscrowFeeHandler is Test {
    MASP public masp;
    address public permit2;
    MockERC20 public token;
    address public payer;

    uint64 public constant ASSET_ID = 1;
    uint256 public constant SCALE = 1e10;
    uint16 public constant FEE_BPS = 25;

    /// All intent ids ever submitted (pending OR cleared).
    uint256[] public allIds;
    /// id → fee locked at submit (asset-units * scale).
    mapping(uint256 => uint256) public feeAt;
    /// id → principal locked at submit.
    mapping(uint256 => uint256) public principalAt;
    /// id → still pending?
    mapping(uint256 => bool) public pending;
    /// id → cancel/flush preimage shadow. The 1-slot escrow stores only the
    /// digest, so the handler must remember every preimage field off-chain
    /// to rebuild it at flush/cancel time.
    mapping(uint256 => uint48) public preimagePublicIn;
    mapping(uint256 => bytes32) public preimageCm0;
    mapping(uint256 => uint32) public preimageSubmittedAt;
    /// Sum of `inAmt + fee` for pending ids; escrowed balance not yet in
    /// `accruedFee`.
    uint256 public expectedPendingTotal;
    /// Mirrors masp.accruedFee(token): += fee at flush, reset by sweep.
    uint256 public expectedAccrued;
    /// Sum of principals for flushed ids (stay in the pool as shielded).
    uint256 public shieldedPrincipal;

    uint256 internal _nonce;

    constructor(MASP m, address p2, MockERC20 t, address payer_) {
        masp = m;
        permit2 = p2;
        token = t;
        payer = payer_;
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

    /// Handler: submit a fresh intent.
    function submit(uint64 publicIn) external {
        publicIn = uint64(bound(publicIn, 1, 1_000));

        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;
        token.mint(payer, inAmt + fee);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);

        PubInputs.DepositIntent memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = address(0xb0b);
        d.outCm = bytes32(uint256(0x1000 + _nonce));

        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: _nonce++, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00"
        });

        uint256 id = masp.submitIntent(d, sig, _aux()[0]);
        allIds.push(id);
        feeAt[id] = fee;
        principalAt[id] = inAmt;
        pending[id] = true;
        // forge-lint: disable-next-line(unsafe-typecast)
        preimagePublicIn[id] = uint48(publicIn);
        preimageCm0[id] = d.outCm;
        // forge-lint: disable-next-line(unsafe-typecast)
        preimageSubmittedAt[id] = uint32(block.number);
        expectedPendingTotal += inAmt + fee;
    }

    /// Handler: flush one pending intent (uses mocked SNARK verify).
    function flushOne(uint256 idxSeed) external {
        if (allIds.length == 0) return;
        uint256 id = _firstPendingFrom(idxSeed);
        if (!pending[id]) return; // none pending

        // Rebuild tpi from the off-chain preimage shadow; the digest check
        // in `_drainIntent` enforces every field matches what was escrowed.
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(masp.committedCount()) + 1); // arbitrary; SNARK is mocked
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = 1;
        tpi.cms[0] = preimageCm0[id];
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafPublicIn[0] = uint64(preimagePublicIn[id]);
        tpi.isDeposit[0] = 1;

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        MASP.IntentMeta[] memory meta = new MASP.IntentMeta[](1);
        meta[0] = MASP.IntentMeta({ payer: payer, submittedAt: preimageSubmittedAt[id], fbps: FEE_BPS });

        MASP.Proof memory proof;
        masp.flushBatch(ids, meta, proof, tpi);

        pending[id] = false;
        expectedPendingTotal -= principalAt[id] + feeAt[id];
        shieldedPrincipal += principalAt[id];
        expectedAccrued += feeAt[id];
    }

    /// Handler: cancel one pending intent (rolls past cancelDelay first).
    function cancelOne(uint256 idxSeed) external {
        if (allIds.length == 0) return;
        uint256 id = _firstPendingFrom(idxSeed);
        if (!pending[id]) return;

        // Roll past delay.
        vm.roll(block.number + masp.cancelDelay());

        uint256[2] memory zCv;
        masp.cancelIntent(
            id, preimagePublicIn[id], preimageCm0[id], zCv, ASSET_ID, FEE_BPS, payer, preimageSubmittedAt[id]
        );
        pending[id] = false;
        expectedPendingTotal -= principalAt[id] + feeAt[id];
    }

    /// Handler: sweep accrued fees to treasury.
    function sweep() external {
        masp.sweep(IERC20(address(token)));
        expectedAccrued = 0;
    }

    /// Handler: advance blocks (no-op state change but lets cancel tests fire).
    function advanceBlocks(uint16 n) external {
        n = uint16(bound(n, 1, 200));
        vm.roll(block.number + n);
    }

    /// Find first pending id starting at `seed % len`. Returns the seed-id
    /// itself if it's not pending (the caller will short-circuit).
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
    Groth16Verifier verifier;
    TreeUpdateBatchGroth16Verifier tubVerifier;
    address permit2;
    MockERC20 token;
    MASP masp;
    EscrowFeeHandler handler;

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
            IWrappedNative(address(0)),
            ids,
            tokens,
            scales,
            25,
            address(0xfee),
            address(this)
        );

        // Permissive ERC-1271 stub at payer so any sig bytes pass Permit2.
        MockERC1271 stub = new MockERC1271();
        vm.etch(payer, address(stub).code);

        // Mock the batch SNARK verifier to always return true.
        vm.mockCall(address(tubVerifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));

        handler = new EscrowFeeHandler(masp, permit2, token, payer);
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

    /// Solvency: the pool always holds every still-escrowed total
    /// (principal + fee, never in `accruedFee` until flush), every flushed
    /// principal, and whatever fee is claimable by sweep. Sweep can never
    /// touch escrowed funds.
    function invariant_solvency() public view {
        uint256 bal = token.balanceOf(address(masp));
        uint256 owed =
            handler.expectedPendingTotal() + handler.shieldedPrincipal() + masp.accruedFee(IERC20(address(token)));
        assertEq(bal, owed, "pool balance covers escrow + shielded + claimable fee");
    }

    /// Accrual timing: `accruedFee` moves ONLY at flush (up by the intent's
    /// submit-time fee) and at sweep (to zero). Submit and cancel never
    /// touch it.
    function invariant_accrualOnlyAtFlush() public view {
        assertEq(masp.accruedFee(IERC20(address(token))), handler.expectedAccrued(), "accruedFee drift");
    }
}
