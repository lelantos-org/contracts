// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

// Force compilation of Permit2 into out/Permit2.sol/Permit2.json so
// DeployTest.s.sol can fetch its bytecode via `vm.getCode`. Permit2
// pins solc 0.8.17, MASP pins ^0.8.30 — keeping this in its own file
// lets foundry compile both with their respective compilers.
import { Permit2 } from "permit2/src/Permit2.sol";
