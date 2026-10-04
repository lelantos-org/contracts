// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Vm.sol";

import { MASP } from "../../src/MASP.sol";

/// Reads a deposit's refund cap out of its `DepositEscrowed` log.
///
/// The pool stores nothing for the cap: `pulled` is bound by the escrow digest
/// and published once, in the event, so a flusher or canceller takes it from
/// there and hands it back as `DepositMeta.pulled` or as `cancelDeposit`'s last
/// argument.
///
/// Calls no cheatcode itself: the caller wraps the deposit in
/// `vm.recordLogs()` / `vm.getRecordedLogs()`.
library EscrowLogs {
    /// Head word of `pulled` in the event data: the last of the 18 non-indexed
    /// parameters, each of which takes one.
    uint256 private constant PULLED_WORD = 17;

    /// `pulled` of the `DepositEscrowed` log `pool` emitted for `id`.
    function pulled(Vm.Log[] memory logs, address pool, uint256 id) internal pure returns (uint256 value) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != pool || log.topics[0] != MASP.DepositEscrowed.selector) continue;
            if (uint256(log.topics[1]) != id) continue;

            bytes memory data = log.data;
            // Past the length word.
            uint256 offset = (PULLED_WORD + 1) * 0x20;
            assembly ("memory-safe") {
                value := mload(add(data, offset))
            }
            return value;
        }
        revert("EscrowLogs: no DepositEscrowed for id");
    }
}
