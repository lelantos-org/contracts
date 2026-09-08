// Model of `NullifierSet` (src/NullifierSet.sol).
//
// Replayed against `test/utils/NullifierSetHarness.sol` by
// test/quint/NullifierSetReplay.t.sol.
//
// WHY THIS ONE
//
// The contract stores nullifiers as a packed bitmap: `_spentBuckets[nf >> 8]`
// holds 256 bits keyed by `nf & 0xff`. Splitting one 256-bit value into a
// bucket and a bit position is where aliasing bugs live.
//
// test/symbolic/ proves the isolation property for *pairs* — consuming `a`
// never marks `b`. What it does not do is run a sequence: nine consumes across
// three buckets, with the whole spent set re-read and compared after each one.
// That is what this adds, and it is the reason the domain below is chosen the
// way it is rather than being a wide random range.
//
// ABSTRACTED
//
// Nothing, really. The driver maps model integers straight onto `bytes32` and
// reads `spent()` back, so this is the contract's actual storage behaviour
// under a model-chosen sequence. There is no mock and no shadow state.
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
  /// Every bit position is shared across buckets and every bucket holds several
  /// bits, so a bucket index that ignored the high bits, or a mask that ignored
  /// the low ones, changes the observed set. A domain of random 256-bit values
  /// would almost never collide and would exercise none of this.
  pure val NULLIFIERS = Set(0, 1, 255, 256, 257, 511, 512)
  pure val BUCKET_SIZE = 256

  var spentSet: Set[int]

  /// Ghost. Not compared against the chain - `ignoreState` in the config says
  /// so and why. It exists because with a single monotone set variable there is
  /// no non-trivial state invariant to write: `spentSet.subseteq(NULLIFIERS)`
  /// is true by construction and survives every mutation of `consume`, which
  /// makes `quint run --invariant` look like it is checking something when it
  /// is not. Counting consumes independently of recording them gives the
  /// invariant below something real to disagree with.
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

  /// Negative path: consume one that is already spent.
  ///
  /// The model asserts a *rejection* — state is unchanged — and the driver wraps
  /// the call in `vm.expectRevert(NullifierSet.DoubleSpend.selector)`. No
  /// invariant handler expresses this: an invariant run with
  /// `fail_on_revert = false` cannot tell "correctly rejected" from "reverted
  /// for some unrelated reason" from "never ran at all".
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

  /// Nothing outside the modelled domain ever becomes spent.
  ///
  /// True by construction - `consume` only ever draws from `NULLIFIERS` - so
  /// this cannot fail and is documentation, not a check. Kept for that, and
  /// paired with the real one below.
  val inv_spentWithinDomain = spentSet.subseteq(NULLIFIERS)

  /// Every successful consume recorded exactly one new nullifier.
  ///
  /// The consume counter is maintained independently of the set, so a `consume`
  /// that recorded nothing, or recorded the wrong value, or recorded one it had
  /// already recorded, breaks the equality. Mutation testing put numbers on
  /// this: without it, neither of those two mutations was caught by the
  /// invariant check at all.
  val inv_setSizeMatchesConsumes = spentSet.size() == consumeCount

  val allInvariants = and {
    inv_spentWithinDomain,
    inv_setSizeMatchesConsumes,
  }

  // --- witnesses --------------------------------------------------------

  /// Two spent nullifiers sharing a bucket. Without this, a run could satisfy
  /// every invariant while only ever touching one bit per bucket, which is
  /// precisely the case that cannot detect a mask error.
  val wit_sameBucket =
    spentSet.exists(a => spentSet.exists(b => a != b and a / BUCKET_SIZE == b / BUCKET_SIZE))

  /// Two spent nullifiers sharing a bit position across different buckets — the
  /// aliasing a wrong bucket index would collapse.
  val wit_sharedBitAcrossBuckets =
    spentSet.exists(a =>
      spentSet.exists(b =>
        a != b and a % BUCKET_SIZE == b % BUCKET_SIZE and a / BUCKET_SIZE != b / BUCKET_SIZE))
}
