// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { NullifierSet } from "../../src/NullifierSet.sol";

/// Minimal concrete `NullifierSet`.
///
/// The fuzz and unit suites reach the bitmap through `MASPHarness`, which drags
/// in permit2, verifiers and the whole pool. Symbolic execution explores every
/// path of everything it touches, so the bitmap is isolated here: this harness
/// adds one external entrypoint and no storage of its own.
///
/// Shared by `test/symbolic/NullifierSet.symbolic.t.sol` and
/// `test/quint/NullifierSetReplay.t.sol` so both reason about the same surface.
contract NullifierSetHarness is NullifierSet {
    function consume(bytes32 nf) external {
        _consumeNullifier(nf);
    }
}
