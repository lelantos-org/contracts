// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Vm.sol";

import { MASP } from "../../src/MASP.sol";
import { IMASPPool } from "../../src/interfaces/IMASPPool.sol";
import { AuxValidation } from "../../src/libs/AuxValidation.sol";
import { SpendFixture } from "./SpendFixture.sol";

/// Proof-fixture reading and empty-argument helpers, kept off the test
/// inheritance chain so unit, reentrancy and integration tests share them.
library FixtureLoader {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// Reads the Groth16 proof at `base` in `json`, laid out as `a[2]`,
    /// `b[2][2]`, `c[2]`.
    function readProof(string memory json, string memory base) internal pure returns (MASP.Proof memory p) {
        p.a[0] = vm.parseJsonUint(json, string.concat(base, ".a[0]"));
        p.a[1] = vm.parseJsonUint(json, string.concat(base, ".a[1]"));
        p.b[0][0] = vm.parseJsonUint(json, string.concat(base, ".b[0][0]"));
        p.b[0][1] = vm.parseJsonUint(json, string.concat(base, ".b[0][1]"));
        p.b[1][0] = vm.parseJsonUint(json, string.concat(base, ".b[1][0]"));
        p.b[1][1] = vm.parseJsonUint(json, string.concat(base, ".b[1][1]"));
        p.c[0] = vm.parseJsonUint(json, string.concat(base, ".c[0]"));
        p.c[1] = vm.parseJsonUint(json, string.concat(base, ".c[1]"));
    }

    /// Aux with a 2-byte zero ciphertext prefix in every slot: the minimal input
    /// that passes `AuxValidation.validate`. Points are set to the Baby-Jubjub
    /// prime-order generator `BASE8` so the low-order and identity rejection in
    /// `AuxValidation` does not trigger.
    function emptyAux() internal pure returns (AuxValidation.Output[6] memory) {
        return SpendFixture.uniformAux(hex"0000");
    }

    function emptyProof() internal pure returns (MASP.Proof memory) {
        return MASP.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }

    /// `emptyProof` as the `IMASPPool` type the satellites (adapters,
    /// wrappers, Bundler) take.
    function emptyPoolProof() internal pure returns (IMASPPool.Proof memory) {
        return IMASPPool.Proof({ a: [uint256(0), 0], b: [[uint256(0), 0], [uint256(0), 0]], c: [uint256(0), 0] });
    }
}
