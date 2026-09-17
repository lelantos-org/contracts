// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { SpendFixture } from "../utils/SpendFixture.sol";
import { FixtureLoader } from "../utils/FixtureLoader.sol";
import { MockPoolTestBase } from "../utils/MockPoolTestBase.sol";
import { singleAsset } from "../utils/PoolDeployer.sol";
import { Stubs } from "../utils/Stubs.sol";
import { TestConstants } from "../utils/TestConstants.sol";
import { DepositFixture } from "../utils/DepositFixture.sol";
import { FeeMath } from "../utils/FeeMath.sol";

/// `flushBatch` edge cases not covered by `MASP.flushBatch.t.sol`:
///   - duplicate deposit id in the same `ids` array
///   - `cancelDeposit` called after the deposit was already flushed
contract MASPFlushBatchDuplicateTest is MockPoolTestBase {
    uint16 internal constant FEE_BPS = TestConstants.FEE_BPS;

    address payer = TestConstants.ESCROW_PAYER;
    address recipient = address(0xb0b);

    function setUp() public {
        token = new MockERC20("M", "M", 18);

        (uint64[] memory ids, IERC20[] memory tokens, uint256[] memory scales) =
            singleAsset(IERC20(address(token)), ASSET_ID, SCALE);

        _deployMockPool(ids, tokens, scales, FEE_BPS, TREASURY, OWNER);

        Stubs.installPermissiveERC1271(payer);
        Stubs.acceptTreeUpdateProofs(tub, true);
    }

    // --- helpers -----------------------------------------------------------

    /// Matches the zero `feeCvDep` the deposit builder leaves in place.
    /// Digest meta matching `_submit` (same payer, same block, deploy fee).
    function _meta(uint256 n) internal view returns (MASP.DepositMeta[] memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return DepositFixture.metas(n, payer, uint32(block.number), FEE_BPS);
    }

    uint256 private _nextNonce;

    struct _Pre {
        uint48 publicIn;
        bytes32 cm;
        uint256[2] cvDep;
    }

    mapping(uint256 => _Pre) internal _pre;

    function _submit(uint64 publicIn, bytes32 cm) internal returns (uint256 id) {
        token.mint(payer, FeeMath.gross(publicIn, SCALE, FEE_BPS));
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);

        PubInputs.DepositRequest memory d = DepositFixture.request(ASSET_ID, publicIn, payer, recipient, cm);
        id = masp.deposit(d, DepositFixture.sig(_nextNonce++), SpendFixture.validAux()[0], SpendFixture.validAux()[1]);
        _pre[id] = _Pre({ publicIn: uint48(publicIn), cm: cm, cvDep: d.cvDep });
    }

    function _buildTpi(uint256[] memory depositIds) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi = DepositFixture.batch(
            masp.currentRoot(), bytes32(uint256(0xfeedbeef)), masp.committedCount(), depositIds.length
        );
        for (uint256 i = 0; i < depositIds.length; i++) {
            _Pre memory p = _pre[depositIds[i]];
            DepositFixture.setDepositLeaves(tpi, i, p.cm, p.cvDep, ASSET_ID, p.publicIn);
        }
    }

    // --- tests: duplicate id in batch -------------------------------------

    /// `ids = [0, 0]`: the first iteration drains slot 0, so `escrowed[0]` is
    /// zero and the second iteration reverts with `DepositNotPending(0)`.
    function test_revert_duplicateIdInBatch() public {
        uint256 id = _submit(100, bytes32(uint256(0x111)));
        assertEq(id, 0);

        // A tpi that drains the same id twice; only the first drain can succeed.
        // The storage check runs before SNARK verification.
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = 4; // two deposits claimed, two leaves each
        // Deposit 0: valid preimage for id 0, principal then fee note.
        tpi.cms[0] = bytes32(uint256(0x111));
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafPublicIn[0] = 100;
        tpi.isDeposit[0] = 1;
        tpi.cms[1] = bytes32(uint256(0xfee));
        // Zero value, so asset 0: the circuit canonicalises the asset of a
        // leaf whose Pedersen binding cannot see it (step 6a), and
        // `_drainDeposit` requires the match.
        tpi.leafAsset[1] = 0;
        tpi.leafPublicIn[1] = 0;
        tpi.isDeposit[1] = 1;
        // Deposit 1: same id and preimage; fails once id 0 is deleted.
        tpi.cms[2] = bytes32(uint256(0x111));
        tpi.leafAsset[2] = ASSET_ID;
        tpi.leafPublicIn[2] = 100;
        tpi.isDeposit[2] = 1;
        tpi.cms[3] = bytes32(uint256(0xfee));
        tpi.leafAsset[3] = 0;
        tpi.leafPublicIn[3] = 0;
        tpi.isDeposit[3] = 1;

        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 0; // duplicate

        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, uint256(0)));
        masp.flushBatch(ids, _meta(2), FixtureLoader.emptyProof(), tpi);
    }

    // --- tests: cancel after flush ----------------------------------------

    function test_revert_cancelAfterFlush() public {
        uint256 id = _submit(100, bytes32(uint256(0xAAA)));

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        PubInputs.TreeUpdateBatch memory tpi = _buildTpi(ids);
        masp.flushBatch(ids, _meta(1), FixtureLoader.emptyProof(), tpi);

        // Flush deleted the escrow slot, so cancel reverts with DepositNotPending.
        vm.roll(block.number + masp.cancelDelay());
        _Pre memory p = _pre[id];
        uint256[2] memory zCv;
        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, id));
        masp.cancelDeposit(id, p.publicIn, p.cm, zCv, ASSET_ID, FEE_BPS, payer, 0, DepositFixture.feeNote());
    }

    function test_revert_cancelAfterFlush_multipleDeposits() public {
        uint256 id0 = _submit(50, bytes32(uint256(0x111)));
        uint256 id1 = _submit(50, bytes32(uint256(0x333)));

        uint256[] memory ids = new uint256[](2);
        ids[0] = id0;
        ids[1] = id1;
        PubInputs.TreeUpdateBatch memory tpi = _buildTpi(ids);
        masp.flushBatch(ids, _meta(2), FixtureLoader.emptyProof(), tpi);

        vm.roll(block.number + masp.cancelDelay());

        // Both revert.
        uint256[2] memory zCv;
        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, id0));
        masp.cancelDeposit(
            id0, _pre[id0].publicIn, _pre[id0].cm, zCv, ASSET_ID, FEE_BPS, payer, 0, DepositFixture.feeNote()
        );

        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, id1));
        masp.cancelDeposit(
            id1, _pre[id1].publicIn, _pre[id1].cm, zCv, ASSET_ID, FEE_BPS, payer, 0, DepositFixture.feeNote()
        );
    }
}
