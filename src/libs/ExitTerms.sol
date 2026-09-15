// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { UpgradeStorage } from "../UpgradeStorage.sol";

/// Delayed raises for the terms a holder exits under, held at a fixed ERC-7201
/// slot.
///
/// Three owner-set parameters decide what leaving costs someone already in the
/// pool, and all three are read live rather than bound at entry:
///
/// - `withdrawBps`, the unshield fee, read at spend time;
/// - `perfBps`, the yield asset's performance fee, charged on growth accrued
///   while the holder stays;
/// - `cancelDelay`, the lock on an escrow already in flight, read at cancel.
///
/// Lowering any of them can only help a holder, so it applies at once. A raise
/// is queued here instead and takes effect only through the permissionless
/// commit once `DELAY` has passed, so every holder sees it coming and can exit
/// under the old terms first.
///
/// The delay is measured from the raise itself, so it does not depend on call
/// order relative to an upgrade: `DelayedUpgradeProxy` requires
/// `UPGRADE_DELAY <= DELAY`, so a raise queued alongside an upgrade cannot land
/// before the upgrade activates.
///
/// Namespaced rather than declared in the pool, so the pool's sequential layout
/// (`StorageLayout.t.sol`) is unchanged.
library ExitTerms {
    /// `keccak256(abi.encode(uint256(keccak256("lelantos.storage.ExitTerms")) - 1)) & ~bytes32(uint256(0xff))`
    /// Re-derived in `ExitTerms.t.sol`.
    bytes32 internal constant SLOT = 0x0f9c0e5b0c444e1c6ae77a031530181a8734d67ee4430f4d78d0babf00f7d800;

    /// Notice a raise gets before it can be committed. At least the upgrade
    /// window, which `DelayedUpgradeProxy` bounds by this constant, so the
    /// raise-then-upgrade ordering above cannot charge holders leaving ahead of
    /// an upgrade.
    uint256 internal constant DELAY = 30 days;

    /// Values of the indexed `term` topic of `ExitTermRaisePending`.
    uint8 internal constant WITHDRAW_BPS = 0;
    uint8 internal constant PERF_BPS = 1;
    uint8 internal constant CANCEL_DELAY = 2;

    /// One queued raise. 4 + 5 bytes, one slot. `notBefore == 0` means none is
    /// queued; a queued `value` is never zero, since it exceeds the live value.
    /// `uint32` holds every term: the rates are capped at 2,000 and the delay
    /// is a `uint32` in the pool.
    struct Pending {
        uint32 value;
        uint40 notBefore;
    }

    /// @custom:storage-location erc7201:lelantos.storage.ExitTerms
    struct Layout {
        mapping(uint64 assetId => Pending) withdrawBps;
        mapping(uint64 assetId => Pending) perfBps;
        /// Pool-wide, so it has no asset id.
        Pending cancelDelay;
    }

    /// The raise queued for `term` on `assetId` changed. `value == 0` (with
    /// `notBefore == 0`) means none is queued any more: it was committed, which
    /// also emits the term's own applied event, or cleared by a setter call at
    /// or below the live value. `assetId` is zero for `CANCEL_DELAY`.
    ///
    /// `notBefore` is the earliest commit time as of queueing; a later guardian
    /// pause defers it (see `dueAt`), which this event does not re-announce.
    event ExitTermRaisePending(uint64 indexed assetId, uint8 indexed term, uint256 value, uint256 notBefore);

    /// Every queued raise for the id is still inside its notice period; the
    /// earliest becomes committable at `due`.
    error RaiseNotDue(uint256 due);
    /// Neither the id's rates nor the pool-wide delay has a raise queued.
    error NoPendingRaise();

    /// Named `$` because `layout` is reserved for promotion to a keyword.
    function $() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly {
            l.slot := s
        }
    }

    /// Routes a setter's new value for one term. Returns true when `next` was
    /// queued (or was already queued), in which case the caller keeps `live`;
    /// false when the caller applies `next` now.
    ///
    /// At or below `live`, any queued raise is dropped: the owner's latest word
    /// is a value no higher than today's, so the raise is withdrawn with it.
    ///
    /// Above `live`, a call repeating the queued value keeps its timer, so a
    /// setter that also carries an immediate term (the deposit rate, the
    /// buffer) can be called again without restarting the notice. Any other
    /// value restarts it, lower ones included: the notice is for a specific
    /// value, and holders must not have to guess which one will land.
    ///
    /// Bounds are the caller's to check before this call.
    function propose(Pending storage p, uint256 live, uint256 next, uint64 id, uint8 term) internal returns (bool) {
        if (next <= live) {
            if (p.notBefore != 0) _clear(p, id, term);
            return false;
        }
        if (p.value != next) {
            uint256 notBefore = block.timestamp + DELAY;
            // Callers bound `next` well inside uint32; uint40 spans timestamps to
            // the year 36,812.
            // forge-lint: disable-next-line(unsafe-typecast)
            // aderyn-fp-next-line(unsafe-casting)
            p.value = uint32(next);
            // forge-lint: disable-next-line(unsafe-typecast)
            // aderyn-fp-next-line(unsafe-casting)
            p.notBefore = uint40(notBefore);
            emit ExitTermRaisePending(id, term, next, notBefore);
        }
        return true;
    }

    /// When `p` becomes committable; zero if nothing is queued.
    ///
    /// A guardian pause halts exits, so time spent paused cannot count as
    /// notice. Rather than track paused time, the raise waits a full `DELAY`
    /// after the latest pause ends: `pausedUntil` is never cleared, so an old
    /// pause yields a bound already in the past.
    function dueAt(Pending storage p) internal view returns (uint256) {
        uint256 notBefore = p.notBefore;
        if (notBefore == 0) return 0;
        uint256 afterPause = UpgradeStorage.spendsPausedUntil() + DELAY;
        return notBefore > afterPause ? notBefore : afterPause;
    }

    /// Consumes `p` if it is due, returning its value; returns zero if nothing
    /// is queued or the notice has not run. `wait` accumulates the earliest due
    /// time among raises that were queued but not taken, for the caller's
    /// `RaiseNotDue`.
    function take(Pending storage p, uint64 id, uint8 term, uint256 wait)
        internal
        returns (uint256 value, uint256 nextWait)
    {
        uint256 due = dueAt(p);
        if (due == 0) return (0, wait);
        if (block.timestamp < due) return (0, due < wait ? due : wait);
        value = p.value;
        _clear(p, id, term);
        return (value, wait);
    }

    function _clear(Pending storage p, uint64 id, uint8 term) private {
        p.value = 0;
        p.notBefore = 0;
        emit ExitTermRaisePending(id, term, 0, 0);
    }
}
