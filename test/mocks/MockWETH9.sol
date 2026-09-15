// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";

/// Test-only WETH9 reimplementation with an EIP-2612 permit extension.
///
/// Matches canonical WETH9 behaviour: `deposit()` mints 1:1 from `msg.value`,
/// and `withdraw()` burns and returns native coin via a raw `call`. It also
/// implements `IERC20Permit`.
///
/// Canonical mainnet WETH9 does not support EIP-2612, so production flows must
/// not depend on the permit extension; the pool pulls deposits through Permit2.
contract MockWETH9 is ERC20, ERC20Permit, IWrappedNative {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    constructor() ERC20("Wrapped Ether", "WETH") ERC20Permit("Wrapped Ether") { }

    /// A plain native transfer is treated as `deposit()`, as in canonical WETH9.
    receive() external payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function deposit() external payable override {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external override {
        _burn(msg.sender, wad);
        (bool ok,) = msg.sender.call{ value: wad }("");
        require(ok, "weth: send");
        emit Withdrawal(msg.sender, wad);
    }

    /// Test-only unbacked mint; canonical WETH mints only against `msg.value`.
    /// Matches the `IMintable` shape of `MockERC20` so the mock routers can
    /// mint output of either token type without holding inventory.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
