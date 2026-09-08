// Model of `CommitmentTree._advanceRoot` (src/CommitmentTree.sol).
//
// Replayed against `test/fuzz/CommitmentTreeHarness.sol` by
// test/quint/CommitmentTreeReplay.t.sol.
//
// WHY THIS ONE FIRST
//
// The ring buffer is 64 entries deep, and the interesting behaviour is what
// happens when it wraps: an evicted root is unlearned, *unless* it is the root
// being pushed, or unless the slot was never written. `[invariant] depth = 64`
// in foundry.toml means the fuzz suite essentially never reaches a wrap, and
// test/symbolic/CommitmentTree.symbolic.t.sol proves the property for two
// advances. A Quint trace can be driven straight past the wrap and asserted at
// every step in between.
//
// ABSTRACTED
//
// Roots are opaque small integers, not Poseidon hashes: this models the
// bookkeeping around a root, not the hashing that produces one. The driver maps
// model integers onto bytes32 and back. `0` is reserved to mean "slot never
// written", matching the contract's `evicted != bytes32(0)` test, and `1` stands
// for the genesis EMPTY_ROOT.
//
// The domain is deliberately small (six distinct new roots over 64 slots) so
// that an evicted value is usually still live elsewhere in the ring. That is
// exactly the case the `evicted != newRoot` carve-out exists for, and drawing
// roots from a wide domain would almost never produce it.
module commitment_tree {
  /// CommitmentTree.ROOT_HISTORY
  pure val ROOT_HISTORY = 64
  /// Stands for CommitmentTree.EMPTY_ROOT.
  pure val EMPTY = 1
  /// Model roots are drawn from EMPTY + 1 .. MAX_ROOT.
  pure val MAX_ROOT = 7
  /// Bound on `inserted` per advance. The contract takes a uint64 and does not
  /// itself cap it; the cap lives in `MASP._requireTreePosition`, which is not
  /// what this spec models.
  pure val MAX_INSERTED = 4

  /// roots[0..63]. 0 means "never written", as in storage.
  var rootRing: List[int]
  var rootIndex: int
  var committedCount: int
  var knownRoots: Set[int]

  /// Ghosts. Not compared against the chain - `ignoreState` in the config says
  /// so and why. Both exist because the ring walk and the leaf count are
  /// otherwise unconstrained by any invariant: mutation testing showed that
  /// advancing the index by two, or counting one leaf per advance instead of
  /// `inserted`, left every invariant satisfied. Tracking each quantity a
  /// second way gives them something to contradict.
  var advances: int
  var insertedTotal: int

  def currentRoot = rootRing[rootIndex]

  action init = all {
    // `_initCommitmentTree` writes roots[0] and leaves the rest at zero.
    rootRing' = range(0, ROOT_HISTORY).foldl([], (acc, i) => acc.append(if (i == 0) EMPTY else 0)),
    rootIndex' = 0,
    committedCount' = 0,
    knownRoots' = Set(EMPTY),
    advances' = 0,
    insertedTotal' = 0,
  }

  action advance = {
    nondet newRoot = (EMPTY + 1).to(MAX_ROOT).oneOf()
    nondet inserted = 0.to(MAX_INSERTED).oneOf()
    val newIdx = (rootIndex + 1) % ROOT_HISTORY
    val evicted = rootRing[newIdx]
    all {
      rootRing' = rootRing.replaceAt(newIdx, newRoot),
      rootIndex' = newIdx,
      committedCount' = committedCount + inserted,
      advances' = advances + 1,
      insertedTotal' = insertedTotal + inserted,
      // Mirrors `_advanceRoot`: unlearn the evicted root, but not when the slot
      // was never written and not when it is the root being pushed. Dropping
      // either carve-out would mark a root still live in the buffer unknown.
      knownRoots' =
        if (evicted != 0 and evicted != newRoot)
          knownRoots.exclude(Set(evicted)).union(Set(newRoot))
        else
          knownRoots.union(Set(newRoot)),
    }
  }

  action step = any { advance }

  // --- invariants -------------------------------------------------------

  /// `rootIndex` is masked, not reduced, so a ROOT_HISTORY that stopped being a
  /// power of two would silently break this.
  ///
  /// True by construction here, since the model reduces modulo ROOT_HISTORY.
  /// Its value is in the replay, where it is compared against the contract's
  /// masked index.
  val inv_rootIndexInRing = rootIndex >= 0 and rootIndex < ROOT_HISTORY

  /// The ring advances exactly one slot per advance. Counting advances
  /// separately is what makes a wrong stride visible to the invariant check
  /// rather than only to the replay.
  val inv_indexTracksAdvances = rootIndex == advances % ROOT_HISTORY

  /// The leaf count is the sum of what each advance inserted, not a count of
  /// advances. Exactly the confusion that made `invariant_rootCoherence`
  /// vacuous over in test/invariant/.
  val inv_countIsSumOfInserts = committedCount == insertedTotal

  /// The live root is always accepted. This is the property a spend depends on.
  val inv_currentRootIsKnown = knownRoots.contains(currentRoot)

  /// NOT an invariant, and checking established that.
  ///
  /// "Every root still in the ring is still known" reads like it should hold,
  /// and it does not: `_advanceRoot` unlearns the value it evicted without
  /// checking whether that same value still occupies another slot. So a root
  /// present twice in the ring becomes unknown as soon as the older of the two
  /// slots is overwritten, even though the newer one still holds it.
  ///
  /// Benign in production, where roots come from Poseidon over a strictly
  /// growing leaf set and two batches never share one: the duplicate case
  /// cannot arise. It is recorded here because it is a real gap between the
  /// ring's contents and `isKnownRoot`, and because a future change that made
  /// roots repeatable (a no-op batch, say) would turn it into a live bug that
  /// silently rejects valid proofs.
  ///
  /// `wit_ringRootUnlearned` below witnesses it, so the traces demonstrably
  /// reach the state rather than merely failing to rule it out.
  val wit_ringRootUnlearned =
    rootRing.indices().exists(i => rootRing[i] != 0 and not(knownRoots.contains(rootRing[i])))

  /// Nothing is known that is not in the ring. Rules out a leak in the other
  /// direction: an eviction that failed to unlearn a value no longer present.
  val inv_knownRootsAreInRing =
    knownRoots.forall(r => rootRing.indices().exists(i => rootRing[i] == r))

  val allInvariants = and {
    inv_rootIndexInRing,
    inv_currentRootIsKnown,
    inv_knownRootsAreInRing,
    inv_indexTracksAdvances,
    inv_countIsSumOfInserts,
  }
}
