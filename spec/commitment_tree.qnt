// Model of `CommitmentTree._advanceRoot` and the root lookups `isKnownRoot`
// and `rootIndexOf` (src/CommitmentTree.sol).
//
// Replayed against `test/fuzz/CommitmentTreeHarness.sol` by
// test/quint/CommitmentTreeReplay.t.sol.
//
// SCOPE
//
// The root history is a 64-entry ring buffer. On wrap, the pushed root
// overwrites the oldest slot, and a root is known exactly while some slot still
// holds it: `isKnownRoot` scans the ring and keeps no separate known-root
// record. With `[invariant] depth = 64` in foundry.toml the fuzz suite rarely
// reaches a wrap, and test/symbolic/CommitmentTree.symbolic.t.sol proves the
// property for two advances. A Quint trace runs past the wrap and is checked at
// every step.
//
// ABSTRACTED
//
// Roots are opaque small integers, not Poseidon hashes: the model covers the
// bookkeeping around a root, not the hashing that produces it. The driver maps
// model integers onto bytes32 and back. `0` means "slot never written", which
// the contract's lookups never match, and `1` stands for the genesis
// EMPTY_ROOT.
//
// The domain is small (six distinct new roots over 64 slots) so that an evicted
// value is usually still held by another slot, exercising the requirement that
// eviction does not unlearn a root the ring still holds.
module commitment_tree {
  /// CommitmentTree.ROOT_HISTORY
  pure val ROOT_HISTORY = 64
  /// Stands for CommitmentTree.EMPTY_ROOT.
  pure val EMPTY = 1
  /// Model roots are drawn from EMPTY + 1 .. MAX_ROOT.
  pure val MAX_ROOT = 7
  /// Bound on `inserted` per advance. The contract accepts any uint64; the cap
  /// is enforced by `MASP._requireTreePosition`, outside this spec.
  pure val MAX_INSERTED = 4

  /// roots[0..63]. 0 means "never written", as in storage.
  var rootRing: List[int]
  var rootIndex: int
  var committedCount: int
  /// `isKnownRoot`: what the scan over the ring finds.
  var knownRoots: Set[int]

  /// Ghosts; not compared against the chain (see `ignoreState` in the config).
  /// Without them the ring walk and the leaf count are unconstrained by any
  /// invariant: under mutation testing, advancing the index by two or counting
  /// one leaf per advance instead of `inserted` satisfies every invariant.
  /// Tracking each quantity independently gives the invariants a second source
  /// to contradict.
  var advances: int
  var insertedTotal: int

  def currentRoot = rootRing[rootIndex]

  /// The non-zero roots a ring holds.
  def ringRoots(ring: List[int]): Set[int] =
    ring.indices().map(i => ring[i]).exclude(Set(0))

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
    all {
      rootRing' = rootRing.replaceAt(newIdx, newRoot),
      rootIndex' = newIdx,
      committedCount' = committedCount + inserted,
      advances' = advances + 1,
      insertedTotal' = insertedTotal + inserted,
      // `isKnownRoot` scans the ring, so a root is known exactly while a slot
      // holds it: the evicted value stays known if another slot still does.
      knownRoots' = ringRoots(rootRing.replaceAt(newIdx, newRoot)),
    }
  }

  action step = any { advance }

  // --- invariants -------------------------------------------------------

  /// `rootIndex` is masked rather than reduced, so the contract requires
  /// ROOT_HISTORY to be a power of two.
  ///
  /// Holds by construction in the model, which reduces modulo ROOT_HISTORY; the
  /// check is meaningful in the replay, where it is compared against the
  /// contract's masked index.
  val inv_rootIndexInRing = rootIndex >= 0 and rootIndex < ROOT_HISTORY

  /// The ring advances exactly one slot per advance. The independent advance
  /// count makes a wrong stride visible to the invariant check, not only to the
  /// replay.
  val inv_indexTracksAdvances = rootIndex == advances % ROOT_HISTORY

  /// The leaf count is the sum of each advance's `inserted`, not the number of
  /// advances.
  val inv_countIsSumOfInserts = committedCount == insertedTotal

  /// The live root is always accepted; spends depend on this.
  val inv_currentRootIsKnown = knownRoots.contains(currentRoot)

  /// Every root still in the ring is known, including a root held by several
  /// slots after the older slot is overwritten. The traces reach duplicate
  /// roots.
  val inv_ringRootsAreKnown =
    rootRing.indices().forall(i => rootRing[i] == 0 or knownRoots.contains(rootRing[i]))

  /// Nothing is known that is not in the ring: eviction unlearns a value that no
  /// other slot holds.
  val inv_knownRootsAreInRing =
    knownRoots.forall(r => rootRing.indices().exists(i => rootRing[i] == r))

  val allInvariants = and {
    inv_rootIndexInRing,
    inv_currentRootIsKnown,
    inv_knownRootsAreInRing,
    inv_ringRootsAreKnown,
    inv_indexTracksAdvances,
    inv_countIsSumOfInserts,
  }
}
