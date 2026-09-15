// Model of `FeeBurner`'s reverse Dutch auction (src/burn/FeeBurner.sol).
//
// Replayed against a real burner by test/quint/FeeBurnerReplay.t.sol.
//
// SCOPE
//
// test/symbolic/README.md notes that division of a symbolic product is
// intractable for the symbolic tooling, so no accepting path is proven there.
// `buy` concentrates that arithmetic:
//
//   govIn      = ceil(amountOut * price / 1e18)
//   fillBps    = floor(amountOut * BPS / bal)
//   mult       = BPS + floor((restartMultBps - BPS) * fillBps / BPS)
//   startPrice = floor(price * mult / BPS)
//   burned     = floor(govIn * burnBps / BPS)
//
// Five roundings, four of them floors, applied to the `startPrice` and
// `startedAt` written by the previous `buy`. The price follows a sawtooth: it
// decays with time and jumps up on each fill, weighted by the share of the lot
// the fill took. That shape exists only across steps, so neither a single-call
// proof nor an end-of-run invariant observes it.
//
// Two rules decide whether a fill moves the sawtooth at all, and both are
// cross-step properties:
//
//   - A fill re-anchors (rewrites `startPrice`, `startedAt` and the lot's curve
//     snapshot) only if `amountOut >= minLot` and `mult > BPS`. A clearing fill
//     below `minLot` is a full fill against a balance anyone can donate to, and
//     a zero-weight fill would only restart decay; neither may touch the clock.
//   - The decay curve a lot runs on is the `(halfLife, maxHalvings)` snapshot
//     taken when it was set or last re-anchored, not the globals, so
//     `setDecayParams` never reprices time a lot has already spent decaying.
//     The price is not projected, but it reaches the chain through `govIn`: a
//     burner that priced off the globals diverges on `bidderGov` at the next
//     fill after a change.
//
// DOMAIN
//
// spec/masp.qnt notes that its fee rounding is unobservable because its asset
// scale of 1e10 is a multiple of BPS, making every division exact. The same
// applies to each of the five divisions here, so every constant below is chosen
// to make the division inexact:
//
//   - SEED_PRICE is not a multiple of 1e18 and is odd, so `ceil` differs from
//     `floor` in `govIn` and `startPrice >> periods` loses bits.
//   - RESTART_MULT_BPS is 17_777, not 20_000: with 20_000 the term
//     `(restartMultBps - BPS) * fillBps / BPS` is exactly `fillBps` and the
//     rounding vanishes.
//   - BURN_BPS is 6_667, not 10_000: with 10_000 the split is exact and the
//     remainder is always zero.
//   - TIME_JUMPS are mostly not multiples of HALF_LIFE, so `elapsed % period`
//     is non-zero and the linear interpolation inside a period actually runs.
//   - AMOUNTS are chosen so `amountOut * BPS % bal != 0`, so the floor in
//     `fillBps` is observable. `1` and `7` are below MIN_LOT: they build dust
//     balances, which `buy` clears by drawing the whole balance. `1009` is
//     exactly MIN_LOT, and against a balance holding `10000019` its share is
//     one basis point, whose ratchet term floors to zero. Both paths that must
//     not re-anchor are therefore reached.
//
// Each choice is validated by fault injection: flipping the corresponding
// operation in the contract must make the replay fail. If it does not, the
// domain is exact where it should be inexact.
//
// ABSTRACTED
//
//   - `harvest` and the pool. The burner needs no pool unless `harvest` is
//     modelled, and `harvest` ignores the outcome of every call it makes.
//   - `burnAccruedGov`, `rescue`, `setPools`, `setSecondaryTreasury`. Owner
//     configuration and a cleanup path covered by
//     test/burn/FeeBurner.invariant.t.sol (`invariant_burnerHoldsNoGov`).
//   - `minLot` is one constant, MIN_LOT, and `setLot`'s `BadMinLot` rejection
//     of zero is not modelled. The `BelowMinLot` revert is only a guard here:
//     replay drives accepted steps, so the rejection itself is a single-call
//     property left to test/burn/FeeBurner.t.sol.
//   - `restartMultBps` is held at RESTART_MULT_BPS; `setDecayParams` draws only
//     the two parameters a lot snapshots. The `restartMultBps == BPS` case is
//     covered by `test_unitRestartMultiplierNeverReanchors`, and a zero-weight
//     fill is reached here through a large balance instead.
//   - Multiple lot tokens. One token is modelled; lots are independent per
//     token.
module fee_burner {
  pure val BPS = 10000
  pure val PRICE_SCALE = 1000000000000000000  // 1e18

  // Must match the driver, which asserts the deployed burner agrees.
  pure val HALF_LIFE = 3600
  pure val MAX_HALVINGS = 12
  pure val RESTART_MULT_BPS = 17777
  /// Dust floor. Above two of AMOUNTS, so dust balances form, and equal to a
  /// third, so a fill of exactly the floor is drawn.
  pure val MIN_LOT = 1009
  pure val BURN_BPS = 6667
  /// ~1.234e18. Odd, and not a multiple of 1e18.
  pure val SEED_PRICE = 1234567890123456789
  /// Above `SEED_PRICE >> MAX_HALVINGS` (~3.01e14), so the floor binds once
  /// decay clamps. A lower value would leave the `p < minPrice` branch
  /// unreachable in every trace.
  pure val MIN_PRICE = 400000000000000  // 4e14

  /// The bidder's starting balance. `bidderGov` moves only by `govIn`, so the
  /// composite rounding is compared directly rather than inferred (the same
  /// approach as `payerBalance` in spec/masp.qnt).
  pure val BIDDER_START = 100000000000000000000000  // 100_000e18
  /// LelantosToken's fixed supply, minted once at construction.
  pure val GOV_SUPPLY = 1000000000000000000000000000  // 1e9 * 1e18

  /// Fee-token amounts, for both `accrueFees` and `buy`. Chosen so
  /// `amountOut * BPS` rarely divides `bal`.
  ///
  /// Over 300 traces at 80 steps a dust clear on a running clock is reached in
  /// 52% of traces and a zero-weight fill in 56%. With MIN_LOT at 7 and a
  /// fourth amount of 100003, a dust clear needs a balance of exactly 1 and is
  /// reached in 12%. The cost is fills: a sub-floor draw against a large
  /// balance is rejected, so `buy` runs on fewer steps, which `maxSteps` in
  /// the config absorbs.
  pure val AMOUNTS = Set(1, 7, 1009, 10000019)

  /// Mostly not multiples of HALF_LIFE, so the mid-period interpolation runs.
  /// 3600 makes the exact-boundary case reachable, and 50000 exceeds
  /// MAX_HALVINGS * HALF_LIFE = 43200 so the clamp branch is reached.
  pure val TIME_JUMPS = Set(1, 1000, 3600, 7300, 50000)

  /// Global decay curves for `setDecayParams`, indexed by a QUARTERS draw.
  /// Index 0 is the constructor's curve, so governance can return to it. The
  /// others differ in both fields: a shorter half-life with fewer halvings, so
  /// the clamp is reached inside one `wait`; a longer one whose clamp sits
  /// below MIN_PRICE, so the floor binds; and a short half-life with the same
  /// halvings, where applying it retroactively would drop the price furthest.
  pure val DECAY_HALF_LIVES = [3600, 1000, 7300, 600]
  pure val DECAY_MAX_HALVINGS = [12, 3, 16, 12]

  /// The biased draw behind the `setLot` and `setPaused` flags, and the index
  /// into the decay curves.
  ///
  /// Every action draws exactly one number named `p` from its domain (AMOUNTS,
  /// TIME_JUMPS or QUARTERS) and renames it locally. A trace step carries a
  /// 64-byte slot for every distinct pick name in the spec regardless of which
  /// action ran, so a single shared name keeps fixtures small.
  ///
  /// A uniform bool on each of the two gates would block `buy`, the accepting
  /// path under test, three quarters of the time. Deriving the flags from a
  /// quarters draw enables the lot 3/4 of the time and pauses the burner 1/4 of
  /// the time: both states and both rejection guards are still exercised, and
  /// the fill arithmetic is reached far more often.
  pure val QUARTERS = Set(0, 1, 2, 3)

  /// Powers of two up to the largest of DECAY_MAX_HALVINGS, for the `>>` in
  /// the decay curve. The clamp means no larger shift is ever needed.
  pure val POW2 = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]

  var nowTs: int
  var lotEnabled: bool
  var startedAt: int
  var startPrice: int
  var minPrice: int
  var paused: bool
  /// token.balanceOf(burner)
  var burnerTokenBal: int
  /// GOV held by the burner. Zero after every buy: the split sends all of it
  /// out.
  var burnerGovBal: int
  var govSupply: int
  var bidderGov: int
  var secondaryGov: int
  /// The global decay curve, `burner.halfLife()` and `burner.maxHalvings()`.
  var halfLife: int
  var maxHalvings: int
  /// The curve the lot runs on, snapshotted from the globals by `setLot` and by
  /// a re-anchoring fill.
  var lotHalfLife: int
  var lotMaxHalvings: int

  // --- ghosts (ignoreState) ---------------------------------------------

  /// GOV burned, accumulated independently of `govSupply`, which is read live
  /// from `totalSupply()`. Monotonicity alone would be satisfied by a burn of
  /// the wrong amount.
  var burnedTotal: int
  /// GOV paid in, accumulated independently of `bidderGov`.
  var govInTotal: int
  /// Fills, so a run that never bought anything is visible.
  var fillCount: int
  /// Counts fills whose ratchet left `startPrice` below the clearing price.
  /// `restartMultBps >= BPS` makes that impossible.
  var ratchetViolations: int
  /// Sum of `amountOut * price` over fills, in price-scale units. Paired with
  /// `govInTotal` it brackets the rounding: `ceil` puts each `govIn` in
  /// `[cost/1e18, cost/1e18 + 1)`, which a floor does not satisfy.
  var costBasis: int
  /// Fee tokens sold and received, tracked separately from the balance so a
  /// buy that omits the debit, or an accrual that omits the credit, breaks the
  /// identity rather than moving both sides together.
  var soldTotal: int
  var accruedTotal: int
  /// Time advanced, tracked independently of the clock.
  var timeAdvanced: int
  /// When the lot was last (re)started, by a fill or by `setLot`. Both write
  /// `startedAt`, so this pins it without restating either.
  var lastTouchAt: int
  /// Fills whose ratchet term survives flooring yet did not raise the asking
  /// price. The ratchet makes that impossible.
  var flatRatchets: int
  /// Fills split by the share of the lot they took: under a tenth, and at
  /// least half. The ratchet interpolates between `BPS` and `restartMultBps`
  /// on that share, so a trace set with only one fill size never varies `mult`
  /// and cannot distinguish the interpolation from a constant.
  ///
  /// Bands rather than endpoints: `fillBps == BPS` requires `amt` to equal the
  /// balance exactly, which the amount domain reaches in 7.6% of traces, too
  /// rarely for a coverage floor.
  var smallFills: int
  var largeFills: int
  /// Waits that moved the clock forward inside the decaying region but left the
  /// asking price unchanged. Counted by comparing the curve at two clocks rather
  /// than by restating the decay expression: every other invariant reads the
  /// price through the same `priceAt`, so a curve with the interpolation term
  /// dropped satisfies all of them.
  var flatDecays: int
  /// Fills below MIN_LOT, admitted only because they clear the balance, that
  /// ran after the lot's clock had started. A re-anchor there would move
  /// `startedAt` on chain, so the replay compares a kept clock against one a
  /// size-blind ratchet would have restarted.
  var dustClearsMidDecay: int
  /// Fills of at least MIN_LOT whose ratchet term floored to zero, after the
  /// lot's clock had started: the other path that must not re-anchor.
  var zeroWeightFillsMidDecay: int
  /// Fills that did not re-anchor yet left the asking price, read through
  /// `priceAt` at the same clock, different from the price they cleared at.
  var unanchoredPriceMoves: int
  /// Fills below MIN_LOT that re-anchored. The guard makes that impossible.
  var dustReanchors: int
  /// Fills on a lot whose curve snapshot differs from the globals, after its
  /// clock had started. Only these tell a burner that prices off the snapshot
  /// from one that prices off the globals, through `govIn`.
  var staleCurveFills: int

  // --- the decay curve --------------------------------------------------

  pure def shr(x: int, n: int): int = x / POW2[n]

  /// `_priceOf`, restated exactly. `mulDiv(a, b, c)` is `(a * b) / c` here
  /// because Quint integers do not overflow, and overflow safety is the only
  /// difference between mulDiv and the naive expression.
  ///
  /// Parametrised on the clock rather than reading `nowTs`, so `wait` can
  /// compute the price after the jump it is about to take and `flatDecays` can
  /// compare two points on the curve.
  ///
  /// Takes the curve as arguments: the lot's snapshot, never the globals.
  pure def priceAt(en: bool, sAt: int, sPrice: int, mPrice: int, hl: int, mh: int, t: int): int =
    if (not(en)) 0
    else
      val elapsed = t - sAt
      val periods = elapsed / hl
      val p =
        if (periods >= mh) shr(sPrice, mh)
        else
          val base = shr(sPrice, periods)
          val rem = elapsed % hl
          base - ((shr(base, 1) * rem) / hl)
      if (p < mPrice) mPrice else p

  def priceNow: int = priceAt(lotEnabled, startedAt, startPrice, minPrice, lotHalfLife, lotMaxHalvings, nowTs)

  pure def ceilDiv(a: int, b: int): int = (a + b - 1) / b

  action init = all {
    nowTs' = 0,
    lotEnabled' = false,
    startedAt' = 0,
    startPrice' = 0,
    minPrice' = 0,
    paused' = false,
    burnerTokenBal' = 0,
    burnerGovBal' = 0,
    govSupply' = GOV_SUPPLY,
    bidderGov' = BIDDER_START,
    secondaryGov' = 0,
    // The constructor's curve, which the driver asserts in `setUp`. The lot
    // snapshot is the zero struct until the first `setLot`.
    halfLife' = HALF_LIFE,
    maxHalvings' = MAX_HALVINGS,
    lotHalfLife' = 0,
    lotMaxHalvings' = 0,
    burnedTotal' = 0,
    govInTotal' = 0,
    fillCount' = 0,
    ratchetViolations' = 0,
    flatRatchets' = 0,
    costBasis' = 0,
    soldTotal' = 0,
    accruedTotal' = 0,
    timeAdvanced' = 0,
    lastTouchAt' = 0,
    flatDecays' = 0,
    smallFills' = 0,
    largeFills' = 0,
    dustClearsMidDecay' = 0,
    zeroWeightFillsMidDecay' = 0,
    unanchoredPriceMoves' = 0,
    dustReanchors' = 0,
    staleCurveFills' = 0,
  }

  // --- frames -----------------------------------------------------------
  //
  // Quint has no `UNCHANGED`: every action assigns all thirty-three variables.
  // The frame actions below group the `x' = x` assignments by which actions
  // write them, so each group is a partition: a variable whose set of writers
  // changes must move to another group, which makes the change explicit.
  //
  // Each action lists what it changes and names the frames it leaves alone.

  /// Written only by `wait`.
  action unchangedClock = all {
    nowTs' = nowTs,
    timeAdvanced' = timeAdvanced,
    flatDecays' = flatDecays,
  }

  /// Written only by `setLot`: the parameters of the lot, as opposed to the
  /// auction currently running on it.
  action unchangedLotConfig = all {
    lotEnabled' = lotEnabled,
    minPrice' = minPrice,
  }

  /// Written by `buy` and `setLot`, the two actions that restart the auction.
  /// `lastTouchAt` shadows `startedAt` so both writers are pinned. The curve
  /// snapshot belongs here: it is written exactly when the clock is.
  action unchangedLotClock = all {
    startedAt' = startedAt,
    startPrice' = startPrice,
    lastTouchAt' = lastTouchAt,
    lotHalfLife' = lotHalfLife,
    lotMaxHalvings' = lotMaxHalvings,
  }

  /// Written only by `setDecayParams`.
  action unchangedDecayParams = all {
    halfLife' = halfLife,
    maxHalvings' = maxHalvings,
  }

  /// Written only by `setPaused`.
  action unchangedPauseFlag = paused' = paused

  /// Written by `accrueFees` and `buy`: fees in, lot out.
  action unchangedTokenBal = burnerTokenBal' = burnerTokenBal

  /// Written by no action. `buy` sends all proceeds out in the same call, so
  /// the burner holds no GOV between calls, as `inv_burnerHoldsNoGov` asserts
  /// against the live balance.
  action unchangedGovHeld = burnerGovBal' = burnerGovBal

  /// Written only by `buy`: everything a fill moves, live balances and ghosts
  /// alike, which must change together for a fill to be correct.
  action unchangedFillLedger = all {
    govSupply' = govSupply,
    bidderGov' = bidderGov,
    secondaryGov' = secondaryGov,
    burnedTotal' = burnedTotal,
    govInTotal' = govInTotal,
    fillCount' = fillCount,
    ratchetViolations' = ratchetViolations,
    flatRatchets' = flatRatchets,
    costBasis' = costBasis,
    soldTotal' = soldTotal,
    smallFills' = smallFills,
    largeFills' = largeFills,
    dustClearsMidDecay' = dustClearsMidDecay,
    zeroWeightFillsMidDecay' = zeroWeightFillsMidDecay,
    unanchoredPriceMoves' = unanchoredPriceMoves,
    dustReanchors' = dustReanchors,
    staleCurveFills' = staleCurveFills,
  }

  /// Written only by `accrueFees`.
  action unchangedAccrual = accruedTotal' = accruedTotal

  /// Fee tokens arriving at the burner. In production this is `sweep` paying
  /// the treasury; only the amount is modelled, not the route.
  action accrueFees = {
    nondet p = AMOUNTS.oneOf()
    val amt = p
    all {
      burnerTokenBal' = burnerTokenBal + amt,
      accruedTotal' = accruedTotal + amt,
      unchangedClock,
      unchangedDecayParams,
      unchangedLotConfig,
      unchangedLotClock,
      unchangedPauseFlag,
      unchangedGovHeld,
      unchangedFillLedger,
    }
  }

  /// `buy`. The five roundings above, in order.
  ///
  /// Draws from AMOUNTS or the whole balance. A clearing fill is the only way
  /// a fill below MIN_LOT is admitted, and an amount drawn from AMOUNTS alone
  /// equals the balance too rarely to reach it.
  action buy = {
    nondet p = AMOUNTS.union(Set(burnerTokenBal)).oneOf()
    val amt = p
    val price = priceNow
    val govIn = ceilDiv(amt * price, PRICE_SCALE)
    val fillBps = (amt * BPS) / burnerTokenBal
    val mult = BPS + (((RESTART_MULT_BPS - BPS) * fillBps) / BPS)
    val burned = (govIn * BURN_BPS) / BPS
    // Only a fill of at least MIN_LOT with a non-zero ratchet term re-anchors.
    val reanchors = amt >= MIN_LOT and mult > BPS
    val nextStart = if (reanchors) (price * mult) / BPS else startPrice
    val nextStartedAt = if (reanchors) nowTs else startedAt
    val nextHalfLife = if (reanchors) halfLife else lotHalfLife
    val nextMaxHalvings = if (reanchors) maxHalvings else lotMaxHalvings
    // The asking price right after the fill, at the same clock.
    val postPrice = priceAt(true, nextStartedAt, nextStart, minPrice, nextHalfLife, nextMaxHalvings, nowTs)
    val midDecay = nowTs > startedAt
    all {
      not(paused),
      lotEnabled,
      amt > 0,
      amt <= burnerTokenBal,
      // Dust floor, with the clearing escape.
      amt >= MIN_LOT or amt == burnerTokenBal,
      govIn > 0,
      govIn <= bidderGov,
      burnerTokenBal' = burnerTokenBal - amt,
      startPrice' = nextStart,
      startedAt' = nextStartedAt,
      lastTouchAt' = nextStartedAt,
      lotHalfLife' = nextHalfLife,
      lotMaxHalvings' = nextMaxHalvings,
      bidderGov' = bidderGov - govIn,
      govSupply' = govSupply - burned,
      secondaryGov' = secondaryGov + (govIn - burned),
      burnedTotal' = burnedTotal + burned,
      govInTotal' = govInTotal + govIn,
      fillCount' = fillCount + 1,
      costBasis' = costBasis + (amt * price),
      soldTotal' = soldTotal + amt,
      // The ratchet never leaves the lot cheaper than its clearing price.
      ratchetViolations' =
        if (nextStart < price) ratchetViolations + 1 else ratchetViolations,
      // A fill large enough for the ratchet term to survive flooring must leave
      // the lot above its clearing price. Below that threshold a flat price is
      // correct, since `floor((restartMultBps - BPS) * fillBps / BPS)` is zero
      // for a small share, so the condition is on the term rather than on
      // `fillBps > 0`. Counting exceptions makes a flattened ratchet visible:
      // `newStart == price` violates no bound.
      // Only a fill of at least MIN_LOT is eligible at all.
      flatRatchets' =
        if (amt >= MIN_LOT and fillBps * (RESTART_MULT_BPS - BPS) >= BPS and nextStart <= price)
          flatRatchets + 1
        else flatRatchets,
      smallFills' = if (fillBps * 10 < BPS) smallFills + 1 else smallFills,
      largeFills' = if (fillBps * 2 >= BPS) largeFills + 1 else largeFills,
      dustClearsMidDecay' =
        if (amt < MIN_LOT and midDecay) dustClearsMidDecay + 1 else dustClearsMidDecay,
      zeroWeightFillsMidDecay' =
        if (amt >= MIN_LOT and mult == BPS and midDecay) zeroWeightFillsMidDecay + 1
        else zeroWeightFillsMidDecay,
      // Compares the curve before and after at one clock rather than restating
      // the guard, so a fill that skips the re-anchor but still writes part of
      // the lot is counted.
      unanchoredPriceMoves' =
        if (not(reanchors) and postPrice != price) unanchoredPriceMoves + 1
        else unanchoredPriceMoves,
      dustReanchors' =
        if (amt < MIN_LOT and or {
          nextStart != startPrice,
          nextStartedAt != startedAt,
          nextHalfLife != lotHalfLife,
          nextMaxHalvings != lotMaxHalvings,
        }) dustReanchors + 1
        else dustReanchors,
      staleCurveFills' =
        if (midDecay and (lotHalfLife != halfLife or lotMaxHalvings != maxHalvings))
          staleCurveFills + 1
        else staleCurveFills,
      unchangedClock,
      unchangedDecayParams,
      unchangedLotConfig,
      unchangedPauseFlag,
      unchangedGovHeld,
      unchangedAccrual,
    }
  }

  action wait = {
    nondet p = TIME_JUMPS.oneOf()
    val dt = p
    // The two ends of the jump. Both use `priceAt`; the count below compares
    // them instead of re-deriving either, so it holds for any strictly decaying
    // curve and fails for one that is flat inside the decaying region.
    val before = priceNow
    val after = priceAt(lotEnabled, startedAt, startPrice, minPrice, lotHalfLife, lotMaxHalvings, nowTs + dt)
    all {
      nowTs' = nowTs + dt,
      timeAdvanced' = timeAdvanced + dt,
      // Excludes the two regions where the curve is flat by design: past
      // `maxHalvings` it is constant, and at `minPrice` it has bottomed out.
      // Everywhere else a forward jump must lower the price.
      flatDecays' =
        if (and {
          lotEnabled,
          (nowTs - startedAt) / lotHalfLife < lotMaxHalvings,
          before > minPrice,
          after >= before,
        }) flatDecays + 1
        else flatDecays,
      unchangedDecayParams,
      unchangedLotConfig,
      unchangedLotClock,
      unchangedPauseFlag,
      unchangedTokenBal,
      unchangedGovHeld,
      unchangedFillLedger,
      unchangedAccrual,
    }
  }

  /// `setLot`. Re-seeds the whole struct, restarts the clock and snapshots the
  /// global curve, whether enabling or disabling.
  action setLot = {
    nondet p = QUARTERS.oneOf()
    val on = p > 0
    all {
      lotEnabled' = on,
      // `setLot` overwrites the whole struct in both directions, so the
      // driver passes the same prices whether enabling or disabling.
      startPrice' = SEED_PRICE,
      minPrice' = MIN_PRICE,
      startedAt' = nowTs,
      lastTouchAt' = nowTs,
      lotHalfLife' = halfLife,
      lotMaxHalvings' = maxHalvings,
      unchangedClock,
      unchangedDecayParams,
      unchangedPauseFlag,
      unchangedTokenBal,
      unchangedGovHeld,
      unchangedFillLedger,
      unchangedAccrual,
    }
  }

  action setPaused = {
    nondet p = QUARTERS.oneOf()
    val on = p == 0
    all {
      paused' = on,
      unchangedClock,
      unchangedDecayParams,
      unchangedLotConfig,
      unchangedLotClock,
      unchangedTokenBal,
      unchangedGovHeld,
      unchangedFillLedger,
      unchangedAccrual,
    }
  }

  /// `setDecayParams`, with `restartMultBps` held at RESTART_MULT_BPS. Writes
  /// the globals only: a running lot keeps its snapshot, which is the property
  /// under test.
  action setDecayParams = {
    nondet p = QUARTERS.oneOf()
    all {
      halfLife' = DECAY_HALF_LIVES[p],
      maxHalvings' = DECAY_MAX_HALVINGS[p],
      unchangedClock,
      unchangedLotConfig,
      unchangedLotClock,
      unchangedPauseFlag,
      unchangedTokenBal,
      unchangedGovHeld,
      unchangedFillLedger,
      unchangedAccrual,
    }
  }

  action step = any { accrueFees, buy, wait, setLot, setPaused, setDecayParams }

  // --- invariants -------------------------------------------------------

  /// GOV supply never exceeds its initial value. `govSupply` is read live from
  /// `totalSupply()` on the chain.
  val inv_supplyMonotone = govSupply <= GOV_SUPPLY

  /// Supply falls by exactly what was burned. Monotonicity alone admits a burn
  /// of the wrong size; this pins the amount against a ghost maintained
  /// independently of the live read.
  val inv_supplyExact = govSupply == GOV_SUPPLY - burnedTotal

  /// The bidder paid exactly the sum of the quoted prices; directly checks the
  /// composite rounding in `govIn`.
  val inv_bidderPaidExactly = BIDDER_START - bidderGov == govInTotal

  /// Every GOV that came in either burned or went to the secondary treasury.
  val inv_govInSplitsExactly = govInTotal == burnedTotal + secondaryGov

  /// The burner never sits on GOV: `buy` sends all of it out in the same call.
  val inv_burnerHoldsNoGov = burnerGovBal == 0

  /// A fill never leaves the lot below its clearing price.
  val inv_ratchetNeverLowers = ratchetViolations == 0

  /// The asking price stays inside the band its parameters define.
  val inv_priceWithinBand =
    not(lotEnabled) or (priceNow >= minPrice and priceNow <= startPrice)

  /// `govIn` is a ceiling, not a floor.
  ///
  /// Per fill, `ceil(cost / 1e18)` lies in `[cost/1e18, cost/1e18 + 1)`. Summed,
  /// that brackets the total between the cost basis and the cost basis plus one
  /// unit per fill, a bracket a floor violates as soon as any single division
  /// has a remainder.
  val inv_govInIsCeiling =
    fillCount == 0 or and {
      govInTotal * PRICE_SCALE >= costBasis,
      govInTotal * PRICE_SCALE < costBasis + (fillCount * PRICE_SCALE),
    }

  /// The burn takes its share and no more, within one unit of rounding per fill.
  val inv_burnSplitBounded =
    fillCount == 0 or and {
      burnedTotal * BPS <= govInTotal * BURN_BPS,
      (burnedTotal + fillCount) * BPS > govInTotal * BURN_BPS,
    }

  /// The balance equals fee tokens in minus fee tokens out, tracked separately
  /// so a buy that omits the debit breaks the identity.
  val inv_tokenConservation = burnerTokenBal == accruedTotal - soldTotal

  /// The model clock equals the total time advanced.
  val inv_clockMatchesAdvances = nowTs == timeAdvanced

  /// `startedAt` is when the lot was last restarted, by a fill or by `setLot`,
  /// its two writers.
  val inv_startedAtIsLastTouch = startedAt == lastTouchAt

  /// A fill whose ratchet term survives flooring always leaves the lot above
  /// its clearing price.
  val inv_ratchetAlwaysRaises = flatRatchets == 0

  /// The price strictly falls while the clock runs inside the decaying region.
  ///
  /// The only invariant here that is not an arithmetic consequence of the decay
  /// expression: it compares the curve at two clocks. Deleting the mid-period
  /// interpolation yields a staircase that stays inside the band, above the
  /// floor and below `startPrice`, satisfying every other invariant and
  /// violating only this one.
  val inv_decayStrictlyFalls = flatDecays == 0

  /// A fill below MIN_LOT never rewrites the start price, the clock or the curve
  /// snapshot. Such a fill is a full fill against a balance anyone can donate
  /// to, so a ratchet on it lets a 1-wei donate-and-buy loop double the price
  /// every round.
  val inv_dustNeverReanchors = dustReanchors == 0

  /// A fill that does not re-anchor leaves the asking price where it cleared.
  val inv_unanchoredFillKeepsPrice = unanchoredPriceMoves == 0

  /// The global curve is always one governance can set, and an enabled lot
  /// always runs on one: `setLot` snapshots before any buy can read it.
  val inv_curvesValid = and {
    DECAY_HALF_LIVES.indices().exists(i => DECAY_HALF_LIVES[i] == halfLife and DECAY_MAX_HALVINGS[i] == maxHalvings),
    not(lotEnabled) or DECAY_HALF_LIVES.indices().exists(i =>
      DECAY_HALF_LIVES[i] == lotHalfLife and DECAY_MAX_HALVINGS[i] == lotMaxHalvings
    ),
  }

  val allInvariants = and {
    inv_govInIsCeiling,
    inv_burnSplitBounded,
    inv_tokenConservation,
    inv_clockMatchesAdvances,
    inv_startedAtIsLastTouch,
    inv_ratchetAlwaysRaises,
    inv_decayStrictlyFalls,
    inv_supplyMonotone,
    inv_supplyExact,
    inv_bidderPaidExactly,
    inv_govInSplitsExactly,
    inv_burnerHoldsNoGov,
    inv_ratchetNeverLowers,
    inv_priceWithinBand,
    inv_dustNeverReanchors,
    inv_unanchoredFillKeepsPrice,
    inv_curvesValid,
  }

  // --- witnesses --------------------------------------------------------

  /// Anything was bought at all.
  val wit_filled = fillCount > 0

  /// The lot is partway through a half-life inside the decaying region, so the
  /// linear interpolation inside the period applies. Without this the
  /// `p -= mulDiv(p >> 1, rem, period)` line could be unexercised across the
  /// committed traces.
  val wit_interpolatedMidPeriod =
    lotEnabled and (nowTs - startedAt) % lotHalfLife != 0 and (nowTs - startedAt) < lotHalfLife * lotMaxHalvings

  /// The clamp branch: elapsed time reached `MAX_HALVINGS` half-lives and decay
  /// stopped.
  val wit_decayClampReached =
    lotEnabled and (nowTs - startedAt) / lotHalfLife >= lotMaxHalvings

  /// The price bottomed out at its floor, so an unsold lot is stuck there.
  val wit_floorReached = lotEnabled and priceNow == minPrice

  /// Both fill sizes occurred, so `mult` was interpolated at more than one
  /// point on its range rather than at a single share.
  ///
  /// Reached in 72% of 300 traces at 80 steps. A small fill requires the
  /// balance to be ten times the amount drawn, and the amount domain is shared
  /// with `accrueFees`; the whole-balance draw in `buy` supplies the full fills.
  val wit_partialThenFullFill = smallFills > 0 and largeFills > 0

  /// A burn that left a remainder for the secondary treasury, so the split ran
  /// both ways rather than burning everything.
  val wit_splitBurn = secondaryGov > 0

  /// A clearing fill below MIN_LOT ran on a lot whose clock had started, and
  /// left `startedAt` where it was.
  val wit_dustClearKeptTheClock = dustClearsMidDecay > 0

  /// A fill of at least MIN_LOT with zero ratchet weight left the clock running.
  val wit_zeroWeightFillKeptTheClock = zeroWeightFillsMidDecay > 0

  /// A fill priced a running lot whose curve snapshot differs from the globals,
  /// so its `govIn` tells the snapshot from the globals.
  val wit_boughtOnStaleCurve = staleCurveFills > 0
}
