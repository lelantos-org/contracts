// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";

/// Governance token. Fixed supply, minted once in the constructor.
///
/// The contract exposes no privileged functions: no owner, minter, pauser or
/// upgrade path. Supply is therefore monotonically non-increasing, and
/// `INITIAL_SUPPLY - totalSupply()` measures everything `FeeBurner` has burned.
contract LelantosToken is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes {
    /// The full supply, minted to the constructor's `recipient`. Retained so the
    /// cumulative burn is derivable on-chain.
    uint256 public immutable INITIAL_SUPPLY;

    error ZeroRecipient();
    error ZeroSupply();

    constructor(string memory name_, string memory symbol_, uint256 supply_, address recipient_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (recipient_ == address(0)) revert ZeroRecipient();
        if (supply_ == 0) revert ZeroSupply();
        INITIAL_SUPPLY = supply_;
        // The only mint. `ERC20Votes._update` bounds it against `_maxSupply()`
        // (2^208 - 1), so an oversized supply reverts here rather than corrupting
        // checkpoint arithmetic.
        _mint(recipient_, supply_);
    }

    /// Tokens burned since deployment.
    function totalBurned() external view returns (uint256) {
        return INITIAL_SUPPLY - totalSupply();
    }

    // ============== ERC-6372 clock ===========================================

    /// Timestamp-based checkpoints rather than block numbers, so a voting period
    /// has the same wall-clock duration on every chain the protocol deploys to.
    ///
    /// `LelantosGovernor` does not restate its clock: `GovernorVotes` reads these
    /// through a `try/catch`, keeping the two in step.
    function clock() public view override returns (uint48) {
        return Time.timestamp();
    }

    /// Must be overridden alongside `clock()`: `Votes.CLOCK_MODE()` reverts
    /// `ERC6372InconsistentClock` otherwise.
    // Name and casing are fixed by ERC-6372.
    // solhint-disable-next-line func-name-mixedcase
    // forge-lint: disable-next-line(mixed-case-function)
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // ============== Required overrides =======================================

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    /// `ERC20Permit` and `ERC20Votes` both inherit `Nonces`; one counter serves
    /// `permit` and `delegateBySig`.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
