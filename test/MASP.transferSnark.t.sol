// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { MASP } from "../src/MASP.sol";
import { IVerifier } from "../src/interfaces/IVerifier.sol";
import { Groth16Verifier } from "../src/verifiers/Verifier.sol";
import { TreeUpdateBatchGroth16Verifier } from "../src/verifiers/TreeUpdateBatchVerifier.sol";
import { PubInputs } from "../src/libs/PubInputs.sol";
import { AuxValidation } from "../src/libs/AuxValidation.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

import { MASPSpendHarness } from "./utils/MASPSpendHarness.sol";

/// End-to-end transfer test with REAL Groth16 proofs. Bootstraps the tree
/// to a known state via `MASPSpendHarness.seedRoot`, then invokes
/// `transfer` with the spend-side fixture (transact_2x2 +
/// tree_update_batch N=1 proofs).
contract MASPTransferSnarkTest is Test {
    string internal constant FIXTURE = "test/fixtures/proof_transfer.json";

    Groth16Verifier verifier;
    TreeUpdateBatchGroth16Verifier tubVerifier;
    address permit2;
    MockERC20 token;
    MASPSpendHarness masp;

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

        masp = new MASPSpendHarness(
            IVerifier(address(verifier)),
            IVerifier(address(tubVerifier)),
            ISignatureTransfer(address(permit2)),
            ids,
            tokens,
            scales,
            address(0xfee),
            address(this)
        );
    }

    function _readProof(string memory j, string memory base) internal pure returns (MASP.Proof memory p) {
        p.a[0] = vm.parseJsonUint(j, string.concat(base, ".a[0]"));
        p.a[1] = vm.parseJsonUint(j, string.concat(base, ".a[1]"));
        p.b[0][0] = vm.parseJsonUint(j, string.concat(base, ".b[0][0]"));
        p.b[0][1] = vm.parseJsonUint(j, string.concat(base, ".b[0][1]"));
        p.b[1][0] = vm.parseJsonUint(j, string.concat(base, ".b[1][0]"));
        p.b[1][1] = vm.parseJsonUint(j, string.concat(base, ".b[1][1]"));
        p.c[0] = vm.parseJsonUint(j, string.concat(base, ".c[0]"));
        p.c[1] = vm.parseJsonUint(j, string.concat(base, ".c[1]"));
    }

    function test_transferRealSnark_succeeds() public {
        string memory j = vm.readFile(FIXTURE);
        vm.chainId(uint256(vm.parseJsonUint(j, ".chainId")));

        // Seed the tree to the post-bootstrap state. After this:
        // currentRoot() == fixture.bootstrap.newRoot (= fixture.transfer.merkleRoot)
        // committedCount == 2
        bytes32 seedRoot = bytes32(vm.parseJsonUint(j, ".bootstrap.newRoot"));
        masp.seedRoot(seedRoot, 2);
        assertEq(masp.currentRoot(), seedRoot, "seed root mismatch");
        assertEq(masp.committedCount(), 2, "committedCount=2");

        // Build the transact_2x2 PI tuple from publicSignals.
        uint256[] memory ps = vm.parseJsonUintArray(j, ".transfer.txPublicSignals");
        require(ps.length == 30, "expected 30 transact pi");

        PubInputs.Transact memory pi;
        pi.merkleRoot = bytes32(ps[0]);
        pi.nullifier[0] = bytes32(ps[1]);
        pi.nullifier[1] = bytes32(ps[2]);
        pi.outCm[0] = bytes32(ps[3]);
        pi.outCm[1] = bytes32(ps[4]);
        pi.publicAssetId = uint64(ps[5]);
        pi.publicIn = uint64(ps[6]);
        pi.publicOut = uint64(ps[7]);
        pi.inCv[0][0] = ps[8];
        pi.inCv[0][1] = ps[9];
        pi.inCv[1][0] = ps[10];
        pi.inCv[1][1] = ps[11];
        pi.outCv[0][0] = ps[12];
        pi.outCv[0][1] = ps[13];
        pi.outCv[1][0] = ps[14];
        pi.outCv[1][1] = ps[15];
        pi.recipient = address(uint160(ps[16]));
        pi.chainId = ps[17];
        pi.payer = address(uint160(ps[18]));
        pi.relayer = address(uint160(ps[19]));
        pi.outCvDep[0][0] = ps[20];
        pi.outCvDep[0][1] = ps[21];
        pi.outCvDep[1][0] = ps[22];
        pi.outCvDep[1][1] = ps[23];

        // tree_update_batch PI for the transfer leg.
        PubInputs.TreeUpdateBatch memory tpi;
        tpi.oldRoot = bytes32(vm.parseJsonUint(j, ".transfer.oldRoot"));
        tpi.newRoot = bytes32(vm.parseJsonUint(j, ".transfer.newRoot"));
        tpi.startIndex = uint64(vm.parseJsonUint(j, ".transfer.startIndex"));
        tpi.actualCount = uint64(vm.parseJsonUint(j, ".transfer.actualCount"));
        for (uint256 i = 0; i < 2 * PubInputs.MAX_N_BATCH; i++) {
            string memory key = string.concat(".transfer.cms[", vm.toString(i), "]");
            tpi.cms[i] = bytes32(vm.parseJsonUint(j, key));
        }
        for (uint256 i = 0; i < 2 * PubInputs.MAX_N_BATCH; i++) {
            string memory base = string.concat(".transfer.cvDeps[", vm.toString(i), "]");
            tpi.cvDeps[i][0] = vm.parseJsonUint(j, string.concat(base, "[0]"));
            tpi.cvDeps[i][1] = vm.parseJsonUint(j, string.concat(base, "[1]"));
        }
        for (uint256 i = 0; i < PubInputs.MAX_N_BATCH; i++) {
            tpi.pairAsset[i] = uint64(vm.parseJsonUint(j, string.concat(".transfer.pairAsset[", vm.toString(i), "]")));
            tpi.pairPublicIn[i] =
                uint64(vm.parseJsonUint(j, string.concat(".transfer.pairPublicIn[", vm.toString(i), "]")));
            tpi.isDeposit[i] = uint8(vm.parseJsonUint(j, string.concat(".transfer.isDeposit[", vm.toString(i), "]")));
        }

        AuxValidation.Output[2] memory aux;
        aux[0].clueRx = vm.parseJsonUint(j, ".transfer.aux[0].clueRx");
        aux[0].clueRy = vm.parseJsonUint(j, ".transfer.aux[0].clueRy");
        aux[0].ephPubX = vm.parseJsonUint(j, ".transfer.aux[0].ephPubX");
        aux[0].ephPubY = vm.parseJsonUint(j, ".transfer.aux[0].ephPubY");
        aux[0].ciphertext = vm.parseJsonBytes(j, ".transfer.aux[0].ciphertext");
        aux[1].clueRx = vm.parseJsonUint(j, ".transfer.aux[1].clueRx");
        aux[1].clueRy = vm.parseJsonUint(j, ".transfer.aux[1].clueRy");
        aux[1].ephPubX = vm.parseJsonUint(j, ".transfer.aux[1].ephPubX");
        aux[1].ephPubY = vm.parseJsonUint(j, ".transfer.aux[1].ephPubY");
        aux[1].ciphertext = vm.parseJsonBytes(j, ".transfer.aux[1].ciphertext");

        MASP.Proof memory txProof = _readProof(j, ".transfer.txProof");
        MASP.Proof memory tubProof = _readProof(j, ".transfer.tubProof");

        // Submit transfer. Both proofs verified against real verifiers.
        vm.prank(pi.relayer);
        masp.transfer(txProof, pi, tubProof, tpi, aux);

        // Post-state assertions.
        assertEq(masp.currentRoot(), tpi.newRoot, "root advanced to fixture transfer.newRoot");
        assertEq(masp.committedCount(), 4, "count = 2 (bootstrap) + 2 (transfer)");
        assertTrue(masp.spent(pi.nullifier[0]), "nf0 consumed");
        assertTrue(masp.spent(pi.nullifier[1]), "nf1 consumed");
    }
}
