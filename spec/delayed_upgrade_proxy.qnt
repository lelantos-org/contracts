// Model of `DelayedUpgradeProxy` (src/DelayedUpgradeProxy.sol) and the
// ERC-7201 slot it keeps in `src/UpgradeStorage.sol`.
//
// Replayed against a real proxy over MockPoolV1/V2 by
// test/quint/DelayedUpgradeProxyReplay.t.sol.
//
// WHY THIS ONE
//
// test/symbolic/DelayedUpgradeProxy.symbolic.t.sol proves eleven properties over
// all inputs, and every one of them is about a *single* call: activation happens
// exactly after the window, a queued payload cannot be swapped, the guardian
// pause is one-shot, non-admins are rejected. That is the shape halmos is good
// at, and it leaves the sequencing untouched.
//
// The property this spec exists for is a sequencing asymmetry:
//
//     `pauseSpends` extends `activationAt` by its duration ONLY IF an upgrade
//     is already pending.
//
// So `queue; pause` and `pause; queue` reach different `activationAt` from
// identical inputs - in the second, the one-shot pause is spent without
// protecting the window it was presumably meant to protect. No single-call
// proof can see that, and an invariant checked at the end of a fuzz run cannot
// either: both orderings end with a pending upgrade and a used latch.
//
// The exit window is the protocol's headline safety guarantee - holders can
// leave before a changed implementation takes effect - so the arithmetic that
// sets its end deserves a model.
//
// ABSTRACTED, and why
//
//   - The implementation behind the proxy. `implVersion` is `version()` read
//     through the proxy, so it is 1 or 2 and nothing else. It is modelled
//     because it is the only *observable consequence* of activation: without
//     it, an `activateUpgrade` that cleared the queue without actually calling
//     `upgradeToAndCall` would pass every other check.
//   - Which address is admin. Modelled as an index into a fixed three-address
//     set, so `changeProxyAdmin` is exercised by every later admin call having
//     to come from the new holder.
//   - Caller rejection. There is no `queueNotAdmin` action: who may call is a
//     single-call property the symbolic suite already owns over all addresses,
//     and each extra action dilutes every other action's share of the step
//     budget. `activateTooEarly` is the exception, and stays, because its
//     guard is *time* - state this model computes rather than an input.
module delayed_upgrade_proxy {
  // Must match the driver, which asserts the deployed proxy agrees.
  pure val UPGRADE_DELAY = 2592000   // 30 days
  pure val MAX_PAUSE = 604800        // 7 days

  /// Implementations. 1 = MockPoolV1, 2 = MockPoolV2; 0 = "nothing pending".
  pure val IMPLS = Set(1, 2)
  /// Admin addresses, by index.
  pure val ADMINS = Set(0, 1, 2)

  /// One shared domain for every duration: `advanceTime` moves the clock by it
  /// and `pauseSpends` pauses for it, with the `<= MAX_PAUSE` guard inside the
  /// action. Sharing costs nothing and saves a pick name, which is 64 bytes on
  /// every step whichever action ran.
  ///
  /// UPGRADE_DELAY and MAX_PAUSE are both drawable on purpose: activating
  /// exactly on `activationAt` is the boundary the whole contract is about, and
  /// drawing from a range would reach it with probability near zero.
  /// Three of the seven clear a full window. With only one, activation needed
  /// queue -> that exact draw -> activate with no cancel in between, and fired
  /// 3 times in 488 steps - too rare to floor. UPGRADE_DELAY itself stays in the
  /// set because landing exactly on `activationAt` is the boundary the guard
  /// divides.
  pure val TIME_JUMPS =
    Set(1, 3600, 86400, MAX_PAUSE, UPGRADE_DELAY, UPGRADE_DELAY + 1, 2 * UPGRADE_DELAY)

  /// Seconds since the driver's T0. Relative so the model never carries an
  /// absolute timestamp, and the driver warps to `T0 + nowTs`.
  var nowTs: int
  /// 0 when nothing is queued.
  var pendingImpl: int
  /// 0 when nothing is queued.
  var activationAt: int
  /// Spends are halted while `nowTs < pausedUntil`. Decays on its own; nothing
  /// clears it, not even `resetGuardianPause`.
  var pausedUntil: int
  var guardianPauseUsed: bool
  /// `version()` through the proxy: the observable consequence of activation.
  var implVersion: int
  var admin: int

  // --- ghosts (ignoreState) ---------------------------------------------

  /// When the live queue was created. The contract stores only `activationAt`,
  /// so there is nothing on chain to compare this against - it exists so
  /// `inv_windowNeverShortened` can be stated at all.
  var queuedAt: int
  /// Pause duration that landed while an upgrade was pending, and so extended
  /// the window. Without it, deleting the `pendingImplementation != 0` check in
  /// `pauseSpends` leaves every other invariant satisfied.
  var pausedInWindow: int
  /// The latch, counted a second way. A boolean alone is unconstrained: the
  /// same lesson as `guardViolations` in spec/masp.qnt.
  var pauseFirings: int
  var resetFirings: int
  /// Windows opened. `> 1` means the model exercised more than one window,
  /// which is the only way a cancel-then-requeue is visible in a state
  /// invariant - the contract keeps no history of past queues.
  var queueFirings: int
  /// The implementation the last successful activation promoted. `implVersion`
  /// is read live through the proxy, so comparing the two is what makes an
  /// `activateUpgrade` that clears the queue without actually calling
  /// `upgradeToAndCall` visible.
  var lastActivated: int

  action init = all {
    nowTs' = 0,
    pendingImpl' = 0,
    activationAt' = 0,
    pausedUntil' = 0,
    guardianPauseUsed' = false,
    implVersion' = 1,
    admin' = 0,
    queuedAt' = 0,
    pausedInWindow' = 0,
    pauseFirings' = 0,
    resetFirings' = 0,
    queueFirings' = 0,
    lastActivated' = 1,
  }

  // --- frames -----------------------------------------------------------
  //
  // Quint has no `UNCHANGED`, so every action must assign all thirteen
  // variables and eighty-four of the lines below said only `x' = x`. They are
  // grouped by what they describe rather than by which action writes them: a
  // strict writer-partition needs ten names for thirteen variables here, which
  // is a worse spec, not a better one.
  //
  // The consequence of choosing meaning over writers is that an action writing
  // *part* of a group cannot also frame it, and spells out the rest by hand -
  // `cancelUpgrade` below is the shape. That is deliberate: it keeps a group
  // name honest about what it covers.

  /// The queued upgrade and everything scoped to its window.
  action unchangedUpgradeQueue = all {
    pendingImpl' = pendingImpl,
    activationAt' = activationAt,
    queuedAt' = queuedAt,
    pausedInWindow' = pausedInWindow,
    queueFirings' = queueFirings,
  }

  /// The guardian pause: the deadline, the one-shot latch, and the two counters
  /// that pin the latch to its own history.
  action unchangedPauseLatch = all {
    pausedUntil' = pausedUntil,
    guardianPauseUsed' = guardianPauseUsed,
    pauseFirings' = pauseFirings,
    resetFirings' = resetFirings,
  }

  /// What is actually running behind the proxy. Written by `activateUpgrade`
  /// alone, which is the point: an activation that clears the queue without
  /// promoting anything leaves these two behind.
  action unchangedImpl = all {
    implVersion' = implVersion,
    lastActivated' = lastActivated,
  }

  action unchangedAdmin = admin' = admin

  action unchangedClock = nowTs' = nowTs

  /// `queueUpgrade`. One at a time: replacing a payload needs cancel-then-queue,
  /// which restarts the window from scratch.
  action queueUpgrade = {
    nondet impl = IMPLS.oneOf()
    all {
      pendingImpl == 0,
      pendingImpl' = impl,
      activationAt' = nowTs + UPGRADE_DELAY,
      queuedAt' = nowTs,
      // A fresh window has absorbed no pause yet.
      pausedInWindow' = 0,
      queueFirings' = queueFirings + 1,
      unchangedPauseLatch,
      unchangedImpl,
      unchangedAdmin,
      unchangedClock,
    }
  }

  action cancelUpgrade = all {
    pendingImpl != 0,
    pendingImpl' = 0,
    activationAt' = 0,
    // The rest of the window group, by hand: cancelling writes two of its five.
    queuedAt' = queuedAt,
    pausedInWindow' = pausedInWindow,
    queueFirings' = queueFirings,
    unchangedPauseLatch,
    unchangedImpl,
    unchangedAdmin,
    unchangedClock,
  }

  /// `activateUpgrade`. Permissionless - anyone may push a queued upgrade over
  /// the line once its window has elapsed.
  action activateUpgrade = all {
    pendingImpl != 0,
    nowTs >= activationAt,
    implVersion' = pendingImpl,
    lastActivated' = pendingImpl,
    pendingImpl' = 0,
    activationAt' = 0,
    queuedAt' = queuedAt,
    pausedInWindow' = pausedInWindow,
    queueFirings' = queueFirings,
    unchangedPauseLatch,
    unchangedAdmin,
    unchangedClock,
  }

  /// Negative path: activating inside the window must be rejected with
  /// `NotYetActivatable(activationAt)`. The driver asserts the revert *and its
  /// argument*, so a contract that reported the wrong deadline would diverge.
  action activateTooEarly = all {
    pendingImpl != 0,
    nowTs < activationAt,
    // Writes nothing at all: the whole point is that a rejected call leaves
    // every one of the thirteen variables where it was.
    unchangedUpgradeQueue,
    unchangedPauseLatch,
    unchangedImpl,
    unchangedAdmin,
    unchangedClock,
  }

  /// `pauseSpends`. The asymmetry this spec exists for is the `pendingImpl != 0`
  /// condition on the window extension: a pause with nothing queued halts spends
  /// and burns the one-shot latch, but protects no window.
  action pauseSpends = {
    nondet dt = TIME_JUMPS.oneOf()
    all {
      not(guardianPauseUsed),
      dt > 0,
      dt <= MAX_PAUSE,
      guardianPauseUsed' = true,
      pausedUntil' = nowTs + dt,
      pauseFirings' = pauseFirings + 1,
      resetFirings' = resetFirings,
      activationAt' = if (pendingImpl != 0) activationAt + dt else activationAt,
      pausedInWindow' = if (pendingImpl != 0) pausedInWindow + dt else pausedInWindow,
      pendingImpl' = pendingImpl,
      queuedAt' = queuedAt,
      queueFirings' = queueFirings,
      unchangedImpl,
      unchangedAdmin,
      unchangedClock,
    }
  }

  /// `resetGuardianPause` clears the latch but NOT `pausedUntil` - an in-flight
  /// pause runs to its end, and a second pause can then extend past it.
  action resetGuardianPause = all {
    guardianPauseUsed' = false,
    // Counts *effective* resets only. An idempotent reset must not move the
    // counter, or `inv_latchMatchesCounters` below could not pin the latch.
    resetFirings' = if (guardianPauseUsed) resetFirings + 1 else resetFirings,
    // `pausedUntil` deliberately survives: clearing the latch does not end an
    // in-flight pause, which is the asymmetry this action exists to model.
    pausedUntil' = pausedUntil,
    pauseFirings' = pauseFirings,
    unchangedUpgradeQueue,
    unchangedImpl,
    unchangedAdmin,
    unchangedClock,
  }

  action changeProxyAdmin = {
    nondet who = ADMINS.oneOf()
    all {
      admin' = who,
      unchangedUpgradeQueue,
      unchangedPauseLatch,
      unchangedImpl,
      unchangedClock,
    }
  }

  action advanceTime = {
    nondet dt = TIME_JUMPS.oneOf()
    all {
      nowTs' = nowTs + dt,
      unchangedUpgradeQueue,
      unchangedPauseLatch,
      unchangedImpl,
      unchangedAdmin,
    }
  }

  action step = any {
    queueUpgrade,
    cancelUpgrade,
    activateUpgrade,
    activateTooEarly,
    pauseSpends,
    resetGuardianPause,
    changeProxyAdmin,
    advanceTime,
  }

  // --- invariants -------------------------------------------------------

  /// The two halves of a queue are written and cleared together.
  ///
  /// An arithmetic consequence of the transitions here; its value is in the
  /// replay, where both sides come from `pendingUpgrade()` on the real proxy.
  val inv_pendingIffActivation = (pendingImpl == 0) == (activationAt == 0)

  /// The exit window is exactly the delay from the queue plus every pause that
  /// landed inside it.
  ///
  /// The contract's headline claim, and the one property that needs a ghost to
  /// state. An *equality* rather than a lower bound on purpose: `>=` is
  /// satisfied by a window that was lengthened without being recorded, so it
  /// misses an extension applied when none was due - which is the exact
  /// mutation this spec exists to catch.
  val inv_windowIsExact =
    pendingImpl == 0 or activationAt == queuedAt + UPGRADE_DELAY + pausedInWindow

  /// A pause never runs longer than the permitted maximum.
  val inv_pauseBounded = pausedUntil == 0 or pausedUntil <= nowTs + MAX_PAUSE

  /// The latch is one-shot between resets, and its live value agrees with the
  /// counts. The bound alone is too weak: a reset that failed to clear the
  /// latch satisfies it, because the counter still moves.
  val inv_pauseOneShot = pauseFirings - resetFirings <= 1
  val inv_latchMatchesCounters = guardianPauseUsed == (pauseFirings == resetFirings + 1)

  /// What the proxy serves is what the last activation promoted.
  val inv_implFollowsActivation = implVersion == lastActivated

  /// The served implementation only ever becomes something that was queued.
  val inv_implIsAnImplementation = IMPLS.contains(implVersion)

  val allInvariants = and {
    inv_pendingIffActivation,
    inv_windowIsExact,
    inv_pauseBounded,
    inv_pauseOneShot,
    inv_latchMatchesCounters,
    inv_implFollowsActivation,
    inv_implIsAnImplementation,
  }

  // --- witnesses --------------------------------------------------------

  /// THE target. A pause fired with nothing queued, so the latch was spent
  /// without protecting any window - and a later queue got no extension for it.
  /// A run that never reaches this has not tested the thing this spec is for.
  val wit_pauseBeforeQueue = guardianPauseUsed and pendingImpl == 0

  /// The other ordering: a pause that did extend a live window.
  val wit_pauseDuringWindow = pausedInWindow > 0

  /// Activation exactly on the boundary block, which is the edge the guard
  /// divides rather than either side of it.
  val wit_activatedAtBoundary = pendingImpl != 0 and nowTs == activationAt

  /// Pause, reset, pause again - the latch cycle.
  val wit_relatch = pauseFirings > 1

  /// More than one window was opened, so a cancel-or-activate was followed by a
  /// fresh queue starting the delay again from scratch.
  val wit_requeued = queueFirings > 1

  /// An upgrade actually landed - without this the whole spec could pass while
  /// never once activating anything.
  val wit_activated = implVersion == 2
}
