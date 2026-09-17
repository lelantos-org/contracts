// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../../src/MASP.sol";
import { IVerifier } from "../../src/interfaces/IVerifier.sol";
import { IBatchVerifier } from "../../src/interfaces/IBatchVerifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../../src/verifiers/TreeUpdateBatchVerifier.sol";
import { BatchedGroth16Verifier } from "../../src/verifiers/BatchedGroth16Verifier.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { FixtureLoader } from "./FixtureLoader.sol";
import { SpendFixture } from "./SpendFixture.sol";
import { DepositFixture } from "./DepositFixture.sol";
import { FeeMath } from "./FeeMath.sol";
import { deployPoolUniform, singleAsset } from "./PoolDeployer.sol";
import { Stubs } from "./Stubs.sol";
import { TestConstants } from "./TestConstants.sol";

/// A real pool and the escrow flow that populates its state: `deposit` followed
/// by `flushBatch`, which advances the tree and runs `FeeConfig._accrueFee`.
///
/// Suites requiring real pool state (accrued fees, a non-empty tree, a pending
/// escrow) extend this rather than reimplementing the flow. The tree-update
/// SNARK is mocked; proof validity is covered by the fixture-driven tests.
///
/// Warps and rolls use absolute values: under `via_ir` the optimizer may cache
/// `block.timestamp` and `block.number` within a call, which `vm.warp` and
/// `vm.roll` invalidate.
abstract contract EscrowFlowBase is Test {
    uint64 internal constant ASSET_ID = TestConstants.ASSET_ID;
    uint256 internal constant SCALE = TestConstants.SCALE;
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;
    uint256 internal constant T0 = 1_000_000;

    /// The relayer fee note every deposit here carries. It has zero value, but
    /// its leaf is still inserted, so a deposit always occupies two leaves.
    bytes32 internal constant FEE_CM = DepositFixture.FEE_CM;

    TreeUpdateBatchGroth16Verifier internal tubVerifier;
    BatchedGroth16Verifier internal batchVerifier;
    address internal permit2;
    MockERC20 internal token;
    MASP internal masp;

    address internal poolOwner = makeAddr("poolOwner");
    /// Assignable before `setUp`; `FeeBurnerTestBase` points it at the burner.
    address internal treasury = makeAddr("treasury");
    /// Fixture payer, carrying a permissive ERC-1271 stub so Permit2 accepts any
    /// signature bytes. This makes it a contract payer, so only it may cancel its
    /// own escrows.
    address internal payer = TestConstants.ESCROW_PAYER;
    address internal recipient = address(0xb0b);

    function setUp() public virtual {
        vm.warp(T0);
        tubVerifier = new TreeUpdateBatchGroth16Verifier();
        batchVerifier = new BatchedGroth16Verifier();
        permit2 = new DeployPermit2().deployPermit2();
        token = new MockERC20("Fee Token", "FEE", 18);

        masp = _deployTestPool();

        Stubs.installPermissiveERC1271(payer);
    }

    /// Deploys the pool. Defaults to the shared proxy wiring; suites that
    /// exercise the upgrade surface override it to control their own proxy.
    function _deployTestPool() internal virtual returns (MASP) {
        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) = _genesisAsset();
        return deployPoolUniform(
            IVerifier(address(tubVerifier)),
            IBatchVerifier(address(batchVerifier)),
            ISignatureTransfer(permit2),
            ids,
            tokens,
            scales,
            FEE_BPS,
            treasury,
            poolOwner
        );
    }

    /// The single-asset genesis set registered by these suites.
    function _genesisAsset()
        internal
        view
        returns (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales)
    {
        return singleAsset(IERC20(address(token)), ASSET_ID, SCALE);
    }

    // ============== Escrow flow ==============================================

    /// Mints principal plus fee to the payer and arms Permit2. Separate from
    /// `_depositCall` so a test can place `vm.expectRevert` immediately before
    /// the pool call, which a mint or prank in between would consume.
    function _fundPayer(uint64 publicIn) internal {
        token.mint(payer, FeeMath.gross(publicIn, SCALE, FEE_BPS));
        vm.prank(payer);
        token.approve(permit2, type(uint256).max);
    }

    function _depositCall(uint64 publicIn, bytes32 cm, uint256 nonce) internal returns (uint256 id) {
        PubInputs.DepositRequest memory d = DepositFixture.request(ASSET_ID, publicIn, payer, recipient, cm);
        AuxValidation.Output[6] memory aux = SpendFixture.validAux();
        return masp.deposit(d, DepositFixture.sig(nonce), aux[0], aux[1]);
    }

    /// Funds the payer and escrows a deposit in one step.
    function _deposit(uint64 publicIn, bytes32 cm, uint256 nonce) internal returns (uint256 id) {
        _fundPayer(publicIn);
        return _depositCall(publicIn, cm, nonce);
    }

    /// Flushes one escrowed deposit, advancing the tree and accruing the
    /// treasury's fee. A deposit occupies two adjacent leaves (principal and the
    /// note paying the flusher), so the tree advances by two.
    function _flush(uint256 id, uint64 publicIn, bytes32 cm) internal {
        // The new root must stay inside the BN254 scalar field:
        // `PubInputs.compress` rejects an out-of-field coefficient.
        PubInputs.TreeUpdateBatch memory tpi =
            DepositFixture.batch(masp.currentRoot(), bytes32(uint256(0xfeedbeef)), masp.committedCount(), 1);
        DepositFixture.setDepositLeaves(tpi, 0, cm, ASSET_ID, publicIn);
        MASP.DepositMeta[] memory meta = DepositFixture.metas(1, payer, uint32(block.number), FEE_BPS);

        Stubs.acceptTreeUpdateProofs(IVerifier(address(tubVerifier)), true);
        masp.flushBatch(DepositFixture.ids(id), meta, FixtureLoader.emptyProof(), tpi);
        vm.clearMockedCalls();
    }

    /// Deposits then flushes. Returns the treasury fee accrued by the flush.
    function _depositAndFlush(uint64 publicIn, bytes32 cm) internal returns (uint256 fee) {
        fee = FeeMath.fee(uint256(publicIn) * SCALE, FEE_BPS);
        _flush(_deposit(publicIn, cm, 0), publicIn, cm);
    }
}
