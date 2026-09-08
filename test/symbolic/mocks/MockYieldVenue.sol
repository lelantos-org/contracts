// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Minimal venue and vault stand-ins for the binding checks in
/// `YieldOps.initAsset`.
///
/// `initAsset` reaches the venue through exactly three view calls — `POOL()`,
/// `VAULT()` and the vault's `asset()` — and binds the asset on what they
/// answer. That is the whole of what the binding proofs need. A real
/// `ERC4626Venue` in front of a real vault would drag share accounting and
/// `Math.mulDiv` into every path, which no solver here finishes and none of
/// these properties are about.
///
/// Both answers are settable so a proof can quantify over what a venue claims,
/// including a venue pinned to another pool or holding the wrong token — the
/// two cases the guards exist to reject.
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
