// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Minimal wrapped-native interface (WETH9 ABI). `deposit` wraps msg.value;
/// `withdraw` unwraps.
interface IWrappedNative is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
