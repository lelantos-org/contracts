// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FeeConfig } from "../FeeConfig.sol";
import { YieldOps } from "./YieldOps.sol";

/// Pool-managed yield index: storage, access control, and the registry lookup
/// the logic requires. Every non-trivial operation lives in `YieldOps`, an
/// external library that runs against this contract's storage by
/// `delegatecall`.
///
/// Notes in a yield asset are denominated in normalized units rather than
/// underlying: one unit is worth `gross / supply` of the token, and that ratio
/// rises as the venue earns. The circuit is unaffected, since `publicIn` and
/// `publicOut` remain plain integers and value conservation is unchanged,
/// because every note in an asset shares the same unit. The index exists only
/// at the token boundary.
///
/// Venue binding is immutable. `_initYieldAsset` is the only path that writes a
/// venue, and the registry it is called from is add-only, so an asset id's
/// venue is fixed for its lifetime. There is no `setVenue`: an owner able to
/// re-point a live id could move every holder's principal into another protocol
/// with no delay. Replacing a venue means registering a new asset id, at the
/// cost of a public exit and re-entry for those holders.
///
/// Yield is therefore a property of the asset id, not of the note, which is
/// what makes opting out possible: the plain id for a token remains risk-free
/// custody, and a depositor chooses between them by picking an id.
///
/// Solvency is structural. The index is derived from what the pool holds and is
/// never stored or oracle-fed, so no accounting drift can make the pool owe
/// more than it has. The one stored index, `lastIdx`, is a fee high-water mark:
/// a wrong value mis-collects for the treasury and can never pay a user the
/// wrong amount.
abstract contract YieldIndex is FeeConfig {
    YieldOps.Store internal _y;

    /// Resolves an asset id to the registry fields this mixin cannot see.
    /// Implemented by the pool over its own registry. Used only by the entry
    /// points below, which hold no `AssetEntry`; the spend and shield paths
    /// pass `scale` down from the one they already have.
    function _yieldAsset(uint64 id) internal view virtual returns (IERC20 token, uint256 scale);

    // ============== Views ====================================================

    /// True iff `id` carries a venue. One SLOAD, and the branch test the pool's
    /// yield-aware paths perform.
    function isYieldAsset(uint64 id) public view returns (bool) {
        return _y.params[id].venue != address(0);
    }

    /// Everything an indexer or the SDK needs for one asset.
    ///
    /// One view returning one struct rather than a public getter per mapping:
    /// the pool sits close to the EIP-170 limit, and each additional dispatch
    /// entry costs code size.
    struct YieldState {
        address venue;
        uint16 bufferBps;
        uint16 perfBps;
        bool halted;
        uint256 totalNormalized;
        uint256 accruedFeeNormalized;
        uint256 idle;
        uint256 lastIdx;
        /// Derived, not stored. `RAY` when nothing is outstanding.
        uint256 index;
    }

    function yieldState(uint64 id) external view returns (YieldState memory) {
        YieldOps.YieldParams memory q = _y.params[id];
        return YieldState({
            venue: q.venue,
            bufferBps: q.bufferBps,
            perfBps: q.perfBps,
            halted: q.halted,
            totalNormalized: _y.totalNormalized[id],
            accruedFeeNormalized: _y.accruedFeeNormalized[id],
            idle: _y.idle[id],
            lastIdx: _y.lastIdx[id],
            index: index(id)
        });
    }

    /// The index in RAY. `RAY` when nothing is outstanding.
    function index(uint64 id) public view returns (uint256) {
        (, uint256 scale) = _yieldAsset(id);
        return YieldOps.index(_y, id, scale);
    }

    // ============== Registration =============================================

    /// Called by the pool immediately after its registry has accepted `id`.
    function _initYieldAsset(uint64 id, IERC20 token, address venue, uint16 bufferBps, uint16 perfBps) internal {
        YieldOps.initAsset(_y, id, address(token), venue, bufferBps, perfBps);
    }

    // ============== Owner controls ===========================================

    /// Updates the buffer split and the performance-fee rate. Neither rate
    /// touches the venue binding, so neither can move principal between
    /// protocols.
    function setYieldParams(uint64 id, uint16 bufferBps, uint16 perfBps) external onlyOwner {
        (, uint256 scale) = _yieldAsset(id);
        YieldOps.setParams(_y, id, scale, bufferBps, perfBps);
    }

    /// Withdraws the venue position back to idle and stops further supply.
    /// Leaves the venue bound; see `YieldOps.emergencyUnwind`.
    function emergencyUnwind(uint64 id) external onlyOwner nonReentrant returns (uint256) {
        return YieldOps.emergencyUnwind(_y, id);
    }

    /// Halts or resumes supply to the asset's bound vault.
    function setHalted(uint64 id, bool halted) external onlyOwner {
        YieldOps.setHalted(_y, id, halted);
    }

    // ============== Permissionless maintenance ===============================

    /// Restores the buffer split in either direction.
    function rebalance(uint64 id) external nonReentrant {
        (IERC20 token, uint256 scale) = _yieldAsset(id);
        YieldOps.rebalance(_y, id, token, scale);
    }

    /// Brings the treasury's cut up to date without waiting on user traffic.
    function accruePerf(uint64 id) external nonReentrant {
        (, uint256 scale) = _yieldAsset(id);
        YieldOps.accruePerf(_y, id, scale);
    }

    /// Converts the treasury's units to underlying and transfers them.
    /// Counterpart to `sweep(IERC20)`.
    function sweepNormalized(uint64 id) external nonReentrant returns (uint256) {
        (IERC20 token, uint256 scale) = _yieldAsset(id);
        return YieldOps.sweepNormalized(_y, id, token, scale, treasury);
    }
}
