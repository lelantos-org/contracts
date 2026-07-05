// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import { IWrappedNative } from "../../src/interfaces/IWrappedNative.sol";

/// Test-only WETH9 reimplementation with EIP-2612 permit baked in.
///
/// Mirrors the canonical mainnet WETH9 invariants — `deposit()` mints 1:1
/// from `msg.value`, `withdraw()` burns and returns ETH via raw `call` —
/// while also satisfying `IERC20Permit` so the SDK's deposit flow (which
/// always signs an EIP-2612 permit before posting to the relayer) works
/// against this mock without an approve detour.
///
/// Real mainnet WETH9 does NOT support EIP-2612; production deployments
/// must either (a) use a permit-capable wrapped-ETH variant such as
/// `WETH9Permit`, (b) route deposits via an `approve + transact` flow, or
/// (c) sign through Uniswap Permit2. None of those are wired today; this
/// mock unblocks local-demo deposits only.
contract MockWETH9 is ERC20, ERC20Permit, IWrappedNative {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    constructor() ERC20("Wrapped Ether", "WETH") ERC20Permit("Wrapped Ether") { }

    /// Plain ETH push (`receive`) is treated as an implicit `deposit()` so
    /// transfers from the SDK's wrap-card path land in the same balance.
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

    /// Test-only public mint. Real WETH mints only via `deposit()` /
    /// `receive()` against `msg.value`. The MockSwapRouter02 needs to
    /// synthesize WETH on demand without holding inventory; this hook
    /// matches the `IMintable` shape MockERC20 already exposes so the
    /// router can mint either token type uniformly.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
