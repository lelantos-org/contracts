// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// Minimal ERC-4626 vault with test controls the real thing does not offer.
///
/// Hand-written rather than derived from OpenZeppelin's `ERC4626` because the
/// scenarios that matter here are the ones a correct vault will not perform on
/// request: earning, losing money, and running out of withdrawable liquidity
/// while still reporting a position. `earn` / `lose` / `setLiquidityCap` are
/// those levers.
///
/// Share maths mirrors the standard: shares are minted pro rata against
/// `totalAssetsHeld`, and a withdrawal burns `ceil` shares so rounding favours
/// the vault exactly as it does in production.
contract MockERC4626 {
    IERC20 public immutable UNDERLYING;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    /// Underlying the vault claims to hold. Moves with `earn` and `lose`
    /// independently of the token balance, which is what makes a share price
    /// other than 1:1 possible.
    uint256 public totalAssetsHeld;
    /// Ceiling on `maxWithdraw`, on top of the vault's actual liquidity. Set it
    /// to zero to model a vault whose underlying markets are fully drawn.
    uint256 public liquidityCap = type(uint256).max;

    constructor(IERC20 underlying_) {
        UNDERLYING = underlying_;
    }

    function asset() external view returns (address) {
        return address(UNDERLYING);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        UNDERLYING.transferFrom(msg.sender, address(this), assets);
        shares = totalSupply == 0 ? assets : Math.mulDiv(assets, totalSupply, totalAssetsHeld);
        totalSupply += shares;
        totalAssetsHeld += assets;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(assets <= maxWithdraw(owner), "MockERC4626: exceeds maxWithdraw");
        shares = Math.mulDiv(assets, totalSupply, totalAssetsHeld, Math.Rounding.Ceil);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        totalAssetsHeld -= assets;
        UNDERLYING.transfer(receiver, assets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalSupply == 0) return shares;
        return Math.mulDiv(shares, totalAssetsHeld, totalSupply);
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        uint256 owned = convertToAssets(balanceOf[owner]);
        uint256 liquid = UNDERLYING.balanceOf(address(this));
        uint256 v = owned < liquid ? owned : liquid;
        return v < liquidityCap ? v : liquidityCap;
    }

    // --- test controls ------------------------------------------------------

    /// Credit interest. The caller funds it, so the vault's token balance and
    /// its accounting stay consistent.
    function earn(uint256 amt) external {
        UNDERLYING.transferFrom(msg.sender, address(this), amt);
        totalAssetsHeld += amt;
    }

    /// Burn value out of the position, share price falling with it.
    function lose(uint256 amt) external {
        totalAssetsHeld -= amt;
        UNDERLYING.transfer(address(0xdead), amt);
    }

    /// Model a vault that still reports a position it cannot currently pay out.
    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }
}
