// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// Minimal ERC-4626 vault with test controls a production vault does not expose.
///
/// Hand-written rather than derived from OpenZeppelin's `ERC4626` so tests can
/// force earning, losses, and exhausted withdrawable liquidity while a position
/// is still reported, via `earn`, `lose` and `setLiquidityCap`.
///
/// Share maths follows the standard: shares are minted pro rata against
/// `totalAssetsHeld`, and a withdrawal burns `ceil` shares so rounding favours
/// the vault.
contract MockERC4626 {
    IERC20 public immutable UNDERLYING;
    /// The vault label the indexer publishes as `vaultName`, so a local stack
    /// exercises the same path a real ERC-4626 vault does.
    string public constant name = "Mock Vault";

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    /// Underlying the vault claims to hold. Moves with `earn` and `lose`
    /// independently of the token balance, allowing a share price other than 1:1.
    uint256 public totalAssetsHeld;
    /// Ceiling on `maxWithdraw`, on top of the vault's actual liquidity. Set it
    /// to zero to model a vault whose underlying markets are fully drawn.
    uint256 public liquidityCap = type(uint256).max;
    /// Ceiling on `maxDeposit`, and enforced by `deposit`. Set it to zero to
    /// model a paused vault, or to a remaining capacity for a capped one.
    uint256 public depositCap = type(uint256).max;
    /// When set, `withdraw` burns shares for `assets` but sends only
    /// `assets - withdrawHaircut`, modelling a vault with an exit fee or one
    /// that rounds against the withdrawer.
    uint256 public withdrawHaircut;

    constructor(IERC20 underlying_) {
        UNDERLYING = underlying_;
    }

    function asset() external view returns (address) {
        return address(UNDERLYING);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets <= depositCap, "MockERC4626: exceeds maxDeposit");
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
        // The haircut leaves the vault rather than accruing to other holders.
        if (withdrawHaircut != 0) UNDERLYING.transfer(address(0xdead), withdrawHaircut);
        UNDERLYING.transfer(receiver, assets - withdrawHaircut);
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

    function maxDeposit(address) external view returns (uint256) {
        return depositCap;
    }

    // --- test controls ------------------------------------------------------

    /// Credits interest funded by the caller, keeping the token balance and
    /// accounting consistent.
    function earn(uint256 amt) external {
        UNDERLYING.transferFrom(msg.sender, address(this), amt);
        totalAssetsHeld += amt;
    }

    /// Removes value from the vault, lowering the share price.
    function lose(uint256 amt) external {
        totalAssetsHeld -= amt;
        UNDERLYING.transfer(address(0xdead), amt);
    }

    /// Models a vault that reports a position it cannot currently pay out.
    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }

    /// Models a capped (non-zero) or paused (zero) vault.
    function setDepositCap(uint256 cap) external {
        depositCap = cap;
    }

    /// Models a vault that delivers `haircut` less than each withdrawal asks.
    function setWithdrawHaircut(uint256 haircut) external {
        withdrawHaircut = haircut;
    }
}
