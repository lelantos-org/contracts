// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// The pool's sequential storage slots, in one place.
///
/// `upgrade/StorageLayout.t.sol` pins every entry against the live contract; any
/// other suite that reads raw storage takes its slot from here rather than
/// restating a number. Both used to hold their own copy, and both had to be
/// edited when the verifiers left the layout.
///
/// Behind a proxy the layout is the compatibility contract between versions, so
/// an upgrade may only append: a new entry goes after `END`, and `END` moves.
library PoolSlots {
    uint256 internal constant ROOTS = 0; // bytes32[64] -> slots 0..63
    uint256 internal constant PACKED_COUNTS = 64; // rootIndex | committedCount
    uint256 internal constant RETIRED_KNOWN_ROOT = 65; // reserved gap (`_retiredKnownRootSlot`)
    uint256 internal constant OWNER = 66;
    uint256 internal constant ASSETS = 67;
    uint256 internal constant SPENT_BUCKETS = 68;
    uint256 internal constant TREASURY = 69;
    uint256 internal constant ACCRUED_FEE = 70;
    uint256 internal constant YIELD_STORE = 71; // 5 slots, 71..75
    /// The Permit2 address. The two verifiers used to sit at 76 and 77; they
    /// moved to the `VerifierStorage` namespace so the proxy can install a
    /// replacement without holding a copy of this layout, and everything below
    /// shifted up by two.
    uint256 internal constant PERMIT2 = 76;
    uint256 internal constant ESCROWED = 77;
    uint256 internal constant NEXT_DEPOSIT_ID = 78;
    uint256 internal constant CANCEL_DELAY = 79;
    /// `_escrowPulled`, the yield-escrow refund cap. A mapping root, so the slot
    /// itself stays zero; entries live at `keccak256(abi.encode(id, ESCROW_PULLED))`.
    uint256 internal constant ESCROW_PULLED = 80;
    /// First slot past the layout.
    uint256 internal constant END = 81;
}
