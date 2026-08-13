// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../src/BabyJubJub.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC1271 } from "./mocks/MockERC1271.sol";

/// `flushBatch` edge cases not covered by `MASP.flushBatch.t.sol`:
///   - duplicate deposit id in the same `ids` array
///   - `cancelDeposit` called after the deposit was already flushed
contract MASPFlushBatchDuplicateTest is Test {
    uint64 internal constant ASSET_ID = 1;
    uint256 internal constant SCALE = 1e10;
    uint16 internal constant FEE_BPS = 25;
    address internal constant TREASURY = address(0xfee);
    address internal constant OWNER = address(0x0117e7);

    IVerifier verifier;
    IVerifier tubVerifier;
    address permit2;
    MockERC20 token;
    MASP masp;

    address payer = address(0xface);
    address recipient = address(0xb0b);

    function setUp() public {
        token = new MockERC20("M", "M", 18);
        verifier = IVerifier(address(new MockERC20("v", "v", 18)));
        tubVerifier = IVerifier(address(new MockERC20("tub", "tub", 18)));
        permit2 = new DeployPermit2().deployPermit2();

        uint64[] memory ids = new uint64[](1);
        IERC20[] memory tokens = new IERC20[](1);
        uint256[] memory scales = new uint256[](1);
        ids[0] = ASSET_ID;
        tokens[0] = IERC20(address(token));
        scales[0] = SCALE;

        masp = new MASP(
            verifier, tubVerifier, ISignatureTransfer(address(permit2)), ids, tokens, scales, FEE_BPS, TREASURY, OWNER
        );

        MockERC1271 stub = new MockERC1271();
        vm.etch(payer, address(stub).code);

        vm.mockCall(address(tubVerifier), abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
    }

    // --- helpers -----------------------------------------------------------

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

    function _emptyProof() internal pure returns (MASP.Proof memory) {
        return MASP.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    /// Digest meta matching `_submit` (same payer, same block, deploy fee).
    function _meta(uint256 n) internal view returns (MASP.DepositMeta[] memory m) {
        m = new MASP.DepositMeta[](n);
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            m[i] = MASP.DepositMeta({ payer: payer, submittedAt: uint32(block.number), fbps: FEE_BPS });
        }
    }

    uint256 private _nextNonce;

    struct _Pre {
        uint48 publicIn;
        bytes32 cm;
        uint256[2] cvDep;
    }

    mapping(uint256 => _Pre) internal _pre;

    function _submit(uint64 publicIn, bytes32 cm) internal returns (uint256 id) {
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
        d.recipient = recipient;
        d.outCm = cm;

        MASP.Permit2Sig memory sig = MASP.Permit2Sig({
            nonce: _nextNonce++, deadline: type(uint256).max, maxTotal: type(uint256).max, signature: hex"00"
        });
        id = masp.deposit(d, sig, _aux()[0]);
        _pre[id] = _Pre({ publicIn: uint48(publicIn), cm: cm, cvDep: d.cvDep });
    }

    function _buildTpi(uint256[] memory depositIds) internal view returns (PubInputs.TreeUpdateBatch memory tpi) {
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xfeedbeef));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = uint64(depositIds.length);
        for (uint256 i = 0; i < depositIds.length; i++) {
            _Pre memory p = _pre[depositIds[i]];
            tpi.cms[i] = p.cm;
            tpi.cvDeps[i] = p.cvDep;
            tpi.leafAsset[i] = ASSET_ID;
            tpi.leafPublicIn[i] = p.publicIn;
            tpi.isDeposit[i] = 1;
        }
    }

    // --- tests: duplicate id in batch -------------------------------------

    /// `ids = [0, 0]`: after draining slot 0 on the first iteration,
    /// `escrowed[0] == bytes32(0)` → DepositNotPending(0) on second.
    function test_revert_duplicateIdInBatch() public {
        uint256 id = _submit(100, bytes32(uint256(0x111)));
        assertEq(id, 0);

        // Build a tpi as if draining id twice — but only the first slot is valid.
        // The revert fires before SNARK verification (storage check comes first).
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = masp.currentRoot();
        tpi.newRoot = bytes32(uint256(0xdead));
        tpi.startIndex = masp.committedCount();
        tpi.actualCount = 2; // two leaves, one per claimed slot
        // Slot 0: valid preimage for id 0.
        tpi.cms[0] = bytes32(uint256(0x111));
        tpi.leafAsset[0] = ASSET_ID;
        tpi.leafPublicIn[0] = 100;
        tpi.isDeposit[0] = 1;
        // Slot 1: same id, same preimage — will fail after id 0 is deleted.
        tpi.cms[1] = bytes32(uint256(0x111));
        tpi.leafAsset[1] = ASSET_ID;
        tpi.leafPublicIn[1] = 100;
        tpi.isDeposit[1] = 1;

        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 0; // duplicate

        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, uint256(0)));
        masp.flushBatch(ids, _meta(2), _emptyProof(), tpi);
    }

    // --- tests: cancel after flush ----------------------------------------

    function test_revert_cancelAfterFlush() public {
        uint256 id = _submit(100, bytes32(uint256(0xAAA)));

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        PubInputs.TreeUpdateBatch memory tpi = _buildTpi(ids);
        masp.flushBatch(ids, _meta(1), _emptyProof(), tpi);

        // Escrow slot deleted by flush; cancel must see DepositNotPending.
        vm.roll(block.number + masp.cancelDelay());
        _Pre memory p = _pre[id];
        uint256[2] memory zCv;
        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, id));
        masp.cancelDeposit(id, p.publicIn, p.cm, zCv, ASSET_ID, FEE_BPS, payer, 0);
    }

    function test_revert_cancelAfterFlush_multipleDeposits() public {
        uint256 id0 = _submit(50, bytes32(uint256(0x111)));
        uint256 id1 = _submit(50, bytes32(uint256(0x333)));

        uint256[] memory ids = new uint256[](2);
        ids[0] = id0;
        ids[1] = id1;
        PubInputs.TreeUpdateBatch memory tpi = _buildTpi(ids);
        masp.flushBatch(ids, _meta(2), _emptyProof(), tpi);

        vm.roll(block.number + masp.cancelDelay());

        // Both must revert.
        uint256[2] memory zCv;
        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, id0));
        masp.cancelDeposit(id0, _pre[id0].publicIn, _pre[id0].cm, zCv, ASSET_ID, FEE_BPS, payer, 0);

        vm.expectRevert(abi.encodeWithSelector(MASP.DepositNotPending.selector, id1));
        masp.cancelDeposit(id1, _pre[id1].publicIn, _pre[id1].cm, zCv, ASSET_ID, FEE_BPS, payer, 0);
    }
}
