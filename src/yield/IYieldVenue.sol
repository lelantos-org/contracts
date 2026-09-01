// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// The venue surface `YieldIndex` drives. One venue instance per
/// `(assetId, vault)`; the pool holds no venue logic of its own.
///
/// The pool pushes: it transfers the underlying to the venue and then calls
/// `deposit`, so a venue never holds an allowance over the contract custodying
/// shielded funds and a compromised venue cannot drain the pool. `withdraw`
/// sends the underlying straight back to the pool, so a draw is one hop.
///
/// `POOL` and `VAULT` are exposed so `MASP.addYieldAsset` can verify on-chain
/// that this venue is pinned to this pool and that its vault's asset is the
/// token being registered.
interface IYieldVenue {
    /// Supply `assets` of the underlying, already transferred in by the pool.
    function deposit(uint256 assets) external;

    /// Redeem `assets` of the underlying and send it to `POOL`.
    function withdraw(uint256 assets) external;

    /// Underlying currently claimable by this venue's position. The pool's
    /// index derives from this plus its own idle balance, so it must never
    /// exceed what the venue could return.
    function totalAssets() external view returns (uint256);

    /// Upper bound on what `withdraw` can service now. The pool gates a draw on
    /// this, so a drained vault surfaces as a bounded shortfall rather than a
    /// revert inside the venue.
    function maxWithdraw() external view returns (uint256);

    /// The pool this venue is pinned to. Immutable in every implementation.
    function POOL() external view returns (address);

    /// The ERC-4626 vault this venue holds shares of. Immutable.
    function VAULT() external view returns (address);
}
