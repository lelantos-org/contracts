// Model-based testing config. See lib/quint-sol-connect/README.md.
//
// Generation needs node and quint (`just quint-install`); replaying the
// committed traces needs neither, so `just test` and the `test` CI job pick
// them up as ordinary Foundry tests.
export default {
  // Fixture size, not runtime, limits how many specs the repo can carry
  // (replay takes milliseconds). Specs draw against a shared total, so adding
  // one is an explicit trade against the others.
  budget: { totalBytes: 12_000_000, defaultMaxBytes: 512_000 },

  solidityOut: 'test/quint/generated',
  fixtureOut: 'test/fixtures/quint',
  pragma: '0.8.36',

  specs: {
    commitmentTree: {
      spec: 'spec/commitment_tree.qnt',
      module: 'commitment_tree',

      // 90 steps exceeds ROOT_HISTORY (64): the ring wrap is the purpose of
      // modelling this contract, and with `[invariant] depth = 64` the fuzz
      // suite rarely reaches one.
      // 2 traces: both hold duplicate roots across the wrap, the case
      // `inv_ringRootsAreKnown` checks, and each costs ~470 KB. Steps cannot be
      // reduced: below ~70 the ring does not wrap. Breadth comes from the
      // nightly `just quint-fresh`.
      run: {
        traces: 2,
        maxSteps: 90,
        maxSamples: 3000,
        seed: '0x5eed0001',
        invariant: 'allInvariants',
      },

      driver: {
        path: 'test/quint/CommitmentTreeReplay.t.sol',
        contract: 'CommitmentTreeReplay',
      },

      budget: {
        maxBytes: 1_800_000,
        why:
          '2638 B/step is the 64-slot ring compared slot by slot, which is the whole point - '
          + 'a digest would keep detection and lose the diagnosis of which slot diverged. '
          + 'Already cut 8 traces to 2; steps cannot go below ~70 without losing the wrap',
      },

      state: {
        // roots[0..63]. Model integers, mapped onto bytes32 by the driver.
        rootRing: { list: 'uint256' },
        rootIndex: 'uint256',
        committedCount: 'uint256',
        // A Quint set has no order; the generator sorts ascending and the
        // driver's projection must produce the same order.
        knownRoots: { set: 'uint256' },
      },

      // Floors at ~60% of what the pinned seed produces. They catch an action
      // whose step count collapses, which would otherwise replay green while
      // barely exercising that action.
      coverage: { minSteps: { advance: 108 } },

      // Model-only ghosts. They give the invariants something to contradict
      // and have no on-chain counterpart to compare against.
      ignoreState: {
        advances:
          'ghost: counts advances so `inv_indexTracksAdvances` can catch a wrong ring stride, which no other invariant constrains',
        insertedTotal:
          'ghost: sums `inserted` so `inv_countIsSumOfInserts` can catch counting advances instead of leaves',
      },

      actions: {
        advance: { newRoot: 'uint256', inserted: 'uint256' },
      },
    },

    nullifierSet: {
      spec: 'spec/nullifier_set.qnt',
      module: 'nullifier_set',

      run: {
        traces: 6,
        maxSteps: 24,
        maxSamples: 2000,
        seed: '0x5eed0002',
        invariant: 'allInvariants',
      },

      driver: {
        path: 'test/quint/NullifierSetReplay.t.sol',
        contract: 'NullifierSetReplay',
      },

      state: {
        // The whole spent set, re-read from the bitmap and compared after every
        // consume. Sorted ascending by the generator; the driver matches.
        spentSet: { set: 'uint256' },
      },

      // Floors at ~60% of what the pinned seed produces; see commitmentTree.
      coverage: { minSteps: { consume: 25, consumeSpent: 61 } },

      ignoreState: {
        consumeCount:
          'ghost: counts successful consumes so `inv_setSizeMatchesConsumes` has something real to check; the set alone admits no non-trivial invariant',
      },

      actions: {
        consume: { nf: 'uint256' },
        // Negative path: the driver expects a DoubleSpend revert.
        consumeSpent: { nf: 'uint256' },
      },
    },

    masp: {
      spec: 'spec/masp.qnt',
      module: 'masp',

      run: {
        // Sized for eight actions: a wider action set dilutes each action's
        // share of a fixed step budget, and cancel coverage (especially the
        // boundary cases) needs this many traces.
        traces: 20,
        maxSteps: 96,
        maxSamples: 20000,
        seed: '0x5eed00a3',
        invariant: 'allInvariants',
      },

      driver: {
        path: 'test/quint/MaspReplay.t.sol',
        contract: 'MaspReplay',
      },

      budget: {
        maxBytes: 7_500_000,
        why:
          '20 x 96 is the setting that restored cancel coverage after setCancelDelay and '
          + 'setAssetDisabled became the seventh and eighth actions; 2 x 96 would fit the '
          + 'default and undo it. Two levers remain if this needs to come down: deposits is '
          + '56% of the step (MAX_DEPOSITS 6 -> 4 saves ~20%) and five pick names cost 320 B '
          + 'on every step whichever action ran',
      },

      state: {
        blockNo: 'uint256',
        nextId: 'uint256',
        // The escrow stores only a keccak digest, so the driver shadows the
        // preimage and cross-checks it against `escrowed[id] != 0`.
        deposits: {
          map: {
            key: 'uint256',
            value: {
              record: {
                principal: 'uint256',
                fee: 'uint256',
                submittedAt: 'uint256',
                status: { variant: ['Pending', 'Flushed', 'Cancelled'], name: 'Status' },
              },
            },
          },
          entryName: 'DepositEntry',
        },
        poolBalance: 'uint256',
        accruedFee: 'uint256',
        treasuryBalance: 'uint256',
        payerBalance: 'uint256',
        committedCount: 'uint256',
        // A live protocol parameter, not a term of each escrow: `cancelDeposit`
        // reads it from storage, so moving it moves the unlock block of every
        // deposit already in flight.
        cancelDelay: 'uint256',
        // Read only in `_validateDeposit`. Flush and cancel do not check it, so
        // disabling an asset does not strand escrows.
        assetDisabled: 'bool',
      },

      // Floors at ~60% of what the pinned seed produces; see commitmentTree.
      coverage: {
        minSteps: {
          submit: 68,
          flush: 50,
          cancel: 16,
          cancelTooEarly: 43,
          sweep: 246,
          advanceBlocks: 227,
          setCancelDelay: 252,
          setAssetDisabled: 246,
        },
      },

      ignoreState: {
        guardViolations:
          'ghost: counts cancels landing on the wrong side of the delay so `inv_cancelGuardsRespected` constrains the timing; every other invariant here is indifferent to when a refund happened',
        settledWhileDisabled:
          'ghost: witnesses that a deposit was flushed or cancelled while its asset was disabled - the property that a disable stops new inflow without stranding escrows',
        cancelledEarlierThanDefault:
          'ghost: witnesses a cancel in the window that opens when setCancelDelay is shortened under a live escrow',
      },

      actions: {
        submit: { publicIn: 'uint256' },
        flush: { id: 'uint256' },
        cancel: { id: 'uint256' },
        // Negative path: the driver expects a CancelTooEarly revert.
        cancelTooEarly: { id: 'uint256' },
        sweep: {},
        advanceBlocks: { n: 'uint256' },
        setCancelDelay: { newDelay: 'uint256' },
        setAssetDisabled: { disabled: 'bool' },
      },
    },

    feeBurner: {
      spec: 'spec/fee_burner.qnt',
      module: 'fee_burner',

      run: {
        traces: 8,
        // 96 rather than 80: a sub-MIN_LOT amount drawn against a large balance
        // is rejected, so `buy` is scarce, and 8 x 80 gives 39 fills, below its
        // floor.
        maxSteps: 96,
        maxSamples: 20000,
        seed: '0x5eed0005',
        invariant: 'allInvariants',
        // Token magnitudes exceed i64: `amountOut * price` at 18 decimals
        // overflows before the division, and the Rust evaluator rejects the
        // literals.
        backend: 'typescript',
      },

      driver: {
        path: 'test/quint/FeeBurnerReplay.t.sol',
        contract: 'FeeBurnerReplay',
      },

      budget: {
        maxBytes: 1_200_000,
        why:
          '`buy` is guard-limited - it needs an enabled lot, a non-empty balance, an '
          + 'unpaused burner and, unless it clears the balance, at least MIN_LOT - so it never '
          + 'gets its 1/6 share of a step budget: 54 of 776 steps on the pinned seed. A floor '
          + 'of 45 fills needs 8 x 96; 8 x 80 gives 39. Lowering the floor instead would leave '
          + 'the accepting-path arithmetic this spec exists for barely exercised, which is the '
          + 'one thing the symbolic suite cannot reach. The global and per-lot decay curves add '
          + 'four scalars per step, which is what shows a running lot is never repriced'
      },

      coverage: { minSteps: { buy: 45, accrueFees: 60, wait: 60, setLot: 60, setPaused: 60, setDecayParams: 60 } },

      state: {
        nowTs: 'uint256',
        lotEnabled: 'bool',
        startedAt: 'uint256',
        startPrice: 'uint256',
        minPrice: 'uint256',
        paused: 'bool',
        burnerTokenBal: 'uint256',
        // Zero after every buy: the split sends all of it out.
        burnerGovBal: 'uint256',
        govSupply: 'uint256',
        // Moves only by `govIn`, so the composite rounding is compared
        // directly rather than inferred.
        bidderGov: 'uint256',
        secondaryGov: 'uint256',
        // The global decay curve, written only by setDecayParams.
        halfLife: 'uint256',
        maxHalvings: 'uint256',
        // The lot's curve snapshot, written by setLot and a re-anchoring fill.
        // Priced off rather than the globals, so setDecayParams never reprices
        // a running lot.
        lotHalfLife: 'uint256',
        lotMaxHalvings: 'uint256',
      },

      ignoreState: {
        burnedTotal:
          'ghost: GOV burned, accumulated independently of the live totalSupply read - monotonicity alone is satisfied by a burn of the wrong amount',
        govInTotal:
          'ghost: GOV paid in, accumulated independently of the bidder balance',
        fillCount:
          'ghost: fills, so a run that never bought anything is visible',
        ratchetViolations:
          'ghost: counts a fill whose ratchet left startPrice below the price it cleared at, which restartMultBps >= BPS should make impossible',
        costBasis:
          'ghost: sum of amountOut * price over fills, in price-scale units. Paired with govInTotal it brackets the rounding, which is how a ceil is told from a floor',
        soldTotal:
          'ghost: fee tokens sold, tracked apart from the balance so a buy that forgets to debit breaks the identity rather than moving both sides together',
        accruedTotal:
          'ghost: fee tokens received, the other half of that identity',
        timeAdvanced:
          'ghost: time advanced, accumulated independently of the clock the driver warps',
        lastTouchAt:
          'ghost: when the lot was last restarted, by a fill or by setLot. Both write startedAt, so this pins it without restating either',
        flatRatchets:
          'ghost: fills that took a share large enough for the ratchet term to survive its own flooring and yet did not raise the asking price. newStart == price breaks no bound, so nothing else would see it',
        smallFills:
          'ghost: fills that took under a tenth of the lot. Paired with largeFills it shows mult was interpolated at more than one point on its range, rather than pinned wherever the seed put it',
        largeFills:
          'ghost: fills that took at least half the lot, the other half of that pair',
        flatDecays:
          'ghost: waits that moved the clock forward inside the decaying region and left the price where it was. Counted by comparing the curve at two clocks, which is the only way a dropped interpolation term is visible - every other invariant reads the price through the same priceAt',
        dustClearsMidDecay:
          'ghost: clearing fills below MIN_LOT on a lot whose clock had started, where a re-anchor would move startedAt on chain. Backs wit_dustClearKeptTheClock',
        zeroWeightFillsMidDecay:
          'ghost: fills of at least MIN_LOT whose ratchet term floored to zero, on a running clock - the other path that must not re-anchor. Backs wit_zeroWeightFillKeptTheClock',
        unanchoredPriceMoves:
          'ghost: fills that did not re-anchor yet changed the asking price at the same clock, compared through priceAt rather than by restating the guard',
        dustReanchors:
          'ghost: fills below MIN_LOT that rewrote startPrice, startedAt or the curve snapshot - the donate-and-clear ratchet',
        staleCurveFills:
          'ghost: fills on a running lot whose curve snapshot differs from the globals, the only fills whose govIn tells snapshot pricing from global pricing. Backs wit_boughtOnStaleCurve',
      },

      // One pick name across all six actions, because every step carries a
      // slot for each distinct name regardless of which action ran: three names
      // would cost 192 B per step for two empty slots. The spec and the driver
      // name it locally in each action.
      //
      // For `setLot` and `setPaused` it is a quarters draw, not a flag: the lot
      // is enabled on `p > 0` and the burner paused on `p == 0`. A uniform bool
      // on each gate would block `buy`, the accepting path this spec targets,
      // three quarters of the time.
      actions: {
        accrueFees: { p: 'uint256' },
        buy: { p: 'uint256' },
        wait: { p: 'uint256' },
        setLot: { p: 'uint256' },
        setPaused: { p: 'uint256' },
        // A quarters draw indexing DECAY_HALF_LIVES and DECAY_MAX_HALVINGS.
        setDecayParams: { p: 'uint256' },
      },
    },

    delayedUpgradeProxy: {
      spec: 'spec/delayed_upgrade_proxy.qnt',
      module: 'delayed_upgrade_proxy',

      // Fewer, longer traces: every property here is an interleaving
      // (queue -> pause -> activate, pause -> queue, pause -> pause),
      // and one 60-step trace reaches more of them than two 30-step ones.
      // 76 rather than 60 since `queueUpgrade` defers by a running pause:
      // longer windows cost activations, and 8 x 60 fell below the floor.
      run: {
        traces: 8,
        maxSteps: 76,
        maxSamples: 20000,
        seed: '0x5eed0004',
        invariant: 'allInvariants',
      },

      driver: {
        path: 'test/quint/DelayedUpgradeProxyReplay.t.sol',
        contract: 'DelayedUpgradeProxyReplay',
      },

      budget: {
        maxBytes: 700_000,
        why:
          '512 B/step is already near the floor for six scalars and three pick names. '
          + 'The overage is trace count, and cutting it costs the interleavings this spec '
          + 'exists for - activateUpgrade sits exactly on its floor of 8 in 8 x 76, since '
          + 'queueUpgrade defers activation by a running pause and pauseSpends, now that the '
          + 'one-shot latch is gone, is always enabled and chains',
      },

      coverage: {
        minSteps: {
          queueUpgrade: 25,
          cancelUpgrade: 20,
          activateUpgrade: 8,
          activateTooEarly: 25,
          pauseSpends: 25,
          changeProxyAdmin: 25,
          advanceTime: 40,
        },
      },

      state: {
        // Seconds since the driver's T0, so the model never carries an absolute
        // timestamp and the driver warps to `T0 + nowTs`.
        nowTs: 'uint256',
        pendingImpl: 'uint256',
        activationAt: 'uint256',
        pausedUntil: 'uint256',
        // Read live through the proxy: the only observable effect of an
        // activation.
        implVersion: 'uint256',
        admin: 'uint256',
      },

      ignoreState: {
        queuedAt:
          'ghost: when the live window opened. The contract stores only activationAt, so there is nothing on chain to compare against - it exists so inv_windowIsExact can be stated',
        pausedInWindow:
          'ghost: pause duration that landed while an upgrade was pending. Without it, deleting the pendingImplementation check in pauseSpends leaves every invariant satisfied',
        carriedPause:
          'ghost: pause still running when the live window was queued, which queueUpgrade adds to activationAt. The contract keeps no record of it, so it exists so inv_windowIsExact stays an equation',
        unpausedInWindow:
          'ghost: unpaused seconds the clock spent inside the live window, so inv_exitWindowIsUnpaused can state the exit guarantee independently of how activationAt was computed',
        pauseFirings:
          'ghost: counts pauses, so a trace that chained several is visible; pauseSpends is repeatable and the window arithmetic has to survive that',
        queueFirings:
          'ghost: windows opened, so wit_requeued can show a second window was started from scratch',
        lastActivated:
          'ghost: what the last activation promoted, so an activateUpgrade that clears the queue without upgrading is visible',
      },

      actions: {
        queueUpgrade: { impl: 'uint256' },
        cancelUpgrade: {},
        activateUpgrade: {},
        // Negative path: the driver asserts NotYetActivatable and its argument.
        activateTooEarly: {},
        pauseSpends: { dt: 'uint256' },
        changeProxyAdmin: { who: 'uint256' },
        advanceTime: { dt: 'uint256' },
      },
    },
  },
};
