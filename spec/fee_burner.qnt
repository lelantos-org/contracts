// Model of `FeeBurner`'s reverse Dutch auction (src/burn/FeeBurner.sol).
//
// Replayed against a real burner by test/quint/FeeBurnerReplay.t.sol.
//
// WHY THIS ONE
//
// test/symbolic/README.md records that division of a symbolic product is the
// hard wall, and that this is why no *accepting* path is proven anywhere in the
// contracts. `buy` is that wall in its most concentrated form:
//
//   govIn      = ceil(amountOut * price / 1e18)
//   fillBps    = floor(amountOut * BPS / bal)
//   mult       = BPS + floor((restartMultBps - BPS) * fillBps / BPS)
//   startPrice = floor(price * mult / BPS)
//   burned     = floor(govIn * burnBps / BPS)
//
// Five roundings, four of them floors, applied to a `startPrice` and `startedAt`
// that the *previous* `buy` wrote. The result is a sawtooth: the price decays
// with time and jumps back up on each fill, by an amount weighted by how much of
// the lot the fill took. That shape only exists across steps, so no single-call
// proof and no end-of-run invariant sees it.
//
// THE DOMAIN IS THE POINT
//
// spec/masp.qnt records that its own fee rounding is invisible, because an
// asset scale of 1e10 divides BPS and every division there is exact. The same
// trap is live here five times over, so every constant below is chosen to make
// the division *inexact*:
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
//   - FEE_AMOUNTS are chosen so `amountOut * BPS % bal != 0`, so the floor in
//     `fillBps` is observable.
//
// Each of those is checked by a fault injection: flip the operation in the
// contract, and the replay must fail. If it does not, the domain is exact where
// it should be inexact and this spec measures nothing.
//
// ABSTRACTED
//
//   - `harvest` and the pool. The burner needs no pool unless `harvest` is
//     modelled, and `harvest` ignores every outcome of the calls it makes.
//   - `burnAccruedGov`, `rescue`, `setPools`, `setSecondaryTreasury`. Owner
//     plumbing and a cleanup path that test/burn/FeeBurner.invariant.t.sol
//     already covers with `invariant_burnerHoldsNoGov`.
//   - `minLot`. Held at zero, so the dust floor never rejects: it is a
//     single-call guard, which is halmos territory.
//   - Multiple lot tokens. One token; the per-token mapping is a mapping.
module fee_burner {
  pure val BPS = 10000
  pure val PRICE_SCALE = 1000000000000000000  // 1e18

  // Must match the driver, which asserts the deployed burner agrees.
  pure val HALF_LIFE = 3600
  pure val MAX_HALVINGS = 12
  pure val RESTART_MULT_BPS = 17777
  pure val BURN_BPS = 6667
  /// ~1.234e18. Odd, and not a multiple of 1e18.
  pure val SEED_PRICE = 1234567890123456789
  /// Above `SEED_PRICE >> MAX_HALVINGS` (~3.01e14), so the floor actually binds
  /// once decay clamps. Below it the floor is unreachable and the
  /// `p < minPrice` branch is dead across every trace.
  pure val MIN_PRICE = 400000000000000  // 4e14

  /// What the bidder starts with. `bidderGov` then moves only by `govIn`, which
  /// makes the composite rounding directly compared rather than inferred - the
  /// `payerBalance` trick from spec/masp.qnt.
  pure val BIDDER_START = 100000000000000000000000  // 100_000e18
  /// LelantosToken's fixed supply, minted once at construction.
  pure val GOV_SUPPLY = 1000000000000000000000000000  // 1e9 * 1e18

  /// Fee-token amounts, for both `accrueFees` and `buy`. Chosen so
  /// `amountOut * BPS` rarely divides `bal`.
  pure val AMOUNTS = Set(1, 7, 1009, 100003)

  /// Mostly not multiples of HALF_LIFE, so the mid-period interpolation runs.
  /// 3600 is included so the exact-boundary case is reachable too, and 50000
  /// clears MAX_HALVINGS * HALF_LIFE = 43200 so the clamp branch is reached.
  pure val TIME_JUMPS = Set(1, 1000, 3600, 7300, 50000)

  /// The draw behind `setLot`'s and `setPaused`'s flags, biased.
  ///
  /// Every action here draws exactly one number and calls it `p`, from whichever
  /// of AMOUNTS, TIME_JUMPS or QUARTERS is its domain, then names it locally.
  /// A trace step carries a slot for every distinct pick *name* in the spec
  /// whichever action ran, at 64 B each, so three names cost 192 B on all 648
  /// steps - 30% of the fixture - to hold two empty slots at a time.
  ///
  /// A uniform bool on each of two independent gates leaves `buy` blocked three
  /// quarters of the time, and `buy` is the accepting path this whole spec
  /// exists to reach. Reading the flag off a quarters draw makes the lot
  /// enabled 3/4 of the time and the burner paused 1/4 - both states still
  /// occur, and both rejection guards are still exercised, but the arithmetic
  /// gets reached far more often. The names differ so each reads as what it is
  /// at its use site.
  pure val QUARTERS = Set(0, 1, 2, 3)

  /// Powers of two up to 2^MAX_HALVINGS, for the `>>` in the decay curve. The
  /// clamp means no larger shift is ever needed.
  pure val POW2 = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096]

  var nowTs: int
  var lotEnabled: bool
  var startedAt: int
  var startPrice: int
  var minPrice: int
  var paused: bool
  /// token.balanceOf(burner)
  var burnerTokenBal: int
  /// GOV held by the burner. Should be zero after every buy: the split sends
  /// all of it out.
  var burnerGovBal: int
  var govSupply: int
  var bidderGov: int
  var secondaryGov: int

  // --- ghosts (ignoreState) ---------------------------------------------

  /// GOV burned, accumulated independently of `govSupply`, which is read live
  /// from `totalSupply()`. Monotonicity alone would be satisfied by a burn of
  /// the wrong amount.
  var burnedTotal: int
  /// GOV paid in, accumulated independently of `bidderGov`.
  var govInTotal: int
  /// Fills, so a run that never bought anything is visible.
  var fillCount: int
  /// Counts a fill whose ratchet left `startPrice` below the price it cleared
  /// at. `restartMultBps >= BPS` should make that impossible.
  var ratchetViolations: int
  /// Sum of `amountOut * price` over fills, in price-scale units. Paired with
  /// `govInTotal` it brackets the rounding: `ceil` puts each `govIn` in
  /// `[cost/1e18, cost/1e18 + 1)`, which a floor cannot satisfy.
  var costBasis: int
  /// Fee tokens sold and received, tracked separately from the balance so a
  /// buy that forgets to debit, or an accrual that forgets to credit, breaks
  /// the identity rather than moving both sides together.
  var soldTotal: int
  var accruedTotal: int
  /// Time advanced, independently of the clock.
  var timeAdvanced: int
  /// When the lot was last (re)started - by a fill or by `setLot`. Both write
  /// `startedAt`, so this pins it without restating either.
  var lastTouchAt: int
  /// Fills that took a non-zero share and yet did not raise the asking price.
  /// The ratchet exists to make that impossible.
  var flatRatchets: int
  /// Fills split by the share of the lot they took: under a tenth, and at
  /// least half. The ratchet interpolates between `BPS` and `restartMultBps`
  /// on that share, so a committed set carrying only one size never varies
  /// `mult` and the interpolation could be a constant without anything
  /// noticing.
  ///
  /// Bands rather than the endpoints: `fillBps == BPS` needs `amt` to equal the
  /// balance exactly, which the amount domain reaches in 7.6% of traces, and a
  /// floor set that low would witness nothing.
  var smallFills: int
  var largeFills: int
  /// Waits that moved the clock forward inside the decaying region and yet
  /// left the asking price where it was. Counted by comparing the curve at two
  /// clocks rather than by restating the decay expression, which is the only
  /// way a dropped interpolation term is visible: every other invariant here
  /// reads the price through the same `priceAt`, so a flattened curve satisfies
  /// all of them.
  var flatDecays: int

  // --- the decay curve --------------------------------------------------

  pure def shr(x: int, n: int): int = x / POW2[n]

  /// `_priceOf`, restated exactly. `mulDiv(a, b, c)` is `(a * b) / c` here
  /// because Quint integers do not overflow, which is the only thing mulDiv
  /// adds over the naive expression.
  ///
  /// Parametrised on the clock rather than reading `nowTs`, so `wait` can ask
  /// what the price *will* be after the jump it is about to take. That is what
  /// lets `flatDecays` compare two points on the curve; a def closed over the
  /// current state can only ever see one.
  pure def priceAt(en: bool, sAt: int, sPrice: int, mPrice: int, t: int): int =
    if (not(en)) 0
    else
      val elapsed = t - sAt
      val periods = elapsed / HALF_LIFE
      val p =
        if (periods >= MAX_HALVINGS) shr(sPrice, MAX_HALVINGS)
        else
          val base = shr(sPrice, periods)
          val rem = elapsed % HALF_LIFE
          base - ((shr(base, 1) * rem) / HALF_LIFE)
      if (p < mPrice) mPrice else p

  def priceNow: int = priceAt(lotEnabled, startedAt, startPrice, minPrice, nowTs)

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
  }

  // --- frames -----------------------------------------------------------
  //
  // Quint has no `UNCHANGED`: every action must assign every variable, so five
  // actions over twenty-four variables is ninety-odd `x' = x` lines that say
  // nothing. They are grouped here by *which actions write them*, which makes
  // each group a real partition rather than a filing convenience - a variable
  // whose writers change no longer fits its group, and moving it is the edit
  // that makes the change visible.
  //
  // The payoff is at the use sites below: an action now lists what it changes
  // and names what it leaves alone.

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

  /// Written by `buy` and by `setLot`, the two things that restart the auction.
  /// `lastTouchAt` shadows `startedAt` precisely so both writers are pinned.
  action unchangedLotClock = all {
    startedAt' = startedAt,
    startPrice' = startPrice,
    lastTouchAt' = lastTouchAt,
  }

  /// Written only by `setPaused`.
  action unchangedPauseFlag = paused' = paused

  /// Written by `accrueFees` and by `buy` - fees in, lot out.
  action unchangedTokenBal = burnerTokenBal' = burnerTokenBal

  /// Written by nothing. `buy` sends the whole proceeds out in the same call,
  /// so the burner never holds GOV between calls - which is what
  /// `inv_burnerHoldsNoGov` asserts against the live balance.
  action unchangedGovHeld = burnerGovBal' = burnerGovBal

  /// Written only by `buy`: everything a fill moves, live balances and ghosts
  /// alike, kept together because they move together or the fill is wrong.
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
  }

  /// Written only by `accrueFees`.
  action unchangedAccrual = accruedTotal' = accruedTotal

  /// Fee tokens arriving at the burner. In production this is `sweep` paying
  /// the treasury; the amount is what matters, not the route.
  action accrueFees = {
    nondet p = AMOUNTS.oneOf()
    val amt = p
    all {
      burnerTokenBal' = burnerTokenBal + amt,
      accruedTotal' = accruedTotal + amt,
      unchangedClock,
      unchangedLotConfig,
      unchangedLotClock,
      unchangedPauseFlag,
      unchangedGovHeld,
      unchangedFillLedger,
    }
  }

  /// `buy`. The five roundings above, in order.
  action buy = {
    nondet p = AMOUNTS.oneOf()
    val amt = p
    val price = priceNow
    val govIn = ceilDiv(amt * price, PRICE_SCALE)
    val fillBps = (amt * BPS) / burnerTokenBal
    val mult = BPS + (((RESTART_MULT_BPS - BPS) * fillBps) / BPS)
    val newStart = (price * mult) / BPS
    val burned = (govIn * BURN_BPS) / BPS
    all {
      not(paused),
      lotEnabled,
      amt <= burnerTokenBal,
      govIn > 0,
      govIn <= bidderGov,
      burnerTokenBal' = burnerTokenBal - amt,
      startPrice' = newStart,
      startedAt' = nowTs,
      lastTouchAt' = nowTs,
      bidderGov' = bidderGov - govIn,
      govSupply' = govSupply - burned,
      secondaryGov' = secondaryGov + (govIn - burned),
      burnedTotal' = burnedTotal + burned,
      govInTotal' = govInTotal + govIn,
      fillCount' = fillCount + 1,
      costBasis' = costBasis + (amt * price),
      soldTotal' = soldTotal + amt,
      // The ratchet must never leave the lot cheaper than it just cleared at.
      ratchetViolations' =
        if (newStart < price) ratchetViolations + 1 else ratchetViolations,
      // A fill big enough for the ratchet term to survive its own flooring
      // must leave the lot dearer than it cleared at. Below that threshold a
      // flat price is correct - `floor((restartMultBps - BPS) * fillBps / BPS)`
      // is genuinely zero for a small enough share - so the condition is on
      // the term, not on `fillBps > 0`. Counting the exceptions is what makes
      // a flattened ratchet visible: `newStart == price` breaks no bound.
      flatRatchets' =
        if (fillBps * (RESTART_MULT_BPS - BPS) >= BPS and newStart <= price)
          flatRatchets + 1
        else flatRatchets,
      smallFills' = if (fillBps * 10 < BPS) smallFills + 1 else smallFills,
      largeFills' = if (fillBps * 2 >= BPS) largeFills + 1 else largeFills,
      unchangedClock,
      unchangedLotConfig,
      unchangedPauseFlag,
      unchangedGovHeld,
      unchangedAccrual,
    }
  }

  action wait = {
    nondet p = TIME_JUMPS.oneOf()
    val dt = p
    // The two ends of the jump. Both go through `priceAt`, but the count below
    // compares them instead of re-deriving either, so it survives any change to
    // the curve that keeps it monotone - and fails on one that does not.
    val before = priceNow
    val after = priceAt(lotEnabled, startedAt, startPrice, minPrice, nowTs + dt)
    all {
      nowTs' = nowTs + dt,
      timeAdvanced' = timeAdvanced + dt,
      // Guarded on the two places the curve is flat by design: past
      // `maxHalvings` it is constant, and at `minPrice` it has bottomed out.
      // Everywhere else a forward jump must cost the lot something.
      flatDecays' =
        if (and {
          lotEnabled,
          (nowTs - startedAt) / HALF_LIFE < MAX_HALVINGS,
          before > minPrice,
          after >= before,
        }) flatDecays + 1
        else flatDecays,
      unchangedLotConfig,
      unchangedLotClock,
      unchangedPauseFlag,
      unchangedTokenBal,
      unchangedGovHeld,
      unchangedFillLedger,
      unchangedAccrual,
    }
  }

  /// `setLot`. Re-seeds the whole struct and restarts the clock, in either
  /// direction.
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
      unchangedClock,
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
      unchangedLotConfig,
      unchangedLotClock,
      unchangedTokenBal,
      unchangedGovHeld,
      unchangedFillLedger,
      unchangedAccrual,
    }
  }

  action step = any { accrueFees, buy, wait, setLot, setPaused }

  // --- invariants -------------------------------------------------------

  /// GOV supply only ever falls. The headline claim, and real: `govSupply` is
  /// read live from `totalSupply()` on the chain.
  val inv_supplyMonotone = govSupply <= GOV_SUPPLY

  /// And by exactly what was burned. Monotonicity alone is satisfied by a burn
  /// of the wrong size; this pins the amount, against a ghost maintained
  /// independently of the live read.
  val inv_supplyExact = govSupply == GOV_SUPPLY - burnedTotal

  /// The bidder paid exactly the sum of the quoted prices. The direct check on
  /// the composite rounding in `govIn`.
  val inv_bidderPaidExactly = BIDDER_START - bidderGov == govInTotal

  /// Every GOV that came in either burned or went to the secondary treasury.
  val inv_govInSplitsExactly = govInTotal == burnedTotal + secondaryGov

  /// The burner never sits on GOV: `buy` sends all of it out in the same call.
  val inv_burnerHoldsNoGov = burnerGovBal == 0

  /// A fill never leaves the lot cheaper than the price it just cleared at.
  val inv_ratchetNeverLowers = ratchetViolations == 0

  /// The asking price stays inside the band its parameters define.
  val inv_priceWithinBand =
    not(lotEnabled) or (priceNow >= minPrice and priceNow <= startPrice)

  /// `govIn` is a ceiling, not a floor.
  ///
  /// Per fill, `ceil(cost / 1e18)` lies in `[cost/1e18, cost/1e18 + 1)`. Summed,
  /// that brackets the total between the cost basis and the cost basis plus one
  /// unit per fill - a bracket a floor cannot sit inside as soon as any single
  /// division has a remainder.
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

  /// Fee tokens in minus fee tokens out. Tracked separately from the balance,
  /// so a buy that forgets to debit breaks it rather than moving both sides.
  val inv_tokenConservation = burnerTokenBal == accruedTotal - soldTotal

  /// The clock the model reasons about is the clock it advanced.
  val inv_clockMatchesAdvances = nowTs == timeAdvanced

  /// `startedAt` is whenever the lot was last restarted, by a fill or a
  /// reconfiguration - the two writers of it.
  val inv_startedAtIsLastTouch = startedAt == lastTouchAt

  /// A fill whose ratchet term survives its own flooring always leaves the lot
  /// dearer than it cleared at.
  val inv_ratchetAlwaysRaises = flatRatchets == 0

  /// The price strictly falls while the clock runs inside the decaying region.
  ///
  /// The one invariant here that is not an arithmetic consequence of the decay
  /// expression: it holds the curve at two clocks against each other. Deleting
  /// the mid-period interpolation leaves every other invariant satisfied - the
  /// staircase it degenerates to is still inside the band, still above the
  /// floor, still below `startPrice` - and violates only this one.
  val inv_decayStrictlyFalls = flatDecays == 0

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
  }

  // --- witnesses --------------------------------------------------------

  /// Anything was bought at all.
  val wit_filled = fillCount > 0

  /// A fill happened partway through a half-life, so the linear interpolation
  /// inside the period ran. Without this the whole `p -= mulDiv(p >> 1, rem,
  /// period)` line could be dead across the committed set.
  val wit_interpolatedMidPeriod =
    lotEnabled and (nowTs - startedAt) % HALF_LIFE != 0 and (nowTs - startedAt) < HALF_LIFE * MAX_HALVINGS

  /// The clamp branch: decay stopped rather than interpolating past the floor.
  val wit_decayClampReached =
    lotEnabled and (nowTs - startedAt) / HALF_LIFE >= MAX_HALVINGS

  /// The price bottomed out at its floor, so an unsold lot is stuck there.
  val wit_floorReached = lotEnabled and priceNow == minPrice

  /// Both fill sizes happened, so `mult` was interpolated at more than one
  /// point on its range rather than pinned at whichever share the seed
  /// happened to produce.
  ///
  /// 53.5% of 2000 traces at 65 steps, which is the ceiling for this shape: a
  /// small fill needs the balance to be ten times the amount drawn, and the
  /// amount domain is shared with `accrueFees`. Adding a fifth, larger amount
  /// to reach it more often makes this *worse* (49.4%) by diluting the draw
  /// every other witness depends on.
  val wit_partialThenFullFill = smallFills > 0 and largeFills > 0

  /// A burn that left a remainder for the secondary treasury, so the split ran
  /// both ways rather than burning everything.
  val wit_splitBurn = secondaryGov > 0
}
