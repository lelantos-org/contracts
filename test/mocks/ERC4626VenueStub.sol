// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// A venue that answers `POOL`/`VAULT` but is pinned elsewhere.
contract ERC4626VenueStub {
    address public immutable POOL;
    address public immutable VAULT;

    constructor(address pool, address vault) {
        POOL = pool;
        VAULT = vault;
    }
}
