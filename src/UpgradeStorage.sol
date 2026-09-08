// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Exit-window state, held at a fixed ERC-7201 slot.
///
/// Written by the proxy in its own context and read by the implementation under
/// `delegatecall`. The namespaced slot keeps it clear of the pool's sequential
/// layout across upgrades.
library UpgradeStorage {
    /// `keccak256(abi.encode(uint256(keccak256("lelantos.storage.DelayedUpgrade")) - 1)) & ~bytes32(uint256(0xff))`
    /// Re-derived in `UpgradeStorage.t.sol`.
    bytes32 internal constant SLOT = 0xfae014a5d49f1423ef3edefa98c6ee7aa2d26ee322477f34a126074d398a3b00;

    /// Occupies one slot: 20 + 5 + 5 + 1 = 31 bytes. The pool reads this slot on
    /// every proof-dependent entry point. `uint40` spans timestamps to the year
    /// 36,812.
    ///
    /// @custom:storage-location erc7201:lelantos.storage.DelayedUpgrade
    struct Layout {
        /// Queued implementation; zero when none is pending.
        address pendingImplementation;
        /// Timestamp from which `pendingImplementation` may be activated.
        /// Extended by the duration of any pause, so the window measures
        /// unpaused time.
        uint40 activationAt;
        /// Spends are paused while `block.timestamp < pausedUntil`.
        uint40 pausedUntil;
        /// Guardian's one-shot pause flag. Cleared only by governance.
        bool guardianPauseUsed;
    }

    /// Named `$` because `layout` is reserved for promotion to a keyword.
    function $() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly {
            l.slot := s
        }
    }

    // ============== Reads ====================================================
    //
    // Callers query state rather than reading fields, so the layout stays
    // confined to this file.

    /// True while an upgrade is queued and not yet activated.
    function upgradePending() internal view returns (bool) {
        return $().pendingImplementation != address(0);
    }

    /// Timestamp until which proof-dependent entry points are halted. Zero or a
    /// past value means unpaused.
    function spendsPausedUntil() internal view returns (uint256) {
        return $().pausedUntil;
    }
}
