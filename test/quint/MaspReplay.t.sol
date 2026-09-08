// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { SnarkCompression } from "../../src/SnarkCompression.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";
import { BatchedGroth16Verifier } from "../../src/verifiers/BatchedGroth16Verifier.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { deployPoolUniform, singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";

import { MaspSpec } from "./generated/MaspSpec.sol";
import { MaspSpecReplay } from "./generated/MaspSpecReplay.sol";

/// Driver for [spec/masp.qnt](../../spec/masp.qnt).
///
/// Deploys a real pool behind its proxy, with permit2, a mock ERC-20 and the
/// tree-update verifier `vm.mockCall`-stubbed — the same setup
/// [test/invariant/MASP.flow.invariant.t.sol](../invariant/MASP.flow.invariant.t.sol)
/// uses. What differs is what drives it: the invariant suite lets the fuzzer
/// pick calls and checks three properties at the end of a run, while this
/// replays a checked model and compares the whole state after every step.
///
/// `abstract` so Foundry does not collect it as a test contract; the generated
/// `MaspTraces` inherits it and holds one test per trace.
abstract contract MaspReplay is MaspSpecReplay {
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    /// Must match `MAX_DEPOSITS` in the spec.
    uint256 internal constant MAX_DEPOSITS = 6;
    /// The pool's *initial* delay. `setCancelDelay` moves it during a trace, so
    /// this is only asserted in `setUp`; the live value is projected state.
    ///
    /// The generator does not emit the spec's constants (v1), so this is a
    /// second copy. It is not load-bearing: a spec that disagreed would put its
    /// `cancel` / `cancelTooEarly` guards on a different block, and the replay
    /// would diverge at the first one rather than pass quietly. `setUp` asserts
    /// the *pool* agrees, which is the copy nothing else would catch.
    uint32 internal constant CANCEL_DELAY = 7200;
    address internal constant TREASURY = address(0xfee);
    /// The fee-note commitment every deposit escrows, with `feeIn` zero. Bound
    /// into the escrow digest, so flush and cancel have to resupply it.
    bytes32 internal constant FEE_CM = bytes32(uint256(0xfee));

    MASP internal masp;
    MockERC20 internal token;
    TreeUpdateBatchGroth16Verifier internal tubVerifier;
    address internal permit2;
    address internal payer = address(0xface);

    // --- driver shadow ----------------------------------------------------
    //
    // `escrowed[id]` stores one keccak digest, not the fields behind it, so
    // flush and cancel must resupply the preimage and there is nothing on
    // chain to read it back from. This is the only state `_project` does not
    // read live, and every field it feeds is cross-checked in `_project`
    // against the one thing the chain does expose: whether the escrow is still
    // occupied. Same reason `MaspFlowHandler` carries `preimage*` maps.
    uint256[] internal ids;
    mapping(uint256 id => uint48) internal shadowPublicIn;
    mapping(uint256 id => bytes32) internal shadowCm;
    mapping(uint256 id => uint256) internal shadowSubmitBlock;
    mapping(uint256 id => MaspSpec.Status) internal shadowStatus;
    uint256 internal nonce;

    function setUp() public virtual {
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        BatchedGroth16Verifier batchVerifier = new BatchedGroth16Verifier();
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("M", "M", 18);

        (uint64[] memory assetIds, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        masp = deployPoolUniform(
            IVerifier(address(tubVerifier)),
            IBatchVerifier(address(batchVerifier)),
            ISignatureTransfer(permit2),
            assetIds,
            tokens,
            scales,
            FEE_BPS,
            TREASURY,
            address(this)
        );

        // This also gives the payer code, which is why cancels have to come
        // from the payer itself.
        Stubs.installPermissiveERC1271(payer);

        // flushBatch's only dependency needing a real depth-11 proof.
        Stubs.acceptTreeUpdateProofs(IVerifier(address(tubVerifier)), true);

        // The spec hardcodes the delay it reasons about. Assert the pool agrees
        // rather than trusting two copies of a constant to stay in step.
        assertEq(masp.cancelDelay(), CANCEL_DELAY, "spec and pool disagree on cancelDelay");
        assertEq(block.number, 1, "spec `init` fixes blockNo = 1");
    }

    // --- the switch -------------------------------------------------------

    function apply_(MaspSpec.Action action, MaspSpec.Picks memory picks) external override {
        require(msg.sender == address(this), "self-call only");

        if (action == MaspSpec.Action.Submit) {
            _submit(uint64(picks.publicIn));
        } else if (action == MaspSpec.Action.Flush) {
            _flush(picks.id);
        } else if (action == MaspSpec.Action.Cancel) {
            _cancel(picks.id, false);
        } else if (action == MaspSpec.Action.CancelTooEarly) {
            _cancel(picks.id, true);
        } else if (action == MaspSpec.Action.Sweep) {
            masp.sweep(IERC20(address(token)));
        } else if (action == MaspSpec.Action.AdvanceBlocks) {
            vm.roll(block.number + picks.n);
        } else if (action == MaspSpec.Action.SetCancelDelay) {
            // Owner-only, and the driver is the owner. The pool bounds the value
            // to [CANCEL_DELAY_MIN, CANCEL_DELAY_MAX]; the spec draws only from
            // inside that range, so a revert here is a divergence, not an
            // expected rejection.
            masp.setCancelDelay(uint32(picks.newDelay));
        } else if (action == MaspSpec.Action.SetAssetDisabled) {
            masp.setAssetDisabled(ASSET_ID, picks.disabled);
        } else {
            revert("unhandled action");
        }
    }

    function _submit(uint64 publicIn) private {
        uint256 inAmt = uint256(publicIn) * SCALE;
        uint256 fee = (inAmt * FEE_BPS) / 10_000;

        // Mint exactly what the deposit costs. The model's `payerBalance` then
        // only ever moves on a refund, which makes it a direct check that the
        // pool pulled neither more nor less than it should have.
        token.mint(payer, inAmt + fee);
        vm.prank(payer);
        token.approve(permit2, type(uint256).max);

        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = publicIn;
        d.payer = payer;
        d.recipient = address(0xb0b);
        d.outCm = bytes32(uint256(0x1000 + nonce));
        d.feeCm = FEE_CM;

        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: nonce++, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00"
        });

        uint256 id = masp.deposit(d, sig, aux[0], aux[1]);

        ids.push(id);
        shadowPublicIn[id] = uint48(publicIn);
        shadowCm[id] = d.outCm;
        shadowSubmitBlock[id] = block.number;
        shadowStatus[id] = MaspSpec.Status.Pending;
    }

    /// A deposit occupies `PubInputs.LEAVES_PER_DEPOSIT` (= 2) adjacent leaves:
    /// its principal, then the note paying the flusher. `_validateBatchHeader`
    /// requires `actualCount == n * 2` and `_drainDeposit` rebuilds the escrow
    /// digest from leaf `p + 1` as the fee note, which submit escrowed as
    /// `(0, FEE_CM, [0, 0])`. Populating only leaf 0 reverts `BatchMisaligned`
    /// — which is exactly the bug `MaspFlowHandler.flushOne` shipped with.
    function _flush(uint256 id) private {
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        // The SNARK is mocked so the value is arbitrary, but it must be a field
        // element: `flushBatch` compresses the header through
        // `SnarkCompression.evaluatePolyAt`, which rejects a coefficient >= R.
        // A raw keccak clears BN254 about 78% of the time.
        tpi.newRoot = bytes32(uint256(keccak256(abi.encode("flushed", id, block.number))) % SnarkCompression.R);
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(PubInputs.LEAVES_PER_DEPOSIT);

        tpi.cms[0] = shadowCm[id];
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafPublicIn[0] = uint64(shadowPublicIn[id]);
        tpi.isDeposit[0] = 1;

        tpi.cms[1] = FEE_CM;
        // Zero value, so asset 0: the circuit canonicalises the asset of a
        // leaf whose Pedersen binding cannot see it (step 7a), and
        // `_drainDeposit` requires the match.
        tpi.leafAsset[1] = 0;
        tpi.leafPublicIn[1] = 0;
        tpi.isDeposit[1] = 1;

        uint256[] memory batch = new uint256[](1);
        batch[0] = id;

        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: payer, submittedAt: uint32(shadowSubmitBlock[id]), fbps: FEE_BPS });

        MASP.Proof memory proof;
        masp.flushBatch(batch, meta, proof, tpi);

        shadowStatus[id] = MaspSpec.Status.Flushed;
    }

    function _cancel(uint256 id, bool expectTooEarly) private {
        uint256[2] memory zCv;

        // `expectRevert` before `prank`, not after: a prank is consumed by the
        // next call, and `expectRevert` is itself a call. Ordering them the
        // other way round spends the prank on the cheatcode, the cancel arrives
        // from this contract rather than the payer, and it reverts
        // `PayerNotSender` instead of the expected `CancelTooEarly`.
        if (expectTooEarly) {
            vm.expectRevert(
                abi.encodeWithSelector(MASP.CancelTooEarly.selector, id, shadowSubmitBlock[id] + masp.cancelDelay())
            );
        }
        // MASP restricts cancellation to the payer itself once
        // `payer.code.length != 0`, and the MockERC1271 etch gives it code: a
        // contract payer must observe its own refund.
        vm.prank(payer);
        masp.cancelDeposit(
            id,
            shadowPublicIn[id],
            shadowCm[id],
            zCv,
            ASSET_ID,
            FEE_BPS,
            payer,
            uint32(shadowSubmitBlock[id]),
            PubInputs.FeeNote({ feeIn: 0, feeCm: FEE_CM, feeCvDep: zCv })
        );

        if (!expectTooEarly) shadowStatus[id] = MaspSpec.Status.Cancelled;
    }

    // --- projection -------------------------------------------------------

    function _project() internal view override returns (MaspSpec.State memory s) {
        s.blockNo = block.number;
        s.nextId = masp.nextDepositId();
        s.poolBalance = token.balanceOf(address(masp));
        s.accruedFee = masp.accruedFee(IERC20(address(token)));
        s.treasuryBalance = token.balanceOf(TREASURY);
        s.payerBalance = token.balanceOf(payer);
        s.committedCount = masp.committedCount();
        s.cancelDelay = masp.cancelDelay();
        s.assetDisabled = masp.asset(ASSET_ID).disabled;

        // Ids are dense from zero and pushed in order, so this is already the
        // ascending order the generator sorted the model's map into.
        s.deposits = new MaspSpec.DepositEntry[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 principal = uint256(shadowPublicIn[id]) * SCALE;

            // The load-bearing cross-check. `escrowed[id]` is the only thing
            // the chain exposes about a deposit's lifecycle, and it says
            // exactly one bit: still pending, or not. Asserting the shadow
            // against it means a driver bookkeeping bug fails here, by name,
            // instead of arriving at the comparison dressed as a divergence
            // between the model and the contract.
            bool pendingOnChain = masp.escrowed(id) != bytes32(0);
            require(
                pendingOnChain == (shadowStatus[id] == MaspSpec.Status.Pending),
                "driver shadow disagrees with escrowed[]"
            );

            s.deposits[i] = MaspSpec.DepositEntry({
                key: id,
                principal: principal,
                fee: (principal * FEE_BPS) / 10_000,
                submittedAt: shadowSubmitBlock[id],
                status: shadowStatus[id]
            });
        }
    }
}
