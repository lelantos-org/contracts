// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Minimal venue and vault stand-ins for the binding checks in
/// `YieldOps.initAsset`.
///
/// `initAsset` reaches the venue through three view calls (`POOL()`, `VAULT()`
/// and the vault's `asset()`) and binds the asset based on their results. A real
/// `ERC4626Venue` and vault would add share accounting and `Math.mulDiv` to every
/// path, which the solvers do not finish and the binding properties do not need.
///
/// Both values are set at construction so a proof can quantify over what a venue
/// claims, including the two rejected cases: a venue pinned to another pool, and
/// a vault holding the wrong token.
contract MockYieldVenue {
    address public POOL;
    address public VAULT;

    constructor(address pool_, address vault_) {
        POOL = pool_;
        VAULT = vault_;
    }
}

/// Answers the single ERC-4626 accessor the venue binding probes.
contract MockVaultAsset {
    address internal _asset;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }
}
