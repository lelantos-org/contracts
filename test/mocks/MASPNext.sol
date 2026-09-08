// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";

/// A next-version implementation. Adds behaviour and no storage, the shape an
/// upgrade must take: append only, never insert or reorder.
contract MASPNext is MASP {
    function poolVersion() external pure returns (uint256) {
        return 3;
    }
}

/// Inserts a variable ahead of the inherited layout, shifting every slot below
/// it. Present so the layout test can demonstrate the failure it guards.
contract MASPCorrupting {
    uint256 public insertedFirst;
}
