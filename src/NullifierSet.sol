// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// Packed-bitmap nullifier set. `_spentBuckets[nf >> 8]` holds 256 bits, keyed
/// by `nf & 0xff`.
abstract contract NullifierSet {
    mapping(uint256 => uint256) private _spentBuckets;

    event NullifierConsumed(bytes32 indexed nf);

    error DoubleSpend();
    error DuplicateNullifier();

    /// True iff `nf` has been spent.
    function spent(bytes32 nf) external view returns (bool) {
        uint256 n = uint256(nf);
        return (_spentBuckets[n >> 8] >> (n & 0xff)) & 1 != 0;
    }

    /// Mark `nf` spent in the packed bitmap. Reverts on a double-spend.
    function _consumeNullifier(bytes32 nf) internal {
        uint256 n = uint256(nf);
        uint256 bucketIdx = n >> 8;
        // The shift amount is on the right-hand side (`value << shift`).
        // forge-lint: disable-next-line(incorrect-shift)
        uint256 mask = 1 << (n & 0xff);
        uint256 word = _spentBuckets[bucketIdx];
        if (word & mask != 0) revert DoubleSpend();
        _spentBuckets[bucketIdx] = word | mask;
        emit NullifierConsumed(nf);
    }
}
