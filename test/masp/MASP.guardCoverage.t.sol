// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { MockBatchVerifier } from "../mocks/MockBatchVerifier.sol";
import { Groth16Verifier } from "../../src/verifiers/Verifier.sol";
import { BatchedGroth16Verifier } from "../../src/verifiers/BatchedGroth16Verifier.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { uniformBps } from "../utils/FeeArrays.sol";
import { MockPoolTestBase } from "../utils/MockPoolTestBase.sol";
import {
    deployBehindProxy,
    deployPoolUniform,
    newPoolImplementation,
    poolInitCalldata,
    singleAsset
} from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";

/// Guards with no direct assertion elsewhere in the suite: constructor
/// dependency checks, registry bounds, spend-path magnitude bounds, batch
/// mode, and the small-subgroup rejection in `AuxValidation`.
contract MASPGuardCoverageTest is MockPoolTestBase {
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    address internal constant PAYER = address(0xBEEF);

    /// Real contracts, used only by the constructor probe tests.
    Groth16Verifier internal realVerifier;
    BatchedGroth16Verifier internal realBatchVerifier;

    /// Builds the mock stack inline rather than through `_deployMockPool`, so
    /// the real verifiers keep their place in the deployment order ahead of
    /// Permit2.
    function setUp() public {
        token = new MockERC20("T", "T", 18);
        tub = IVerifier(address(new MockERC20("tub", "tub", 18)));
        bv = new MockBatchVerifier();
        realVerifier = new Groth16Verifier();
        realBatchVerifier = new BatchedGroth16Verifier();
        permit2 = ISignatureTransfer(new DeployPermit2().deployPermit2());
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = _registry();
        masp = _deploy(tub, bv, permit2, ids, tokens, scales);
        Stubs.acceptAllProofs(tub, bv);
    }

    // --- helpers -----------------------------------------------------------

    /// The pool's registry: `token` alone at the fixture id and scale.
    function _registry() internal view returns (uint64[] memory, IERC20[] memory, uint256[] memory) {
        return singleAsset(IERC20(address(token)), ASSET_ID, SCALE);
    }

    function _deploy(
        IVerifier tub_,
        IBatchVerifier bv_,
        ISignatureTransfer p2,
        uint64[] memory ids,
        IERC20[] memory tokens,
        uint256[] memory scales
    ) internal returns (MASP) {
        return deployPoolUniform(tub_, bv_, p2, ids, tokens, scales, FEE_BPS, TREASURY, address(this));
    }

    /// The reverting counterpart of `_deploy`. Initialization validation runs
    /// inside the proxy's constructor, so the implementation is deployed first;
    /// otherwise its own CREATE consumes `vm.expectRevert`.
    function _expectDeployRevert(
        bytes4 err,
        IVerifier tub_,
        IBatchVerifier bv_,
        ISignatureTransfer p2,
        uint64[] memory ids,
        IERC20[] memory tokens,
        uint256[] memory scales
    ) internal {
        MASP impl = newPoolImplementation();
        bytes memory initData = poolInitCalldata(
            tub_,
            bv_,
            p2,
            ids,
            tokens,
            scales,
            uniformBps(ids.length, FEE_BPS),
            uniformBps(ids.length, FEE_BPS),
            TREASURY,
            address(this)
        );
        vm.expectRevert(err);
        deployBehindProxy(address(impl), initData);
    }

    /// `_expectDeployRevert` over the suite's own registry, for the probes whose
    /// subject is a dependency rather than the registry.
    function _expectDeployRevert(bytes4 err, IVerifier tub_, IBatchVerifier bv_, ISignatureTransfer p2) internal {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = _registry();
        _expectDeployRevert(err, tub_, bv_, p2, ids, tokens, scales);
    }

    function _pi() internal view returns (PubInputs.Transact memory pi) {
        pi = _transact(PAYER, RELAYER, 0x1111, 0x3333);
        pi.publicAssetId = ASSET_ID;
        pi.publicOut = 1;
    }

    // --- batched spend verification ----------------------------------------

    /// The spend path must make exactly one verification call, to
    /// `SPEND_VERIFIER`. Two single-proof calls would forfeit the gas saving,
    /// and a missing call would still satisfy every mocked test in the suite.
    function test_spendRoutesThroughBatchVerifierOnly() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);

        // Funds the pool so the call can pay out and complete.
        token.mint(address(masp), 1e18);

        vm.expectCall(address(bv), abi.encodeWithSelector(IBatchVerifier.verifyBatch.selector), 1);
        // The tree-update verifier is wired for `flushBatch`; a spend must not
        // reach it.
        vm.expectCall(address(tub), abi.encodeWithSelector(IVerifier.verifyProof.selector), 0);

        vm.prank(RELAYER);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// `verifyBatch` returns false rather than reverting, so `_verifyProofs`
    /// must check the bool. Omitting that check fails open and is not detected
    /// by tests that mock verification to `true`.
    function test_revert_ProofRejected_whenBatchReturnsFalse() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);

        bv.setResult(false);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.ProofRejected.selector);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    // --- constructor dependency checks -------------------------------------

    function test_revert_ZeroVerifier_treeUpdate() public {
        _expectDeployRevert(MASP.ZeroVerifier.selector, IVerifier(address(0)), bv, permit2);
    }

    /// The check is `code.length == 0`, so an EOA-shaped address is rejected
    /// even though it is non-zero.
    function test_revert_ZeroVerifier_codelessAddress() public {
        _expectDeployRevert(MASP.ZeroVerifier.selector, IVerifier(address(0xdeadbeef)), bv, permit2);
    }

    function test_revert_ZeroVerifier_batch() public {
        _expectDeployRevert(MASP.ZeroVerifier.selector, tub, IBatchVerifier(address(0)), permit2);
    }

    /// The constructor probes the spend slot rather than trusting the address.
    /// A contract with code but no `verifyBatch` reverts into the probe's
    /// `catch`; a single-proof `Groth16Verifier` is the likely misconfiguration.
    function test_revert_BadSpendVerifier_wrongInterface() public {
        _expectDeployRevert(MASP.BadSpendVerifier.selector, tub, IBatchVerifier(address(realVerifier)), permit2);
    }

    /// The real batch verifier passes the probe. Without this, the test above
    /// would also pass against a probe that rejected every address.
    function test_realSpendVerifierPassesProbe() public {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = _registry();
        MASP deployed = _deploy(tub, realBatchVerifier, permit2, ids, tokens, scales);
        assertEq(address(deployed.SPEND_VERIFIER()), address(realBatchVerifier), "batch verifier wired");
    }

    function test_revert_ZeroPermit2() public {
        _expectDeployRevert(MASP.ZeroPermit2.selector, tub, bv, ISignatureTransfer(address(0)));
    }

    // --- registry bounds ---------------------------------------------------

    function test_revert_LengthMismatch_tokens() public {
        (uint64[] memory ids,, uint256[] memory scales) = _registry();
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(token));
        tokens[1] = IERC20(address(token));
        _expectDeployRevert(AssetRegistry.LengthMismatch.selector, tub, bv, permit2, ids, tokens, scales);
    }

    function test_revert_LengthMismatch_scales() public {
        (uint64[] memory ids, IERC20[] memory tokens,) = _registry();
        uint256[] memory scales = new uint256[](2);
        _expectDeployRevert(AssetRegistry.LengthMismatch.selector, tub, bv, permit2, ids, tokens, scales);
    }

    function test_revert_ScaleTooLarge() public {
        vm.expectRevert(AssetRegistry.ScaleTooLarge.selector);
        masp.addAsset(2, IERC20(address(token)), 1e18 + 1, 0, 0);
    }

    function test_scaleAtBound_accepted() public {
        masp.addAsset(2, IERC20(address(token)), 1e18, 0, 0);
        assertEq(masp.asset(2).scale, 1e18, "scale at bound");
    }

    // --- spend-path magnitude + mode bounds --------------------------------

    function test_revert_PublicOutTooLarge() public {
        PubInputs.Transact memory pi = _pi();
        pi.publicOut = uint64(type(uint48).max) + 1;
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        vm.prank(RELAYER);
        vm.expectRevert(MASP.PublicOutTooLarge.selector);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, SpendFixture.validAux());
    }

    /// `flushBatch` slots must be deposits; a spend-mode slot is rejected
    /// before any digest comparison.
    function test_revert_BadDepositMode() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        MASP.DepositMeta[] memory meta = new MASP.DepositMeta[](1);
        meta[0] = MASP.DepositMeta({ payer: PAYER, submittedAt: uint32(block.number), fbps: FEE_BPS });

        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = masp.committedCount();
        // Two leaves per deposit; slot 0 is the principal, slot 1 the relayer's
        // fee note. Only slot 0 is in spend mode, which the guard under test
        // rejects.
        tpi.actualCount = 2;
        tpi.isDeposit[0] = 0; // spend mode
        tpi.isDeposit[1] = 1;

        // Seeds a pending deposit so the slot passes the pending check first.
        _seedDeposit();

        vm.expectRevert(MASP.BadDepositMode.selector);
        masp.flushBatch(ids, meta, FixtureLoader.emptyProof(), tpi);
    }

    function _seedDeposit() internal {
        token.mint(address(this), 1_000 * SCALE);
        token.approve(address(permit2), type(uint256).max);
        PubInputs.DepositRequest memory d;
        d.chainId = block.chainid;
        d.publicAssetId = ASSET_ID;
        d.publicIn = 1;
        d.payer = address(this);
        d.recipient = RECIPIENT;
        d.outCm = bytes32(uint256(0x1));
        d.feeCm = bytes32(uint256(0xfee));
        // The AllowanceTransfer path needs no signature.
        _approvePermit2ToMasp();
        masp.depositAuthorized(d, SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
    }

    function _approvePermit2ToMasp() internal {
        (bool ok,) = address(permit2)
            .call(
                abi.encodeWithSignature(
                    "approve(address,address,uint160,uint48)",
                    address(token),
                    address(masp),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        require(ok, "permit2 approve");
    }

    // --- small-subgroup rejection ------------------------------------------

    /// `AuxValidation` rejects low-order points (order dividing 8) on the clue
    /// and ephemeral keys.
    /// `BabyJubJub.isLowOrder` is fuzzed directly elsewhere; this pins the
    /// revert wiring in the spend path.
    function test_revert_LowOrderPoint_clue() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        // Identity (0, 1) is on-curve and order 1.
        aux[0].clueRx = 0;
        aux[0].clueRy = 1;
        vm.prank(RELAYER);
        vm.expectRevert(AuxValidation.LowOrderPoint.selector);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, aux);
    }

    function test_revert_LowOrderPoint_ephemeral() public {
        PubInputs.Transact memory pi = _pi();
        PubInputs.SpendTree memory tpi = _spendTree(pi);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        aux[1].ephPubX = 0;
        aux[1].ephPubY = 1;
        aux[2].ephPubX = 0;
        aux[2].ephPubY = 1;
        aux[3].ephPubX = 0;
        aux[3].ephPubY = 1;
        vm.prank(RELAYER);
        vm.expectRevert(AuxValidation.LowOrderPoint.selector);
        masp.withdraw(FixtureLoader.emptyProof(), pi, FixtureLoader.emptyProof(), tpi, aux);
    }

    // --- off-chain dry-run helpers -----------------------------------------
}
