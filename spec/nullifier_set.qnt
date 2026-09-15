// Model of `NullifierSet` (src/NullifierSet.sol).
//
// Replayed against `test/utils/NullifierSetHarness.sol` by
// test/quint/NullifierSetReplay.t.sol.
//
// SCOPE
//
// The contract stores nullifiers as a packed bitmap: `_spentBuckets[nf >> 8]`
// holds 256 bits keyed by `nf & 0xff`. An error in splitting a 256-bit value
// into bucket and bit position aliases distinct nullifiers.
//
// test/symbolic/ proves pairwise isolation: consuming `a` never marks `b`.
// This spec checks sequences of consumes across three buckets, re-reading and
// comparing the whole spent set after each step. The domain below is chosen
// for that purpose rather than as a wide random range.
//
// ABSTRACTED
//
// Nothing. The driver maps model integers directly onto `bytes32` and reads
// `spent()` back, so the replay observes the contract's storage behaviour under
// a model-chosen sequence, with no mock and no shadow state.
module nullifier_set {
  /// The nullifier domain, chosen for bucket/bit structure rather than spread:
  ///
  ///   value | bucket (nf >> 8) | bit (nf & 0xff)
  ///   ------+------------------+-----------------
  ///       0 |                0 |   0
  ///       1 |                0 |   1
  ///     255 |                0 | 255
  ///     256 |                1 |   0   <- same bit as 0, different bucket
  ///     257 |                1 |   1   <- same bit as 1, different bucket
  ///     511 |                1 | 255   <- same bit as 255, different bucket
  ///     512 |                2 |   0   <- same bit as 0 and 256
  ///
  /// Bit positions repeat across buckets and buckets 0 and 1 hold several bits
  /// each, so a bucket index that ignores the high bits, or a mask that ignores
  /// the low bits, changes the observed set. Random 256-bit values would almost
  /// never share a bucket or bit position.
  pure val NULLIFIERS = Set(0, 1, 255, 256, 257, 511, 512)
  pure val BUCKET_SIZE = 256

  var spentSet: Set[int]

  /// Ghost; not compared against the chain (see `ignoreState` in the config).
  /// A single monotone set admits no non-trivial state invariant:
  /// `spentSet.subseteq(NULLIFIERS)` holds by construction under any mutation
  /// of `consume`. Counting consumes independently of the set gives
  /// `inv_setSizeMatchesConsumes` a second source to contradict.
  var consumeCount: int

  action init = all {
    spentSet' = Set(),
    consumeCount' = 0,
  }

  /// Consume an unspent nullifier.
  action consume = {
    nondet nf = NULLIFIERS.oneOf()
    all {
      not(spentSet.contains(nf)),
      spentSet' = spentSet.union(Set(nf)),
      consumeCount' = consumeCount + 1,
    }
  }

  /// Negative path: consume a nullifier that is already spent.
  ///
  /// The model asserts a rejection (state unchanged) and the driver wraps the
  /// call in `vm.expectRevert(NullifierSet.DoubleSpend.selector)`. An invariant
  /// run with `fail_on_revert = false` cannot distinguish a correct rejection
  /// from an unrelated revert or from a call that never ran.
  action consumeSpent = {
    nondet nf = NULLIFIERS.oneOf()
    all {
      spentSet.contains(nf),
      spentSet' = spentSet,
      consumeCount' = consumeCount,
    }
  }

  action step = any { consume, consumeSpent }

  // --- invariants -------------------------------------------------------

  /// Nothing outside the modelled domain becomes spent.
  ///
  /// Holds by construction (`consume` only draws from `NULLIFIERS`), so this
  /// documents the domain; `inv_setSizeMatchesConsumes` is the effective check.
  val inv_spentWithinDomain = spentSet.subseteq(NULLIFIERS)

  /// Every successful consume records exactly one new nullifier.
  ///
  /// The consume counter is maintained independently of the set, so a `consume`
  /// that records nothing, records the wrong value, or re-records an existing
  /// value breaks the equality. Without this invariant, mutation testing shows
  /// such mutations pass the invariant check.
  val inv_setSizeMatchesConsumes = spentSet.size() == consumeCount

  val allInvariants = and {
    inv_spentWithinDomain,
    inv_setSizeMatchesConsumes,
  }

  // --- witnesses --------------------------------------------------------

  /// Two spent nullifiers sharing a bucket. Without this, a run could satisfy
  /// every invariant while touching only one bit per bucket, in which case a
  /// mask error is undetectable.
  val wit_sameBucket =
    spentSet.exists(a => spentSet.exists(b => a != b and a / BUCKET_SIZE == b / BUCKET_SIZE))

  /// Two spent nullifiers sharing a bit position across different buckets — the
  /// aliasing a wrong bucket index would collapse.
  val wit_sharedBitAcrossBuckets =
    spentSet.exists(a =>
      spentSet.exists(b =>
        a != b and a % BUCKET_SIZE == b % BUCKET_SIZE and a / BUCKET_SIZE != b / BUCKET_SIZE))
}
