// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { MASP } from "../../src/MASP.sol";

/// A next-version implementation that adds behaviour and no storage. Upgrades
/// may only append storage, never insert or reorder.
contract MASPNext is MASP {
    function poolVersion() external pure returns (uint256) {
        return 3;
    }
}

/// Inserts a variable ahead of the inherited layout, shifting every slot below
/// it. Used by the layout test to demonstrate the failure it guards against.
contract MASPCorrupting {
    uint256 public insertedFirst;
}
