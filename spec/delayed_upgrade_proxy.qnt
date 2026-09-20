// Model of `DelayedUpgradeProxy` (src/DelayedUpgradeProxy.sol) and the
// ERC-7201 slot it keeps in `src/UpgradeStorage.sol`.
//
// Replayed against a real proxy over MockPoolV1/V2 by
// test/quint/DelayedUpgradeProxyReplay.t.sol.
//
// SCOPE
//
// test/symbolic/DelayedUpgradeProxy.symbolic.t.sol proves single-call
// properties over all inputs: activation happens exactly after the window, a
// queued payload cannot be swapped, pauses chain with each deferring the
// window, non-admins are rejected. This spec covers sequencing, in particular
// the two paths by which paused time is kept out of the window:
//
//     `pauseSpends` extends `activationAt` by its duration only if an upgrade
//     is already pending; `queueUpgrade` starts the window at
//     `max(now, pausedUntil)`, absorbing whatever pause is still running.
//
// `queue; pause` takes the first path and `pause; queue` the second. Before the
// second existed, a pause issued ahead of the queue, or running across a cancel
// and re-queue, spent its remaining duration inside the new window. Neither a
// single-call proof nor an end-of-run invariant distinguishes the orderings,
// since both end with a pending upgrade and a used latch;
// `inv_exitWindowIsUnpaused` states what both must preserve, by counting the
// unpaused seconds the window actually contained.
//
// The exit window, during which holders can leave before a changed
// implementation takes effect, is the protocol's primary upgrade safety
// guarantee; this arithmetic determines when it ends.
//
// ABSTRACTED
//
//   - The implementation behind the proxy. `implVersion` is `version()` read
//     through the proxy, so it is 1 or 2. It is modelled as the observable
//     consequence of activation: without it, an `activateUpgrade` that clears
//     the queue without calling `upgradeToAndCall` passes every other check.
//   - Admin identity. Modelled as an index into a fixed three-address set, so
//     every admin call after `changeProxyAdmin` must come from the new holder.
//   - Caller rejection. There is no `queueNotAdmin` action: caller
//     authorization is a single-call property covered by the symbolic suite
//     over all addresses, and each extra action reduces every other action's
//     share of the step budget. `activateTooEarly` is included because its
//     guard depends on time, which is model state rather than an input.
module delayed_upgrade_proxy {
  // Must match the driver, which asserts the deployed proxy agrees.
  pure val UPGRADE_DELAY = 2592000   // 30 days
  pure val MAX_PAUSE = 604800        // 7 days
  // The proxy constructor refuses `MAX_PAUSE >= UPGRADE_DELAY`
  // (`PauseNotShorterThanDelay`), so constants outside this relation describe
  // no deployable proxy. Checked as part of `allInvariants`.
  pure val inv_constantsAreDeployable = MAX_PAUSE < UPGRADE_DELAY

  /// Implementations. 1 = MockPoolV1, 2 = MockPoolV2; 0 = "nothing pending".
  pure val IMPLS = Set(1, 2)
  /// Admin addresses, by index.
  pure val ADMINS = Set(0, 1, 2)

  /// Shared domain for every duration: `advanceTime` moves the clock by it and
  /// `pauseSpends` pauses for it, with the `<= MAX_PAUSE` guard inside the
  /// action. One pick name instead of two saves 64 bytes on every trace step.
  ///
  /// UPGRADE_DELAY and MAX_PAUSE are drawable so the activation boundary
  /// (`nowTs == activationAt`) and the maximum pause are reached exactly; a
  /// range would reach them with probability near zero. Three of the seven
  /// values clear a full window, so queue-then-activate sequences occur often
  /// enough to meet coverage floors.
  pure val TIME_JUMPS =
    Set(1, 3600, 86400, MAX_PAUSE, UPGRADE_DELAY, UPGRADE_DELAY + 1, 2 * UPGRADE_DELAY)

  /// Seconds since the driver's T0. Relative so the model never carries an
  /// absolute timestamp, and the driver warps to `T0 + nowTs`.
  var nowTs: int
  /// 0 when nothing is queued.
  var pendingImpl: int
  /// 0 when nothing is queued.
  var activationAt: int
  /// Spends are halted while `nowTs < pausedUntil`. Expires with time; nothing
  /// clears it early.
  var pausedUntil: int
  /// `version()` through the proxy: the observable consequence of activation.
  var implVersion: int
  var admin: int

  // --- ghosts (ignoreState) ---------------------------------------------

  /// When the live queue was created. The contract stores only `activationAt`,
  /// so this has no on-chain counterpart; it is needed to state
  /// `inv_windowIsExact`.
  var queuedAt: int
  /// Total pause duration applied while an upgrade was pending, i.e. the
  /// window extension. Without it, deleting the `pendingImplementation != 0`
  /// check in `pauseSpends` satisfies every other invariant.
  var pausedInWindow: int
  /// Pause still to run when the live queue was created, which `queueUpgrade`
  /// adds to the window. Without it `inv_windowIsExact` could state only a
  /// lower bound, and a queue that deferred by the whole pause as issued rather
  /// than by its remainder would pass.
  var carriedPause: int
  /// Unpaused seconds the clock has spent inside the live window, from the
  /// queue up to `min(nowTs, activationAt)`. Accumulated by `advanceTime`, the
  /// only action that moves the clock. Stated independently of both deferral
  /// paths, so `inv_exitWindowIsUnpaused` holds whichever one fires.
  var unpausedInWindow: int
  /// Pauses applied. `pauseSpends` is repeatable, so this is what shows a
  /// trace exercised more than one, which `inv_windowIsExact` then pins.
  var pauseFirings: int
  /// Windows opened. `> 1` shows more than one window was exercised; the
  /// contract keeps no history of past queues, so this is the only state in
  /// which a cancel-then-requeue is visible.
  var queueFirings: int
  /// The implementation promoted by the last successful activation.
  /// `implVersion` is read live through the proxy, so comparing the two detects
  /// an `activateUpgrade` that clears the queue without calling
  /// `upgradeToAndCall`.
  var lastActivated: int

  action init = all {
    nowTs' = 0,
    pendingImpl' = 0,
    activationAt' = 0,
    pausedUntil' = 0,
    implVersion' = 1,
    admin' = 0,
    queuedAt' = 0,
    pausedInWindow' = 0,
    carriedPause' = 0,
    unpausedInWindow' = 0,
    pauseFirings' = 0,
    queueFirings' = 0,
    lastActivated' = 1,
  }

  // --- frames -----------------------------------------------------------
  //
  // Quint has no `UNCHANGED`, so every action assigns all thirteen variables.
  // The frame actions below group the `x' = x` assignments by what the
  // variables describe rather than by which action writes them; a strict
  // writer-partition would need more groups than it saves.
  //
  // An action that writes part of a group cannot use that group's frame and
  // assigns the remaining members explicitly (see `cancelUpgrade`), so each
  // group name covers exactly its members.

  /// The queued upgrade and everything scoped to its window.
  action unchangedUpgradeQueue = all {
    pendingImpl' = pendingImpl,
    activationAt' = activationAt,
    queuedAt' = queuedAt,
    pausedInWindow' = pausedInWindow,
    carriedPause' = carriedPause,
    unpausedInWindow' = unpausedInWindow,
    queueFirings' = queueFirings,
  }

  /// The pause deadline and the count of pauses applied.
  action unchangedPause = all {
    pausedUntil' = pausedUntil,
    pauseFirings' = pauseFirings,
  }

  /// The implementation running behind the proxy. Written only by
  /// `activateUpgrade`, so an activation that clears the queue without
  /// promoting an implementation leaves these two unchanged.
  action unchangedImpl = all {
    implVersion' = implVersion,
    lastActivated' = lastActivated,
  }

  action unchangedAdmin = admin' = admin

  action unchangedClock = nowTs' = nowTs

  /// `queueUpgrade`. One pending upgrade at a time: replacing a payload requires
  /// cancel-then-queue, which restarts the window.
  ///
  /// The window starts when spends reopen, `max(nowTs, pausedUntil)`, so a
  /// pause still running at queue time defers activation by its remainder. An
  /// expired pause defers nothing.
  action queueUpgrade = {
    nondet impl = IMPLS.oneOf()
    val remaining = if (pausedUntil > nowTs) pausedUntil - nowTs else 0
    all {
      pendingImpl == 0,
      pendingImpl' = impl,
      activationAt' = nowTs + remaining + UPGRADE_DELAY,
      queuedAt' = nowTs,
      carriedPause' = remaining,
      // A fresh window has absorbed no pause and counted no time yet.
      pausedInWindow' = 0,
      unpausedInWindow' = 0,
      queueFirings' = queueFirings + 1,
      unchangedPause,
      unchangedImpl,
      unchangedAdmin,
      unchangedClock,
    }
  }

  action cancelUpgrade = all {
    pendingImpl != 0,
    pendingImpl' = 0,
    activationAt' = 0,
    // Remaining members of the upgrade-queue group; cancelling writes two of seven.
    queuedAt' = queuedAt,
    pausedInWindow' = pausedInWindow,
    carriedPause' = carriedPause,
    unpausedInWindow' = unpausedInWindow,
    queueFirings' = queueFirings,
    unchangedPause,
    unchangedImpl,
    unchangedAdmin,
    unchangedClock,
  }

  /// `activateUpgrade`. Permissionless: any caller may activate a queued upgrade
  /// once its window has elapsed.
  action activateUpgrade = all {
    pendingImpl != 0,
    nowTs >= activationAt,
    implVersion' = pendingImpl,
    lastActivated' = pendingImpl,
    pendingImpl' = 0,
    activationAt' = 0,
    queuedAt' = queuedAt,
    pausedInWindow' = pausedInWindow,
    carriedPause' = carriedPause,
    unpausedInWindow' = unpausedInWindow,
    queueFirings' = queueFirings,
    unchangedPause,
    unchangedAdmin,
    unchangedClock,
  }

  /// Negative path: activation inside the window reverts with
  /// `NotYetActivatable(activationAt)`. The driver asserts the revert and its
  /// argument, so a wrong reported deadline diverges.
  action activateTooEarly = all {
    pendingImpl != 0,
    nowTs < activationAt,
    // A rejected call leaves all thirteen variables unchanged.
    unchangedUpgradeQueue,
    unchangedPause,
    unchangedImpl,
    unchangedAdmin,
    unchangedClock,
  }

  /// `pauseSpends`. The window is extended only when `pendingImpl != 0`: a pause
  /// with nothing queued halts spends, and a later `queueUpgrade` defers by
  /// whatever of it is still running.
  ///
  /// Always enabled: each call is capped at `MAX_PAUSE` but nothing bounds how
  /// many may be made, so a chain of pauses is a reachable state and the
  /// window arithmetic must survive it.
  action pauseSpends = {
    nondet dt = TIME_JUMPS.oneOf()
    all {
      dt > 0,
      dt <= MAX_PAUSE,
      pausedUntil' = nowTs + dt,
      pauseFirings' = pauseFirings + 1,
      activationAt' = if (pendingImpl != 0) activationAt + dt else activationAt,
      pausedInWindow' = if (pendingImpl != 0) pausedInWindow + dt else pausedInWindow,
      pendingImpl' = pendingImpl,
      queuedAt' = queuedAt,
      carriedPause' = carriedPause,
      // Pausing moves no clock; the pause is excluded as `advanceTime` crosses it.
      unpausedInWindow' = unpausedInWindow,
      queueFirings' = queueFirings,
      unchangedImpl,
      unchangedAdmin,
      unchangedClock,
    }
  }

  action changeProxyAdmin = {
    nondet who = ADMINS.oneOf()
    all {
      admin' = who,
      unchangedUpgradeQueue,
      unchangedPause,
      unchangedImpl,
      unchangedClock,
    }
  }

  /// Moves the clock and, with an upgrade pending, credits the window with the
  /// unpaused part of the interval it crosses. Pauses always start at the
  /// current time, so the paused part of `[nowTs, end]` is a prefix ending at
  /// `pausedUntil`. Time past `activationAt` is not credited.
  action advanceTime = {
    nondet dt = TIME_JUMPS.oneOf()
    val end = if (nowTs + dt < activationAt) nowTs + dt else activationAt
    val pausedEnd = if (pausedUntil < nowTs) nowTs else if (pausedUntil > end) end else pausedUntil
    val credited = if (pendingImpl != 0 and end > nowTs) end - pausedEnd else 0
    all {
      nowTs' = nowTs + dt,
      unpausedInWindow' = unpausedInWindow + credited,
      pendingImpl' = pendingImpl,
      activationAt' = activationAt,
      queuedAt' = queuedAt,
      pausedInWindow' = pausedInWindow,
      carriedPause' = carriedPause,
      queueFirings' = queueFirings,
      unchangedPause,
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
    changeProxyAdmin,
    advanceTime,
  }

  // --- invariants -------------------------------------------------------

  /// The two halves of a queue are written and cleared together.
  ///
  /// Follows arithmetically from the transitions; the check is meaningful in the
  /// replay, where both sides come from `pendingUpgrade()` on the real proxy.
  val inv_pendingIffActivation = (pendingImpl == 0) == (activationAt == 0)

  /// The exit window equals the delay from queueing, plus the pause still
  /// running at queue time, plus every pause applied inside it.
  ///
  /// Stated as an equality rather than a lower bound: `>=` admits a window
  /// extended when no extension was due, which is the mutation this spec
  /// targets.
  val inv_windowIsExact =
    pendingImpl == 0 or activationAt == queuedAt + carriedPause + UPGRADE_DELAY + pausedInWindow

  /// Once a window has closed, it contained at least `UPGRADE_DELAY` unpaused
  /// seconds: holders had the full exit however pauses and queues interleaved.
  ///
  /// A lower bound, since overlapping pauses are each credited to the window
  /// in full. The exact arithmetic is `inv_windowIsExact`; this states what the
  /// arithmetic is for, and fails for a queue that ignores a running pause.
  val inv_exitWindowIsUnpaused =
    pendingImpl == 0 or nowTs < activationAt or unpausedInWindow >= UPGRADE_DELAY

  /// No window credits more time than has passed since it opened.
  val inv_unpausedWithinElapsed = pendingImpl == 0 or unpausedInWindow <= nowTs - queuedAt

  /// A pause never runs longer than the permitted maximum.
  val inv_pauseBounded = pausedUntil == 0 or pausedUntil <= nowTs + MAX_PAUSE

  /// What the proxy serves is what the last activation promoted.
  val inv_implFollowsActivation = implVersion == lastActivated

  /// The served implementation is always one of IMPLS.
  val inv_implIsAnImplementation = IMPLS.contains(implVersion)

  val allInvariants = and {
    inv_constantsAreDeployable,
    inv_pendingIffActivation,
    inv_windowIsExact,
    inv_exitWindowIsUnpaused,
    inv_unpausedWithinElapsed,
    inv_pauseBounded,
    inv_implFollowsActivation,
    inv_implIsAnImplementation,
  }

  // --- witnesses --------------------------------------------------------

  /// Primary target: a live window was queued while a pause was still running,
  /// so `queueUpgrade` rather than `pauseSpends` kept the paused time out of it.
  /// A run that never reaches this state has not exercised the ordering this
  /// spec covers.
  val wit_pauseBeforeQueue = pendingImpl != 0 and carriedPause > 0

  /// The other ordering: a pause that extended a live window.
  val wit_pauseDuringWindow = pausedInWindow > 0

  /// The clock is exactly on `activationAt` with an upgrade pending, so
  /// activation is enabled at the boundary the guard divides.
  val wit_activatedAtBoundary = pendingImpl != 0 and nowTs == activationAt

  /// Pause, reset, pause again: the latch cycle.
  val wit_relatch = pauseFirings > 1

  /// More than one window was opened: a cancel or activation followed by a
  /// fresh queue that restarts the delay.
  val wit_requeued = queueFirings > 1

  /// The proxy serves MockPoolV2, so at least one activation took effect.
  /// Without this the spec could pass without ever activating.
  val wit_activated = implVersion == 2
}
