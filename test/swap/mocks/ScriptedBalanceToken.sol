// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// A token whose `balanceOf` is a script rather than a ledger: each read returns
/// the next value of `script`, then the last value forever. Transfers and
/// approvals move nothing and report success.
///
/// It models the `tokenIn` of the audit's sweep, where every amount `swap`
/// measures in `tokenIn` is whatever the caller scripted: `[0, 1, 1, 0, 0]`
/// passes the withdraw floor, both refund pull bounds and the leftover check
/// while the pool pulls a real token.
///
/// The cursor is storage, so a `STATICCALL` read, which is how `IERC20.balanceOf`
/// is called, reverts instead of advancing; a contract in the wild keys the same
/// sequence off state the swap changes (the wrapper's balances of the withdrawn
/// and the swept token). The regression tests need neither: `_validate` rejects
/// the token before its first read.
contract ScriptedBalanceToken {
    uint256[] internal script;
    /// How many reads the script has served.
    uint256 public reads;

    constructor(uint256[] memory script_) {
        script = script_;
    }

    function balanceOf(address) external returns (uint256 value) {
        uint256 last = script.length - 1;
        value = script[reads < last ? reads : last];
        ++reads;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}
