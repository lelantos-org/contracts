// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

// Forces compilation of Permit2 into out/Permit2.sol/Permit2.json so
// DeployTest.s.sol can fetch its bytecode via `vm.getCode`. Permit2 pins
// solc 0.8.17 and MASP pins 0.8.36; a separate file lets Foundry compile
// each with its own compiler.
import { Permit2 } from "permit2/src/Permit2.sol";
