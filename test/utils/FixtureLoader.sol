// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Vm } from "forge-std/Vm.sol";

import { MASP } from "../../src/MASP.sol";
import { PubInputs } from "../../src/libs/PubInputs.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { BabyJubJub } from "../../src/BabyJubJub.sol";

/// JSON fixture loading helpers, kept off the test inheritance chain so unit
/// + reentrancy + integration tests can share parsing without duplicating it.
library FixtureLoader {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function loadProofSpend(string memory path)
        internal
        view
        returns (
            MASP.Proof memory p,
            PubInputs.Transact memory pi,
            MASP.Proof memory tp,
            PubInputs.TreeUpdateBatch memory tpi,
            AuxValidation.Output[3] memory aux
        )
    {
        string memory json = vm.readFile(path);

        p.a[0] = vm.parseJsonUint(json, ".proof.a[0]");
        p.a[1] = vm.parseJsonUint(json, ".proof.a[1]");
        p.b[0][0] = vm.parseJsonUint(json, ".proof.b[0][0]");
        p.b[0][1] = vm.parseJsonUint(json, ".proof.b[0][1]");
        p.b[1][0] = vm.parseJsonUint(json, ".proof.b[1][0]");
        p.b[1][1] = vm.parseJsonUint(json, ".proof.b[1][1]");
        p.c[0] = vm.parseJsonUint(json, ".proof.c[0]");
        p.c[1] = vm.parseJsonUint(json, ".proof.c[1]");

        uint256[] memory ps = vm.parseJsonUintArray(json, ".publicSignals");
        require(ps.length == 26, "expected 26 signals");

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

        tp.a[0] = vm.parseJsonUint(json, ".treeUpdateProof.a[0]");
        tp.a[1] = vm.parseJsonUint(json, ".treeUpdateProof.a[1]");
        tp.b[0][0] = vm.parseJsonUint(json, ".treeUpdateProof.b[0][0]");
        tp.b[0][1] = vm.parseJsonUint(json, ".treeUpdateProof.b[0][1]");
        tp.b[1][0] = vm.parseJsonUint(json, ".treeUpdateProof.b[1][0]");
        tp.b[1][1] = vm.parseJsonUint(json, ".treeUpdateProof.b[1][1]");
        tp.c[0] = vm.parseJsonUint(json, ".treeUpdateProof.c[0]");
        tp.c[1] = vm.parseJsonUint(json, ".treeUpdateProof.c[1]");

        tpi.oldRoot = bytes32(vm.parseJsonUint(json, ".oldRoot"));
        tpi.newRoot = bytes32(vm.parseJsonUint(json, ".newRoot"));
        tpi.startIndex = uint64(vm.parseJsonUint(json, ".startIndex"));
        tpi.actualCount = uint64(vm.parseJsonUint(json, ".actualCount"));
        for (uint256 i = 0; i < 32; i++) {
            string memory key = string.concat(".cms[", vm.toString(i), "]");
            tpi.cms[i] = bytes32(vm.parseJsonUint(json, key));
        }

        // Aux blobs (clue PIs sit in publicSignals[20..25]; the contract
        // re-derives them from aux during compress(), so the JSON aux MUST
        // pack the same Rx/Ry/clueBits to keep PIs consistent).
        aux[0].clueRx = vm.parseJsonUint(json, ".aux[0].clueRx");
        aux[0].clueRy = vm.parseJsonUint(json, ".aux[0].clueRy");
        aux[0].ephPubX = vm.parseJsonUint(json, ".aux[0].ephPubX");
        aux[0].ephPubY = vm.parseJsonUint(json, ".aux[0].ephPubY");
        aux[0].ciphertext = vm.parseJsonBytes(json, ".aux[0].ciphertext");
        aux[1].clueRx = vm.parseJsonUint(json, ".aux[1].clueRx");
        aux[1].clueRy = vm.parseJsonUint(json, ".aux[1].clueRy");
        aux[1].ephPubX = vm.parseJsonUint(json, ".aux[1].ephPubX");
        aux[1].ephPubY = vm.parseJsonUint(json, ".aux[1].ephPubY");
        aux[1].ciphertext = vm.parseJsonBytes(json, ".aux[1].ciphertext");
        aux[2].clueRx = vm.parseJsonUint(json, ".aux[2].clueRx");
        aux[2].clueRy = vm.parseJsonUint(json, ".aux[2].clueRy");
        aux[2].ephPubX = vm.parseJsonUint(json, ".aux[2].ephPubX");
        aux[2].ephPubY = vm.parseJsonUint(json, ".aux[2].ephPubY");
        aux[2].ciphertext = vm.parseJsonBytes(json, ".aux[2].ciphertext");
    }

    /// Aux with empty (2-byte zero) ciphertext prefix in both slots — minimal
    /// valid input that always passes `AuxValidation.validate`. Points are set
    /// to the Baby-Jubjub prime-order generator `BASE8` so the low-order /
    /// identity rejection in `AuxValidation` does not trip.
    function emptyAux() internal pure returns (AuxValidation.Output[3] memory aux) {
        aux[0].clueRx = BabyJubJub.BASE8_X;
        aux[0].clueRy = BabyJubJub.BASE8_Y;
        aux[0].ephPubX = BabyJubJub.BASE8_X;
        aux[0].ephPubY = BabyJubJub.BASE8_Y;
        aux[0].ciphertext = hex"0000";
        aux[1].clueRx = BabyJubJub.BASE8_X;
        aux[1].clueRy = BabyJubJub.BASE8_Y;
        aux[1].ephPubX = BabyJubJub.BASE8_X;
        aux[1].ephPubY = BabyJubJub.BASE8_Y;
        aux[1].ciphertext = hex"0000";
        aux[2].clueRx = BabyJubJub.BASE8_X;
        aux[2].clueRy = BabyJubJub.BASE8_Y;
        aux[2].ephPubX = BabyJubJub.BASE8_X;
        aux[2].ephPubY = BabyJubJub.BASE8_Y;
        aux[2].ciphertext = hex"0000";
    }

    function emptyProof() internal pure returns (MASP.Proof memory) {
        return MASP.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }
}
