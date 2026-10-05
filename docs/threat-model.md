# Threat model

Who can call what, what they gain by misbehaving, and the worst case for each
key. Every number below is a constant or a default in `contracts/src/`. A claim
that is not in the code does not belong here. This file was rewritten after the
2026-09-28 hardening plan (C1–C11) because the previous version described a
timelock and a 50 bps bound that did not exist, and updated again for round 2
of that plan (D1–D7): queued changes now expire, loosening the fill bounds is
queued, the demo's lending mock answers only to its vault, and the faucet has
a global budget. Round 3 (F1–F7): deposits are paused from the constructor and
cannot open before the admin calls `finishSetup`, which closes the setup
window; an instant tightening drops a
queued loosening; the oracle reads a feed through one bounded, range-checked
decoder; a real B20 can be routed under simulation; and the Sepolia deploy
hands the vault to `DEMO_OWNER` too. Round 6 (2026-10-04) changed the
contracts for the round-5 findings that needed it. It fixed four of them
(R5-5, R5-6, R5-8, R5-9) and bounded two (R5-1 and R5-2): the swap adapter
refuses a pool whose spot price is away from its own recent average, the
oracle asks whether the sequencer is up, a
plan's last period is held to the 1 USDC minimum at creation, a supply that
mints no shares reverts, and the fee recipient cannot be the vault or an
adapter. Round 6b (2026-10-05) came from a re-review of round 6, which showed
that one five-minute average can be moved by a single block (R6-1) and that
this file said otherwise: the swap adapter now holds the spot to five
one-minute averages, the oracle reads not fresh from Saturday 00:00 UTC to
Monday 01:00 UTC, and the fee recipient cannot be the oracle either. R5-2 is
still bounded, not fixed.

## Actors

| Actor | Can do | Cannot do |
|---|---|---|
| **Plan owner** | Create a plan. Execute their own plan from the moment it is due. Exit at any time the lending market can pay (see *Exits*). | Touch another plan. Execute before `nextExecution`. |
| **Keeper** (allowlisted by admin) | Call `executeDCA` on any plan from the moment it is due. There is no grace wait for a keeper. | Change the asset, the amount, the destination or the schedule. Withdraw anything. Execute before `nextExecution`. |
| **Anyone** | Call `executeDCA` once `nextExecution + grace` has passed (`grace` = 12 hours, a constant, counted from when the buy fell due: a buy that fell due on a weekend can be past it the moment the weekend ends). Call `claimFees()`, which pays the current `feeRecipient` and nobody else. | The same limits as a keeper. |
| **Vault admin** | The instant and delayed powers listed below. | Move user funds directly. Holding the oracle's admin as well, which is the launch setup, and after a public 48-hour feed change, it can make due buys fill at a bad price: up to one due installment per plan per interval (see *Both roles at once*). Touch `exitPlan`. Change a route's token or pool. Swap the adapter, swapper or oracle, which are immutable. Upgrade anything, because there is no proxy. |
| **Oracle admin** | List a feed for a token that has none (instant). Queue a feed change for a **listed** token (48 hours, then a 7-day window to activate it). | Change a listed token's feed without the 48-hour delay. Activate a queued change after its window has closed. Queue a change for an unlisted token (`NoFeed`). Switch the weekend rule off or change the sequencer uptime feed: both are fixed when the oracle is built. |
| **Route venue** (pool) | Receive exactly `spend` USDC and deliver stock to the owner. | Fill below `minOut`. The adapter measures what the owner actually received, and the vault checks it again. Collect more or less than `amountIn`. Be bought from while its spot price is more than about 1% from any of its own five one-minute averages over the last five minutes (`PoolPushed`). |
| **Yield adapter** | Hold the pooled USDC position. Only the vault may `supply`, `redeem` or `withdraw` (`onlyVault`, bound to the vault address at deploy). | Be replaced. It is immutable in the vault. |

### Vault admin powers, exactly

`ADMIN_DELAY` is 48 hours (`DcaVault.ADMIN_DELAY`). Every queued change can be
activated only inside **[eta, eta + 7 days]** (`ACTIVATION_WINDOW`). After that
it has expired (`QueueExpired`) and must be queued again, with a fresh 48 hours
of notice. Without the window, a change queued once and left visibly dormant
could be switched on a year later, in the same block as whatever it enables.

| Power | Takes effect | Bound in the bytecode |
|---|---|---|
| `disableRoute` | instantly | none. It can only stop buys, never redirect them. It also **drops anything queued for that route** (`RouteCancelled`), so a re-enable queued before an incident cannot undo the disable without fresh notice. |
| `queueRoute` → `activateRoute` (list a new route, re-enable a disabled one, or follow an oracle feed rotation) | after 48 hours, in public (`RouteQueued`), within the 7-day window, and cancellable (`RouteCancelled`) | Token and pool are fixed for a route id once set (`RouteImmutable`). The route's `feed` must equal `oracle.feedOf(token)` when queued and again when activated (`FeedMismatch`). The token's decimals: see *The decimals rule* below (`BadTokenDecimals`). |
| `initRoute` | instantly, and **only before `finishSetup`** | Same checks as `queueRoute`. Deposits are paused until `finishSetup`, so no plan can exist while this works. After it, `SetupClosed`, for good. The deploy scripts use this to list the launch routes in the same broadcast as the deploy. |
| `finishSetup` | instantly, **once** | Closes the setup window (`initRoute`, instant loosening) and opens deposits (`SetupFinished`, `DepositsPausedSet(false)`), unless the admin paused deposits on purpose during setup: that pause is kept (`DepositsPausedSet(true)`) and lifted later with `setDepositsPaused(false)`. A second call reverts `SetupClosed`. Every deploy script makes it its last vault call. The mainnet script (`Deploy.s.sol`) pauses first, so its deploy closes the window **without** opening deposits; the multisig opens them. |
| `setFee` | instantly | ≤ `MAX_FEE_BPS` = 1,000 bps (10%) of **accrued yield only**. It never touches principal. It is 0 at launch. |
| `setFeeRecipient` | instantly | Not zero, not the vault, not the yield adapter, not the swap adapter and not the oracle (`BadParams`): nothing can be swept from those four, so fees claimed to one would stay there. The list is not complete and cannot be: a pool, a stock token, or any other contract that cannot send USDC on is still accepted, and fees claimed to it are lost. That costs the fee recipient its fees and nobody else anything. |
| `setBounds(slippage, deviation)` that **tightens** (neither number goes up) | instantly. It also **drops any queued loosening** (`BoundsCancelled`): a tightening is an incident response, and a loosening queued before the incident must not undo it at its eta without fresh notice — the rule `disableRoute` applies to a queued re-enable. | slippage ≤ `MAX_SLIPPAGE_BPS` = 200 bps. deviation ≤ `MAX_DEVIATION_BPS` = 2,000 bps. |
| `setBounds` that **loosens** either number → `activateBounds` | after 48 hours, in public (`BoundsQueued`), within the 7-day window, and cancellable (`cancelBounds`, `BoundsCancelled`). Instant only before `finishSetup`, like `initRoute`. | The same ceilings. A newer loosening replaces a pending one; an instant change drops it. |
| `setTvlCap` | instantly | none. Lowering the cap only refuses new plans. |
| `setDepositsPaused` | instantly | only affects `createPlan`. Paused from the constructor; **unpausing before `finishSetup` reverts `SetupOpen`**, so deposits can never be open while the setup window is. |
| `setKeeper` | instantly | A keeper only skips the grace wait. |
| `transferAdmin` → `acceptAdmin` | when the new admin accepts | two steps, so a typo cannot strand the role |

Every setter emits an event (`FeeSet`, `FeeRecipientSet`, `BoundsSet`,
`BoundsQueued`, `BoundsCancelled`, `TvlCapSet`, `DepositsPausedSet`,
`KeeperSet`, `RouteSet`, `RouteQueued`, `RouteCancelled`, `SetupFinished`,
`AdminTransferStarted`, `AdminTransferred`).

**The setup window ends explicitly.** It used to close on the first
`createPlan`. Deposits were open from deployment, so anyone could land a plan
between two `initRoute` transactions of a deploy and push the remaining launch
routes behind the 48-hour queue. Now deposits are paused from the constructor,
nobody can open them before `finishSetup`, and `finishSetup` is the last vault
call of every deploy script (`Round3.test_F4_*`, `DeployScripts.t.sol`,
`ForkDeploy.t.sol`). Pausing and unpausing deposits later never reopens the
window.

**The decimals rule.** Every stock the vault prices is 8 decimals. A route's
token is checked when the route is initialised, queued and activated:

- a token with **no code** is refused (`BadTokenDecimals(0)`);
- a token whose `decimals()` **answers** must answer 8 (`BadTokenDecimals(n)`);
- a token whose `decimals()` **cannot be read in this EVM** is admitted only
  if its code is exactly the one-byte B20 stub (`0xef`, checked by code
  hash). On Base that stub is backed by a precompile that forge's and
  anvil's EVMs cannot run, so the probe fails under simulation; without this
  case the mainnet deploy reverted `BadTokenDecimals(0)` inside `forge script`.
  On the real chain the stub answers 8. Every other unreadable token is
  refused (`BadTokenDecimals(0)`).

The probe gets 50,000 gas and copies one word, so the stub cannot burn the
transaction's gas (it burned 393M in the old simulation) and a hostile token
cannot return-data-bomb it. Round 3 admitted any unreadable token and relied
on the pool-price bridge to catch a wrong-decimals one; the round-4 re-test
showed that only holds while the pool is honestly priced (pushed to 8dp
parity, it filled at 1e-10 of fair value), so the exception is now the stub
alone (`Round3.test_F1_AnUnreadableWrongDecimalsTokenIsRefused`).
`ForkDeploy.t.sol` runs the real `Deploy.s.sol` against Base mainnet and checks
that all four launch routes are listed, each on the feed the oracle has for it,
and that the deploy ends with the setup window closed and deposits still
paused.

A pending entry survives an admin handover; the new admin inherits it, and it
still expires on the same clock.

`ChainlinkOracle` has its own admin with the same two-step handover. `setFeed`
works only for a token with no feed yet. Changing a listed token's feed goes
through `queueFeed` → `activateFeed` after 48 hours and within the same 7-day
window (`QueueExpired`). `queueFeed` refuses a token that has no feed yet
(`NoFeed`); first listings go through `setFeed`. Every feed must report
`decimals() == 8` (`BadDecimals`).

The oracle's constructor takes two values, and neither can be changed
afterwards by anyone: the chain's sequencer uptime feed (zero switches that
check off) and `closedOnWeekends`, which switches the weekend rule on.
`Deploy.s.sol` passes Base's uptime feed and `true`. Tests pass `false`,
because their stand-in feeds print whenever a test tells them to, except the
tests of the rule itself. The Sepolia and local deploys do not use this
oracle at all. See *The weekend* and *The sequencer*.

**`Route.feed` is the feed at admission.** It is checked against
`oracle.feedOf(token)` when a route is initialised or activated, and the vault
never reads it after that. When the oracle rotates a token's feed behind its
own delay, the route record keeps naming the old feed until the route is
re-queued. Anything that wants the feed a fill is priced off *now* — the web
app, the indexer, a reviewer — reads `oracle.feedOf(token)`, which is also what
the vault prices from.

## The fill bound: one number

Every buy receives at least

    minOut = spend × 1e10 × (10,000 − maxSlippageBps) / (refPx × 10,000)

where `refPx` is the **Chainlink** price (8 decimals). The pool's own price is
not in this formula. `maxSlippageBps` defaults to **100 bps (1%)**, and admin can
raise it to at most **200 bps (2%)**. The bound covers both the pool's premium
over the feed and the trade's own impact. Measured on live Base on 2026-09-21,
GOOGLc traded 38 bps over its feed, and a $1,000 fill moved its pool about
0.03 bps.

So the worst any caller can do to a fill is 1% against the feed (2% if admin
has raised the bound, which now takes 48 hours in public view). That holds for the owner, the keeper, a stranger after
grace, or someone who pushes the pool first and unwinds after. The earlier
design anchored `minOut` to the pool's spot price, so a sandwich could cost up
to the whole 5% divergence band. `test_C2_*` and
`HardInvariants.invariant_probe_fillWithinSlippageBound` pin the new bound.

The pool-versus-feed **circuit breaker** (`maxDeviationBps`, default 500 bps)
still runs first. It refuses a pool that is away from the feed when the call
starts (`PoolDiverged`). It does not price the fill, and it is **not an
independent check on the feed**: it reads the pool's spot price, so a caller
who moves the pool inside the band in the same transaction passes it. Two
things hold against that caller: the fill bound above, which is measured
against the feed, and the push check below, which is measured against the
pool itself.

**The pool must agree with its own recent history.** A bound against the feed
is only as good as the feed. When the feed is behind the market (see *Stale
feeds*), or is one a compromised admin put there (see *Both roles at once*),
a caller could push the pool to the feed's price, execute a buy there, and
unwind: the breaker and the fill bound both passed, because both compare with
the feed. So the swap adapter (`AerodromeSwapAdapter`) makes its own check
before every swap, with no feed in it. Round 6 added it against one average.
Round 6b changed it to five:

- it reads the pool's spot tick, and the pool's tick cumulatives at 300, 240,
  180, 120, 60 and 0 seconds ago (`observe`, the pool's built-in price
  oracle). Those give five consecutive mean ticks of `TWAP_STEP` = 60 seconds
  each, covering the last `TWAP_WINDOW` = 300 seconds;
- if the spot is more than `MAX_TWAP_DRIFT` = 100 ticks (a tick is 1 bp, so
  about 1%) from ANY of the five, the swap reverts
  `PoolPushed(spotTick, twapTick)`, where `twapTick` is the mean furthest
  from the spot;
- if the pool cannot give those averages, the swap reverts `NoPriceHistory`:
  `observe` reverts (it does when the pool's oldest observation is younger
  than 300 seconds), or it answers the wrong number of values or a mean that
  is not a tick. A contract that is not a pool can also make the buy revert
  with no error name (return data that does not decode, or a `slot0` that
  reverts). Either way nothing is bought.

The three numbers are constants in the adapter, and the adapter is immutable
in the vault: nobody can widen the band, shorten the window or reduce the
number of averages. `ticks(pool)` is a view of the same read. It returns
three values, `(spot, low, high)`: the spot tick, and the lowest and the
highest of the five means. The spot is inside the band of every mean exactly
when `spot - low` and `high - spot` are both at most 100.

Why a push in the same transaction or block cannot pass: a pool of this kind
writes at most one observation per block, before the first swap of that block
that moves its tick, and from the tick it had before that swap. So a swap in
the same transaction, or anywhere in the same block, is in none of the
averages, and the whole push shows up as drift. This was checked in round 6,
against the single average, on the real NVDAc pool's code and state
(`Fork.test_Fork_APushOnTheRealPoolIsCaught`: on 2026-10-04 a 750,000 USDC
push moved the spot 719 ticks and the average by none), and on a mock pool
for the edges (`Round6.t.sol`, `Round6b.t.sol`).

**Why one average was not enough (R6-1).** Round 6 compared the spot with ONE
mean tick over the whole 300 seconds, and this file said that passing it
took holding the pool off-market "for most of five minutes", and that a push
of 5% "needs 240 seconds". That was false. The check is against a mean of
ticks, so what counts is tick-seconds, not time: a pool held 150 ticks off
passed after 100 of the 300 seconds, and a pool held far past the target
passed sooner in proportion. One 2-second block at about 87,600 ticks off,
or six blocks at 14,600, moved the 300-second mean far enough for a 6% push
to pass. Past the pool's real liquidity, moving the price further costs
almost nothing more, so one block at an extreme tick is affordable.

Both round-6 reviewers found this independently. It was confirmed on this
repository's mock pool, and on a Base fork with a pool made by the same
factory as the NVDAc pool and liquidity shaped like it. With a 100,000 USDC
installment 13 hours overdue and a feed print 20 hours old and 6% above the
pool, the attacker ended with 5,005,012 USDC from 5,000,000. That was the
six-block variant: the spike took 750,177 USDC of the attacker's own capital
and about 750 USDC in pool fees. Break-even was about 13,000 USDC of
executable installments at a 6% gap. Under the 5,000 USDC launch cap, at
that gap, the attack loses money. The admin can raise the cap and the
contracts cannot be changed, so it was rated Medium and the check was
tightened before any deploy. Round 6 bounded R5-2. It did not fix it, and round 6b does not
either.

What the check does **not** stop:

- **A push that ends inside the band.** In one transaction a caller can still
  cost a fill about 1% against the pool's own averages, on top of whatever
  the fill bound allows against the feed. `Round6.t.sol` pins the band's edge
  and what a push of exactly the band costs a plan, and
  `Round6b.test_R6b_TheBandHoldsAgainstEveryMinute` pins the band against
  each of the five. The band is on where the spot ENDS, not on how far it
  was moved: after an honest move to one edge of the band, a push to the
  other edge passes, a move of up to about 2%. The second re-review confirmed
  it on the mock pool: after an honest 100-tick move, a 197-tick push in the
  next block passed, and cost the plan 195 bps against the pool's honest
  price while staying inside the fill bound against the feed.
- **An off-market block in each of the five minutes.** Each average is still
  a mean of ticks. A pool left 15,000 ticks off for one 2-second block moves
  a 60-second average 500 ticks, the same as a pool held 500 ticks off for
  the whole minute. What five averages change is how many such blocks it
  takes. A single excursion lands in one minute's average (two, if it is left
  standing across the boundary between two minutes), the other minutes still
  disagree with the pushed spot, and the buy is refused
  (`Round6b.test_R6b_OneBlockAtAnExtremeTickNoLongerPasses`,
  `test_R6b_AnExcursionInFourOfTheFiveMinutesIsRefused`). An attacker who
  puts an off-market block inside EACH of the five minutes, sized so that
  each average lands in the band, still passes
  (`Round6b.test_R6b_AnExcursionInEveryMinuteStillPasses`). The first of
  those blocks has to be more than four minutes before the buy. Each one
  leaves the attacker's own capital in the pool across a block boundary,
  where anyone can trade against it. A push left standing for two blocks
  across a minute boundary counts in both minutes, so three pushes can do it;
  the pool is off-market for five blocks in all either way.
- **One push, held.** There is also a slow way: ONE push to the target, left
  standing for about 285 of the 300 seconds, moves all five averages to it
  and passes (confirmed on the mock pool in the second re-review). So against
  round 6 the five averages change the shape of the attack, not its floor.
  The fast way now takes five off-market blocks in three to five separate
  pushes, the first more than four minutes before the buy, where round 6 took
  one push of one to six blocks. The slow way costs one round trip of pool
  fees, as before, and leaves the capital exposed for minutes instead of
  seconds.
- **What it costs to pass, measured.**
  Measured in the second re-review, on a Base fork at block 52,221,245
  (Monday 2026-10-05 20:23 UTC): the real NVDAc pool's code and state, a
  stand-in token at the stock's address, the real vault and adapter, a feed
  whose last print is 20 hours old and 600 ticks (6.18%) above the pool, a
  buy 12 hours overdue, a stranger as caller, and nobody trading against the
  attacker, which is the attacker's best case. The attacker adds their own
  liquidity under the strike first; without it the pool is too thin past
  about 600 ticks for the strike to fill at all. The plan got 654 to 666 bps
  less stock than the untouched pool would have given.

  | Shape | Pushes | Block intervals exposed | USDC in per push | Paid over market per push, at risk | Pool fees |
  |---|---|---|---|---|---|
  | Five one-block pushes at 20,000 ticks | 5 | 5 | 543,800 | 25,600 | 2,713 |
  | Three pushes (2 + 2 + 1 blocks) | 3 | 5 | 543,800 | 25,600 | 1,628 |
  | One push to the print, held 300 s | 1 | 150 | 505,200 | 7,300 | 504 |

  The attacker's net result in USDC, by how much is executable on the route
  at once (all of it can be struck in one transaction):

  | Executable at once | Five pushes | Three pushes | Hold |
  |---|---|---|---|
  | 5,000 (the whole launch cap) | -2,315 | -1,255 | -166 |
  | 10,000 | -1,955 | -905 | +175 |
  | 50,000 | +890 | +1,862 | +2,863 |
  | 100,000 | +4,451 | +5,324 | +6,227 |

  So at a 6.2% gap the attack breaks even at about 7,600 USDC (hold), 24,000
  (three pushes) and 41,000 (five pushes), and loses money at the launch cap
  in every shape. At a 1.3% gap the shortfall was 215 bps, and the hold lost
  280 USDC at 5,000 and made 719 at 50,000. Not measured: whether anyone
  would in fact trade against the attacker, what block position costs, and
  anything on the real token's side. By arithmetic, not run: the hold cost
  about 500 USDC whatever the size of the buy, so the break-even falls as
  the gap widens, and a gap of about 10% would bring it down to the cap. The
  widest move between two consecutive prints on the four feeds in their
  first two months was 1.87%.

  **The five averages did not raise the break-even.** Round 6's figure, about
  13,000 USDC, was for a different shape with no added liquidity; the
  cheapest shape now is the hold, at about 7,600. What changed is how long
  the attacker's capital sits in the pool: 150 block intervals for the
  cheapest shape, where round 6 needed one to six. The cap is what keeps
  this unprofitable, and the admin can raise the cap.
- **Liquidity that leaves.** The re-review found that a small full-range
  position was what made the one-block version expensive on the NVDAc pool,
  and that it can be withdrawn. What any excursion costs is set by the pool's
  liquidity when it is made.
- **A pool contract that lies about its own history.** The route's pool is
  fixed at admission; the check trusts it to be a pool.

Passing the check is worth something only while the feed reads above the
market. With an accurate feed the fill bound already holds the buy to
`maxSlippageBps` of the real price, whatever the pool has been made to say.
When a feed is away from the market is the subject of *Stale feeds*.

What it costs:

- **Gas.** Round 6's single-average check added between 21,000 and 41,000 gas
  to a buy, measured on forks of the real pools. The five-average read costs
  about 80,000 more than the single one: a reviewer measured the read alone
  on the real NVDAc pool, cold, at 159,448 gas against 78,948.
- **A fast market stalls buys.** A pool that honestly moves more than about
  1% is refused too, for up to 300 seconds after the move. An execution in
  that window reverts `PoolPushed` and the plan waits, and a deposit whose
  first buy lands in it reverts whole, as in round 6
  (`Round6b.test_R6b_AnHonestStepClearsWithinTheWindow`). The wait is longer
  than round 6's. One average let a 2% step through after 150 seconds. With
  five, some of the oldest minute has to lie after the step, half of it for a
  2% step and nearly all of it for a large one, so any step past the band
  waits more than 240 seconds and at most 300.
- **A route can be stalled on purpose.** One excursion large enough to move
  one minute's average past the band makes every buy and every deposit on
  that route revert `PoolPushed` until that minute has left the window. It
  gains whoever does it nothing, costs them pool fees each time, and leaves
  exits untouched. Measured on the fork in the second re-review: one block
  at 3,030 ticks on the NVDAc pool costs 514 USDC in pool fees and refuses
  buys for 300 seconds (2,990 ticks refuses nothing), so about 6,000 USDC an
  hour per route, with about 8,800 USDC at risk across each block boundary.
  Round 6's equivalent cost 526 USDC. No cheap way to keep a route refused
  was found, and `NoPriceHistory` cannot be forced on these pools.
- **What it cost an honest market, on real history.** The same reviewer
  replayed the rule over each pool's own 2,048 observations (17 to 33 hours,
  ending at the fork block). NVDAc and GOOGLc were never refused. AAPLc was
  refused for 40 seconds and METAc for 74, both at Monday's US open, where
  one 300-second average would have refused 0 and 6 seconds. A retry clears
  it; a volatile day will see more.

The four launch pools hold 2,048 observations each, which covers 300 seconds
however often they trade; `scripts/verify-base-addresses.mjs` and
`Fork.test_Fork_TheFourPoolsAnswerTheirAverageAndSitInsideTheBand` re-check
that.

**A premium above the bound fails closed.** If the pool trades more than
`maxSlippageBps` over the feed (inside the 5% breaker, say 1.5% over a 1%
bound), no fill can reach `minOut` and every execution reverts. The plan waits
— its funds keep earning — until the premium comes back inside the bound or
admin raises the bound through the 48-hour queue. It never buys worse than the
bound (`Round2.test_D7_APremiumAboveTheBoundFailsClosed`).

**`createPlan`'s first buy fails closed too.** With a fresh feed, period 1
executes inside `createPlan`, under exactly the same bounds. If that buy
cannot fill inside them (`PoolDiverged`, `PoolPushed`, `NoPriceHistory`,
`SlippageExceeded`, a venue refusing below `minOut`), the whole deposit
reverts and no USDC moves: the depositor
keeps their money and can try again later. With a stale feed, which includes
every weekend, there is no first buy at all (see *Stale feeds*).

## Stale feeds

An execution with a stale feed **reverts `StaleOracle`**, on a weekday or a
weekend. Stale means `isFresh` is false: the last update is more than 24 hours
old, the timestamp is zero, the timestamp is in the future, it is the weekend
(see *The weekend* below), or the sequencer is down or came back less than an
hour ago (see *The sequencer* below). Coinbase B20 feeds are 24/5: they stop
printing for the weekend, and while the stock market is closed they hold
their last value.

**Outside the weekend, a frozen feed still reads fresh for 24 hours after its
last print.** That is what a 24-hour heartbeat means, and it was misstated
here before the 2026-10-04 review ("nothing is bought against a frozen
price"). For up to a day after the last print, at any time the weekend rule
does not cover, a buy can execute against that print: a deposit's first buy,
the plan owner's own call, a keeper's call, or anyone's call once a buy is 12
hours overdue. The fill is bounded at `maxSlippageBps` against **that
print**, not against where the market has moved since.

Until round 6 that could be exploited in one transaction: if the pool had
drifted below the print, a caller pushed it back up to the print, executed
the overdue buy there, and unwound, and the plan paid the old price for stock
that was now worth less. Measured on the live NVDAc pool, a push of that size
cost about $700 in pool fees, so with a 5% to 8% weekend gap it paid once the
overdue buys on one route added up to roughly $8,000. **The one-transaction
path is closed**: the pushed pool is away from its own recent averages, and
the swap adapter refuses it (`PoolPushed`; `Round6.t.sol`). Left alone, the
plan pays the pool's own price: under the print it simply buys cheaper, until
the pool is more than 5% away and the breaker makes the buy wait; more than
1% over the print, no fill reaches `minOut` and it waits too.

**The path across blocks is not closed.** Round 6's single average let it
through with one block left off-market (R6-1, in *The fill bound* above).
Round 6b did two things about it. The swap adapter's five averages mean one
block is no longer enough. And the oracle's weekend rule removes the weekly
occasion: the hours when the feed is frozen by design while the pools trade.

What is still exposed while a print is old but reads fresh:

- a buy executes at the pool's price whenever that price is inside the bounds
  of the old print. That is the design, and the fill is the pool's real price;
- a push that ends within 100 ticks (about 1%) of all five averages still
  passes, in the same transaction;
- a caller who leaves the pool off-market across at least one block boundary
  in each of the five minutes before the buy, or who holds one push for most
  of those five minutes, moves every average and passes the check. That
  takes their own capital (it cannot be borrowed for one transaction), left
  at a wrong price against anyone who trades it back, for five blocks at
  least, and it is the remaining way to make a plan buy at a stale print. It is not closed. **How much "anyone who trades it back" is
  worth while the stock market is shut is not known**: whoever normally keeps
  these pools in line may not be trading. On a weekend the question no
  longer arises, because nothing is bought. It still arises overnight on a
  weekday, between Friday's last print and Saturday 00:00 UTC, and on an
  exchange holiday. The buys exposed are the ones a caller can send in those
  hours: any due buy for a keeper key, and any buy 12 hours overdue for
  anyone. This should be weighed again before the cap is raised.

### The weekend

The freeze that comes every week is not left to the heartbeat. Since round 6b
the oracle is built with a flag, `closedOnWeekends` (immutable; `Deploy.s.sol`
passes `true`). With it set, `isFresh` is **false from Saturday 00:00 UTC to
Monday 01:00 UTC, whatever the feed says** (`weekendClosed()`,
`WEEKEND_LENGTH` = 49 hours). It is a date rule, not a reading: nothing a
caller or an admin does can move it
(`Round6b.test_R6b_WeekendBoundaries`,
`testFuzz_R6b_WeekendRuleMatchesTheCalendar`,
`test_R6b_NoBuyOnASaturdayEvenWithAFreshPrint`,
`test_R6b_WeekendRuleOffLeavesFreshnessAlone`).

Why: the B20 feeds stop for the weekend while the pools keep trading. Before
this rule the 24-hour heartbeat alone kept Friday's last print "fresh" well
into Saturday, which is exactly the gap between feed and market that R5-2 and
R6-1 need.

Where the window comes from. Both pages were read on 2026-10-05.

- Chainlink's market-hours page
  (https://docs.chain.link/data-streams/market-hours) lists the 24/5 US
  equities sessions and says the market is closed "weekends, holidays, or
  unexpected closures; ~8:00pm Fri–8:00pm Sun ET".
- The Coinbase B20 feeds page
  (https://docs.chain.link/data-feeds/tokenized-equity-feeds/coinbase) says
  "When underlying equity markets are closed (weekends, holidays, thin
  overnight windows), the feed holds the last close" and "These feeds do not
  have heartbeats during off-hours".

20:00 New York time is 00:00 UTC in summer and 01:00 UTC in winter, so one
fixed window in UTC covers both: it shuts an hour early on winter Fridays and
opens an hour late on summer Mondays.

What the chain showed, read on 2026-10-05 from the NVDAc feed
(`0x04689a41629776563E6822F76f2e57D148d28513`, rounds from 2026-09-18 on).
The first print after a weekend came at Monday 00:00:31 UTC on 2026-09-21,
00:00:23 on 2026-09-28 and 00:00:43 on 2026-10-05. The last Friday prints
were at 19:55:33, 19:55:23 and 17:08:11 UTC, and there was no print between
Saturday 00:00 and Monday 00:00 UTC on any of the three weekends. Weekday
gaps between prints ran up to 14.3 hours. (An earlier draft of this
paragraph gave 08:10:17, 18:38:19 and 15.8 hours. Those came from a read
that had silently lost one round in six to rate limiting; the re-review
caught it and all 108 rounds were read again.)

What it means for a user. A buy that falls due on a weekend waits until
Monday 01:00 UTC, or the next fresh print after it. A deposit on a weekend
opens the plan with no first buy, the same path as any stale feed; it does
not revert (`Round6b.test_R6b_ADepositOnAWeekendOpensAPlanWithNoFirstBuy`).
Exits are never affected.

What the rule does **not** cover:

- **Exchange holidays.** The feed holds its last value on a holiday too, and
  the rule knows nothing about them. The heartbeat is still the only limit
  there, so a print can read fresh for up to 24 hours into a holiday.
- **A change of schedule.** The rule cannot be changed. If the feeds one day
  print through the weekend, this vault still will not buy on one.
- **Weekdays.** The 24-hour heartbeat still means a weekday print can be many
  hours old. The feed prints on a 0.5% move or the heartbeat, and gaps of up
  to 14.3 hours were seen.

### The sequencer

Base is an L2. While its sequencer is down no feed prints, and when it comes
back the last print still reads fresh until the next one lands, with pools
that may not have been arbitraged yet. Since round 6 the oracle is built with
Chainlink's L2 sequencer uptime feed for Base
(`0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`, immutable in the oracle), and
`isFresh` is **false while that feed says the sequencer is down, and for
`SEQUENCER_GRACE` = 1 hour after it says it came back**. So the first hour
after a restart is covered: deposits open plans with no first buy, executions
revert `StaleOracle`, and exits are unaffected, exactly as on a weekend
(`Round6.test_R5_6_*`, `Fork.test_Fork_SequencerUptimeFeedIsReadAndGatesFreshness`).

**An uptime feed that cannot be read is ignored.** If it reverts, has no
code, answers fewer than five words or needs more than 100,000 gas, the
sequencer check passes and the price feed's own 24-hour heartbeat is the only
freshness check left. This is deliberate. The feed's address cannot be
changed, so a check that failed closed would let a feed Chainlink retires
halt every buy on every route for good. The cost is the other way round: if
that feed ever dies, there is no protection after an outage, and nothing on
chain announces it. Since round 6b `sequencerUp()` is a public view (it was
internal), so a monitor can see it: when it answers true while the uptime
feed itself cannot be read, the check has failed open
(`Round6b.test_R6b_SequencerUpIsWhatIsFreshUses`). Somebody has to be
watching. `scripts/verify-base-addresses.mjs` reads the feed the way the
oracle does and says so if it stops answering. A feed that answers, but with
something other than "up" (any answer but 0, or a restart time in the future),
reads as down.

The keeper (not in this repository) sends buys only in US market hours, and
on Base mainnet that gate cannot be switched off. That is still true, and it
is not what protects a weekend. It limits the keeper only: the owner can
execute their own plan, and anyone can execute a plan that is 12 hours
overdue. What stops a weekend buy for every caller is the oracle's weekend
rule. On an exchange holiday neither helps: the keeper has no holiday
calendar and the oracle has none either.

A **deposit** made while the feed is stale does not revert. The plan opens
already due, with no first buy, and the next fresh print executes it. Otherwise
the deposit button would fail every weekend. Outside the weekend, inside the
24 hours after the last print the feed is not stale, so the first buy is
attempted as usual.

`ChainlinkOracle.isFresh` **never reverts**. A feed that reverts (deprecated,
paused, access-controlled) or returns malformed data reads as not fresh. It
used to bubble the feed's revert, and `createPlan` asks `isFresh` before its
first buy, so a dead feed blocked deposits as well as executions. The uptime
feed is read the same bounded way (100,000 gas, at most 160 bytes copied), so
it cannot make `isFresh` revert either (`Round6.testFuzz_R5_6_IsFreshNeverRevertsAndFollowsTheRule`).
The weekend rule reads nothing: it is arithmetic on the block's timestamp.

`isFresh` and `latestPrice` read the feed through **one decoder**
(`ChainlinkOracle._read`), so they cannot disagree: `isFresh` true means
`latestPrice` answers. The decoder copies at most the 160 bytes of
`latestRoundData`'s five words, however much the feed returns, and treats as
garbage (not fresh; `latestPrice` reverts `BadPrice`):

- a feed that reverts or returns fewer than 160 bytes;
- a `roundId` or `answeredInRound` that does not fit in `uint80`;
- an answer ≤ 0 or above `MAX_PRICE` = 1e16 ($100,000,000 a share at 8
  decimals);
- `updatedAt` of zero or in the future.

Before round 3 each of these had a hole (`Round3.test_F3_*`): an out-of-range
round id read fresh and then reverted `latestPrice` inside the first buy, which
blocked deposits; an `int256.max` answer passed both reads and overflowed the
breaker's arithmetic into `Panic(0x11)`; and a feed returning as much data as
its gas allowed ran `isFresh` out of gas in the copy. The price ceiling is also
what keeps every product in `_minOut` far from overflow.

## The TVL cap

`tvlCap` bounds **outstanding principal**: the sum of every live plan's
`remainingPrincipal`. It does not count cumulative deposits. Each executed
slice and each exit frees room. To stop one plan holding the cap for free:

- `installment ≥ MIN_INSTALLMENT` = 1 USDC, and the LAST period is held to
  that too, at creation: a deposit that does not divide by the installment
  must leave a remainder of at least 1 USDC, or `createPlan` reverts
  `BadParams`. After a lending loss the last period spends whatever the
  plan's shares are still worth, which can be under 1 USDC. Before round 6
  the remainder could be 2 wei, which was a plan the cap barely counted and a
  last buy of nothing (`Round6.test_R5_5_*`).
- at most `MAX_PERIODS` = 120 installments per plan
- `MIN_INTERVAL` = 1 day ≤ `interval` ≤ `MAX_INTERVAL` = 366 days. A larger
  interval once wrapped `nextExecution` into the past. The cast is checked now.

**The cap is first come, first served.** Nothing reserves room for anyone.
Whoever deposits first holds it until their plan spends down or exits, and a
depositor who wants to hold it for longer can: 120 installments of at least
1 USDC, up to 366 days apart, is a legitimate plan. At launch the cap is $5,000
on mainnet, and a determined depositor can fill it; the answer is raising the
cap, not policing who is inside it.

## Losses and the final installment

A lending loss is **absorbed, never a revert**. An ordinary slice withdraws
`installment + accrued`. The final slice, or any slice the plan's shares can no
longer cover, **redeems every share the plan holds** and spends whatever comes
back. The missing part is reported as `PlanShortfall(id, shortfall)` and the
plan completes. Before this change, the last exact withdraw after any loss or
rounding drift asked for more shares than the plan held, and it reverted
`Panic(0x11)` on every retry. A one-period plan hit the same Panic at
creation.

**A plan no longer ends one period early from rounding alone.** It used to.
When the remaining principal was a few wei above one installment, and
ERC-4626 rounding had left the plan's shares worth a few wei less than that
principal, the second-to-last slice could not be covered by an exact withdraw.
It took the redeem-all path, spent everything, and the plan completed one
period early. Since round 6 the last period's principal is at least 1 USDC,
so the second-to-last slice takes that path only when the plan's shares are worth no
more than one installment: at least 1 USDC less than its principal. That is a
real loss, handled as the paragraph above says, not rounding
(`Round2.test_D7_RoundingCanNoLongerEndAPlanOnePeriodEarly`).

**A deposit that would receive no shares reverts** (`ZeroShares`,
`Round6.test_R5_8_ASupplyThatMintsNoSharesReverts`). The check refuses a
supply that mints exactly zero shares; one that mints a few share-units worth
less than the deposit is not caught, and is equally out of reach on the
pinned vault. How far out of reach has not been checked on chain. Round 5 put
the donation it would take at about 2e15 USDC. The round-6 re-review read
that figure as an empty vault and a 2,000 USDC deposit, and put it at about
1e12 USDC for the 1 USDC minimum and far more on the live vault, by
arithmetic it did not check.

## Exits

`exitPlan` is not pausable, not delayed and not upgradeable. It never reverts
because the position is worth less than principal: the owner receives what the
shares redeem for, and the gap is reported as `shortfall`.

It **does revert `InsufficientAdapterLiquidity` when the lending market is at
100% utilisation** and cannot pay the whole position. There is no partial exit.
The owner waits for borrowers to repay. The position keeps earning meanwhile,
and nobody else can take it. We state this plainly rather than add a
partial-exit path.

## Fees

Fees accrue in the vault (`feesAccrued`), and `claimFees()` pays them out. The
vault never pushes a fee during an execution or an exit, so a `feeRecipient` on
USDC's blocklist cannot block either one. Admin moves the recipient with
`setFeeRecipient`, which refuses the zero address, the vault itself, both
adapters and, since round 6b, the oracle: fees paid to any of those could
never be moved again (`Round6.test_R5_9_*`,
`Round6b.test_R6b_TheFeeRecipientCannotBeTheOracle`). That list is not
complete and cannot be. A pool, a stock token, or any other contract that
cannot send USDC on is still accepted, and fees claimed to it are lost. That
costs the fee recipient its fees and nobody else anything. The vault's USDC
balance is always exactly the unclaimed fees plus anything donated to it
(`HardInvariants.invariant_vaultUsdcIsDonationsPlusFees`).

## Worst case per key

**Keeper key stolen.** The thief pays gas to do what the keeper was going to do
anyway. They choose the block of an execution that is already due, which is
worth at most `maxSlippageBps` against the feed on that fill. Against the
feed is not against the market: while a print is old but reads fresh, a
keeper key can do what *Stale feeds* describes without waiting 12 hours for
the buy to be overdue. Like everyone else, it cannot buy on a weekend. They
cannot redirect funds. Admin revokes the key with `setKeeper(k, false)`.

**Deployer key, between the deploy and the multisig's `acceptAdmin`.** The
handover is two steps, so until the multisig accepts, the deployer EOA is still
admin of the vault and the oracle. The setup window is already closed, so it
cannot list a route or loosen a bound instantly, but it holds every instant
power below, and one that matters on launch day: it can lift the pause the
deploy left on deposits. **What it sets in that window stays set after the
multisig accepts**: a fee, a fee recipient, a keeper, a raised cap, a queued
route or feed. So accepting is not enough. After the accept, every setting is
read back, and the deployer's transaction count is checked to be exactly the
deploy's. The window is as short as the deployer makes it (accept the same
day, before anything else), and the vault holds nothing while deposits are
paused.

**Vault admin compromised.** Instantly, the attacker can:

- pause deposits and disable routes. Buys stop. Funds stay in the lending
  market earning yield. Exits are unaffected.
- raise the fee to 10% of *yield*. It applies to yield already earned and not
  yet harvested, because the fee is computed at harvest.
- tighten the fill bounds, which can only make executions wait. Set to zero,
  they halt every buy at once, and undoing it takes the 48-hour queue.
- point fees at themselves, and claim what has accrued.
- add keepers, who can only pick the block.
- raise `tvlCap` without limit and unpause. The cap is enforced against
  depositors, not against the admin.
- cancel honest queued changes.
- keep the role: `transferAdmin` then `acceptAdmin` from an address they hold.
  Two steps protect against a typo, not against theft, and there is no way to
  take the role back.

Raising the slippage bound to 2% (which, with a colluding keeper or a sandwich,
costs a plan at most 2% of each fill against the feed) is **queued**: visible
for 48 hours (`BoundsQueued`) before it can take effect. So is a new or
re-enabled route, which only affects plans created on that route id later. A
queue the attacker finds already pending is no help to them: it expires 7 days
after its eta, and a `disableRoute` drops a pending re-enable. Existing
plans cannot be moved to another token or pool. The attacker cannot touch
`exitPlan`, so every user can leave with their principal and yield at any time
the lending market can pay.

**Oracle admin compromised.** The attacker can list feeds for tokens no route
uses, which has no effect. A feed change for a live token becomes visible
(`FeedQueued`) 48 hours before it takes effect, and users can exit in that
window. A feed change queued long ago and left dormant cannot be sprung later:
it expired 7 days after its eta. Once active, a bad feed misprices `minOut` for that route. That is the
reason for the delay. Disabling the route (instant, on the vault) stops it. A
mispriced `minOut` alone moves no money: the pool still fills at its own
price, and the breaker stops buys while the bad feed is more than 5% from the
pool. To take anything, the attacker also has to move the pool, which is the
next paragraph.

**Both roles at once, which is the launch configuration.** The deploy hands
the vault's admin and the oracle's admin to the SAME multisig, so the two
paragraphs above are one key, and its worst case is larger than either says.
The vault prices off whatever feed the oracle currently has for the token; it
does not re-check the route's own `feed` at execution. A compromised multisig
queues a feed of its own that mirrors the real price for the 48 public hours,
activates it, and makes itself a keeper. From then on its feed says whatever
it likes, and the breaker and the fill bound, which both compare with the
feed, say nothing.

Until round 6 it could then, in one transaction, set its feed's price, push
the pool to match, execute, and unwind. Confirmed on mocks in the 2026-10-04
review: a 10,000 USDC installment bought 1% of what it should have. **That
transaction now reverts `PoolPushed`**: the feed is the attacker's, but the
pool's recent averages are not, and the swap adapter will not buy from a pool
more than about 1% away from any of them (`Round6.t.sol`).

What that key can still take, after a 48-hour public feed rotation:

- in one transaction, a push of up to 100 ticks: about 1% of each due
  installment;
- more than that, at whatever price its feed names, by leaving the pool
  off-market across at least one block boundary in each of the five minutes
  before the buy, or by holding one push for most of those five minutes (see
  *The fill bound*). That is its own capital, at risk to anyone who trades
  the pool back, for five blocks at least, for one due installment per plan.
  Under round 6's single average one push of one to six blocks was enough.
  This is a different shape, not a bar.

The limit is still **one due installment per plan per interval**, plus the
yield swept with it. Principal not yet due stays in the lending market and
`exitPlan` still works, so the defence is the one the delay exists for:
`FeedQueued` is public for 48 hours, and a user who sees a feed change they do
not recognise exits. "Disabling the route stops it" assumes the vault's admin
is not the attacker. A queued feed is only as trustworthy as the check that it
is a real Chainlink proxy, which nothing on chain makes.

**This is a disclosed risk, and round 6b left it one (R5-1).** The route's
feed is not pinned in the vault, and the deploy still hands the vault's admin
and the oracle's admin to the same multisig. Giving the two roles to two keys
would not remove the power, because the oracle's admin alone can queue a
feed change, and after it anyone can execute a buy that is 12 hours overdue.

Pinning the route's feed in `_minOut`, so that a rotation would also have to
pass the vault's own queue, is **deliberately not done**. It would add a
second public queue, but it does not stop a key that holds both roles, which
is the launch configuration: that key passes both queues. And it would make
every legitimate feed rotation stall buys on the route until the route was
re-queued and activated too. The push check bounds the same attack without
either cost. Pinning pays for itself only where the two roles are held by
different keys, and this deployment is not that.

**Deployer EOA compromised after launch.** The deploy script calls
`transferAdmin(multisig)` on the vault and the oracle, but the handover is
two-step. **Until the multisig calls `acceptAdmin()` on both, the deployer is
still admin.** Accept promptly and check `admin()` on both contracts. After
that, the deployer can do nothing new, but anything it set before the accept
is still set (see above). The script's last call is `finishSetup`, so
even before the multisig accepts, the deployer has no instant route or
loosening power left: only the powers in the table above.

## Accepted findings (Slither)

**`reentrancy-no-eth` in `_execute`/`_draw`, `exitPlan` and `createPlan`.**
State is written after `adapter.withdraw()`/`redeem()`, because the share count
comes from that call. This is accepted because every external entry point that
moves money (`createPlan`, `executeDCA`, `exitPlan`, `claimFees`) carries
`nonReentrant`, and the only cross-function reader of `plans` is `planYield`, a
`view`. The plan is fully advanced before the swap, the one call that reaches an
admitted venue. The adapter is immutable, so no new adapter can be admitted.

**`reentrancy-balance` in `AerodromeSwapAdapter.swapExactIn`** (Slither rates
it High; it is new with the C10 fix). The adapter reads the owner's stock balance,
calls `pool.swap`, and then reads the balance again. That is the fix itself: the
adapter measures what arrived instead of trusting what the pool reports. The
"stale balance" Slither warns about is the *before* value, and the code only
ever uses it to take the difference. Re-entry cannot make that difference
larger than what actually reached the owner:

- `swapExactIn` is callable only by the vault, and every vault entry point that moves money is
  `nonReentrant`.
- The swap callback pays only the active pool, and only exactly `amountIn`,
  and only **once**: it disarms itself (`_activePool`, `_expectedIn` cleared)
  before paying, so a pool that calls back a second time to sweep stray USDC
  in the adapter reverts `BadCallback`, and a swap whose callback never ran
  reverts too.
- Stock that a re-entrant path sends to the owner is still the owner's stock.

A venue that sends less than `minOut` reverts the whole execution.

**`unused-return`.** This finding predates the plan and is now documented.
`slot0()`'s other fields and `latestPrice`'s `updatedAt` inside the vault
are not needed (since round 6 the swap adapter does read `slot0`'s tick, and
ignores the second array `observe` returns, the seconds-per-liquidity
cumulatives). Freshness comes from `isFresh`, which applies the heartbeat,
the zero-timestamp and the future-timestamp checks in one place. (Since round
3 the oracle reads `latestRoundData` itself in assembly and range-checks
`roundId` and `answeredInRound` too; a price feed's `startedAt` is unread,
and of the uptime feed only `answer` and `startedAt` are read.) The one
return value that mattered, the assets `adapter.withdraw` actually delivered,
is used now: the vault spends what arrived, not what it asked for.

**`assembly` in `ChainlinkOracle._read`, `ChainlinkOracle.sequencerUp` and
`DcaVault._checkRoute`** (Informational, new in round 3; it replaces round 2's
`low-level-calls` on the same reads). Each is one `staticcall` with a fixed-size output buffer,
which is the point: Solidity's `staticcall` copies *all* return data into
memory, and a feed or token that returns a megabyte runs the caller out of
gas in the copy (F3). `_read` gives the feed 100,000 gas (a real proxy needs under 20k; a feed that needs more reads as not fresh instead of running the caller's transaction out of gas, round 4), copies at most 160 bytes and decodes the five
words with explicit range checks, so a dead or garbage feed is `false`, never
a revert (D4). Round 6's `sequencerUp` (internal as `_sequencerUp` then,
public since round 6b) reads the uptime feed with the same block: 100,000
gas, 160 bytes, and an unreadable feed is a `true` (see *The sequencer*). `_checkRoute` gives the `decimals()` probe 50,000 gas and one
word, so a token whose code cannot run in this EVM burns only that (F1).
Neither can change state. `SafeTransfer`'s `low-level-calls` are unchanged
and predate the plan.

**`timestamp` comparisons.** These are inherent to a scheduler. The worst a
Base sequencer could do is move `nextExecution` by seconds on a
one-day-or-longer interval. The 48-hour delays and the 7-day activation
windows (`_checkWindow`) are likewise measured in seconds, and so are the
one-hour sequencer grace and, since round 6b, the two edges of the weekend
window.

**`weak-prng` on `ChainlinkOracle.weekendClosed`** (Slither rates it High;
new in round 6b). The detector fires on any `block.timestamp % n`. Nothing
here is random and nothing is drawn: the expression is the place of the
current second in the week, compared with a constant, and it decides one
thing, whether buys are refused. A sequencer that shifts a timestamp by
seconds moves the two edges of the weekend window by those seconds, as under
`timestamp` above. `Round6b.testFuzz_R6b_WeekendRuleMatchesTheCalendar` holds
the expression to the calendar.

**`missing-zero-check` on `ChainlinkOracle`'s `sequencerUptimeFeed`** (Low,
new in round 6). Zero is a value there on purpose: it switches the sequencer
check off, for local and test chains, which have no such feed. What stands in
for the check is that the mainnet script passes Base's feed, which
`ForkDeploy.t.sol` asserts on the deployed oracle and
`scripts/verify-base-addresses.mjs` asserts on the script.

**Mythril on `ChainlinkOracle`** (run in round 6b on the creation bytecode
with the mainnet constructor arguments; ten results, two rated Medium). All
ten are the design, seen from the bytecode:

- *Unchecked return value from external call* (SWC-104, Medium, twice): the
  two bounded reads, of the price feed in `_read` and of the uptime feed in
  `sequencerUp`. The return value is checked. What Mythril reports is that
  execution continues when the call fails, and it does, on purpose: a price
  feed that cannot be read is an answer of "not fresh", and an uptime feed
  that cannot be read is an answer of "up" (*The sequencer*, fails open).
- *Dependence on predictable environment variable* (SWC-116, Low, seven
  times): the heartbeat, the future-timestamp checks, the sequencer grace and
  the weekend window. The same argument as `timestamp` above.
- *Multiple calls in a single transaction* (SWC-113, Low): `isFresh` reads
  the price feed and then the uptime feed. Both are `staticcall`s with a gas
  bound, and neither can make `isFresh` revert.

The same run reported nothing for `AerodromeSwapAdapter`, and nothing for
`DcaVault` within its time limit of 900 seconds, which it reached: that run
is not exhaustive.

## The Base Sepolia demo

The testnet deploy (`Deploy.sepolia.s.sol`) runs on the demo mocks, and its
threat model is a passer-by with free gas. The deployment recorded in
`contracts/deployments/baseSepolia.json` was made before round 6: its vault
does not have round 6's three vault changes, and its swap adapter and oracle
are stand-ins that never had the other two. It has none of round 6b either:
its vault accepts the oracle as fee recipient, and the stand-ins have neither
the five-average check nor the weekend rule.

- **The lending mock answers only to the vault.** `DemoYieldAdapter` used to
  inherit the test mock's open `supply`/`redeem`/`withdraw`, so anyone could
  withdraw every visitor's pooled demo USDC, after which every exit panicked.
  It is now bound at construction to the vault address the deploy script
  predicts, like `MorphoAdapter`, and can never be re-bound. The test mocks
  (`MockYieldAdapter`, `MockRebasingAdapter`) carry the same gate, bound by
  their deployer.
- **The faucet has a global daily budget.** `DemoUSDC.drip` pours 1,000 USDC
  per address per 4 hours, and all addresses together at most
  `DAILY_BUDGET` = 100,000 USDC per UTC day (`FaucetDry`). A per-address limit
  alone was no limit: one transaction deploying 253 one-drip contracts filled
  the old $250,000 cap. The demo cap is now $100,000,000, which the deploy
  script asserts is at least a year of the whole budget. The cost is that a
  Sybil can empty one day's faucet; visitors then wait for the next UTC day,
  and `dripReadyAt` says when.
- **The fixed UTC day allows a burst at midnight.** The budget resets at
  00:00 UTC, so 100 drips at 23:59:59 and 100 more at 00:00:00 pour twice the
  daily budget inside two seconds (`Round3.test_F7_TheFaucetBurstsAtMidnight`).
  The per-day total never exceeds `DAILY_BUDGET`; a
  rolling window would close the burst, and for demo dollars it is not worth
  the code.
- **One large transaction a day can keep the faucet dry.** A contract that
  deploys 100 one-drip children takes the whole day's budget in one
  transaction (about 10M gas on the Sepolia fork). Repeated just after every
  UTC midnight, it leaves the faucet dry for everyone else, every day. The
  damage is bounded: the attacker gets demo dollars, the cap is a thousand
  days of budget away, and a visitor who finds the faucet dry sees when it
  refills (`dripReadyAt`). The owner can mint around it by hand
  (`Round3.test_F7_OneTransactionCanTakeADaysBudget`).
- **`DEMO_OWNER` gets the vault too.** With `DEMO_OWNER` set, the deploy
  hands every demo contract to it, and now also calls the vault's
  `setFeeRecipient(owner)` and `transferAdmin(owner)`. The vault handover is
  two-step: `DEMO_OWNER` must call `acceptAdmin()`, and until it does the
  deployer is still the vault's admin (`DeployScripts.t.sol`).
- The switches (pause, blocklist, share price, price, freshness, haircut) are
  owner-gated, and `mint` is limited to the owner and the yield adapter.

## Residual risks, stated rather than solved

- **No audit.** Mitigated by a $5,000 cap at launch, the author's own funds
  first, and public source. Not by confidence. The cap is enforced by the
  contract against depositors; the admin can raise it at any time.
- **A buy has never been executed on a real chain.** B20 tokens are
  precompiles and cannot run on a fork. The whole path (deposit, lend, buy the
  real NVDAc from the real pool, exit) has been run against live Base state as
  a read-only simulation, and passes. That is not a mined transaction.
- **Outside the weekend, a print is good for 24 hours.** See *Stale feeds*.
  From Saturday 00:00 UTC to Monday 01:00 UTC nothing is bought (round 6b).
  At any other time a buy can still execute against a print up to 24 hours
  old, at the pool's own price: overnight on a weekday (gaps of up to 14.3
  hours between prints were seen), between Friday's last print and Saturday
  00:00 UTC, and on an exchange holiday. Pushing the pool to the print in
  the same transaction no longer works (round 6).
- **Exchange holidays are not covered.** The weekend rule is a date rule and
  knows no holidays. On one, the feed holds its last value while the pools
  keep trading, and the 24-hour heartbeat is the only limit: a print can read
  fresh for up to 24 hours into a holiday. The keeper has no holiday calendar
  either. A Monday holiday is covered in practice, because Friday's print is
  past the heartbeat by the time the weekend rule opens (seen on chain over
  Labor Day 2026: all four feeds were silent from Friday 2026-09-04 until
  Tuesday 00:00 UTC). A Friday or mid-week holiday is not: Thanksgiving is
  a Thursday, and 25 December 2026 and 1 January 2027 are both Fridays.
  Nothing pauses buys for a day: `disableRoute`
  is instant, but switching a route back on waits 48 hours, and tightening
  the bounds does not help, because both are measured against the feed.
- **A buy that fell due on a weekend is open to anyone the moment the weekend
  ends.** `grace`, the 12 hours a keeper has before anyone may send a buy,
  counts from the time the buy fell due, not from the time it could first
  execute. A buy due between Saturday 00:00 and Sunday 13:00 UTC is already
  12 hours overdue at Monday 01:00:00, so a stranger can send it in the first
  block anyone can, and can push the pool inside the band first. A weekly
  plan opened on a Saturday is in that state for every buy. The cost to the
  plan is what any stranger's push costs, under 1% of the buy (94 bps in the
  second re-review's test), and at the pools' measured depth the pool fees
  for it (320 to 563 USDC to move 100 ticks and back) exceed the gain until
  about 34,000 to 60,000 USDC is executable on one route at once. Round 6b
  introduced this by closing the weekend. Not fixed; the fix is designed
  (`docs/hardening-plan.md`, Round 6b, R6b-1) and is to be decided before
  mainnet.
- **The weekend calendar cannot be changed.** The rule and its 49-hour window
  are fixed in the oracle, and the oracle is immutable in the vault. If the
  feeds one day print through the weekend, this vault still will not buy on
  one. The window is fixed in UTC, so it shuts an hour before the feeds do on
  winter Fridays and opens an hour after them on summer Mondays. In winter it
  opens in the same second the feeds do, with no hour in between: only the
  heartbeat holds a buy back until the week's first print. That has not been
  seen on chain yet; these feeds have existed only since August 2026.
- **The push check is against averages, and averages can be moved (R5-2 and
  R6-1: bounded, not closed).** A push that ends within about 1% of all five
  averages passes it, in one transaction. So does a larger one by someone who
  leaves the pool off-market across at least one block boundary in each of
  the five minutes before the buy, with their own capital in the pool each
  time: at least five off-market blocks, or one push held for most of the
  five minutes. Measured on a fork with nobody trading against the attacker
  and a feed 6.2% above the pool, the cheapest shape (one push, held) breaks
  even at about 7,600 USDC of buys executable at once and loses money at the
  5,000 USDC launch cap; the five averages did not raise that figure, they
  lengthened the time the attacker's capital is exposed (*The fill bound*
  has the table). Nothing in the contracts prevents it, and while the stock
  market is shut there may be little arbitrage to face. It pays only while
  the feed reads above the market. **The cap is the control, and the admin
  can raise the cap at once.** See *The fill bound* and *Stale feeds*. A
  stronger check was considered and not built (`docs/hardening-plan.md`,
  Round 6b). To be weighed again before the cap is raised.
- **A fast market stalls buys.** A pool that honestly moves more than about 1%
  is refused like a pushed one for up to 300 seconds, until all five of its
  one-minute averages have caught up. Executions wait and a deposit made in
  that window reverts whole. Anyone willing to pay the pool fees can cause
  the same stall on a route on purpose. No money is at risk; buys are late.
- **After a sequencer outage, the first hour is covered and no more.** Prices
  do not count as fresh while the sequencer is down or for an hour after it
  restarts. If the pools are still off-market after that hour, the fill bound
  and the push check are what is left. And if Chainlink's uptime feed itself
  stops answering, the check is off and nothing on chain announces it:
  `sequencerUp()` is public so that a monitor can notice, and somebody has to
  run one (see *The sequencer*).
- **One multisig holds both admin roles (R5-1: disclosed, bounded, not
  removed).** See *Worst case per key*. After a public 48-hour feed rotation
  that key can cost a plan about 1% of a due installment in one transaction,
  and up to the whole of one due installment per plan per interval by
  leaving a pool off-market for a block in each of five minutes. Two separate
  keys would not remove that power.
- **Nothing can be swept.** USDC or shares sent to the vault or an adapter by
  mistake stay there, and so would any incentive tokens a lending market paid
  to the adapter's address. Plans earn the base rate only. Fees claimed to a
  recipient that cannot send USDC on are lost the same way: `setFeeRecipient`
  refuses the vault, its two adapters and its oracle, and no other contract.
- **Yield adapter risk is not diversified.** One lending market holds every
  plan's idle capital, and the adapter is immutable. Gauntlet USDC Prime was
  chosen for zero B20 stock-collateral exposure, but a MetaMorpho bad-debt
  event still hits every plan. The ledger turns that into a proportional
  shortfall, not a revert. That holds because the pinned vault is MetaMorpho
  v1.0, which marks bad debt into its share price; a v1.1 vault keeps the
  share price up, and there early exits would be paid in full and late ones
  would revert.
- **Route venue risk.** There is one Aerodrome pool per ticker. The fill bound
  and the push check cap what a manipulated pool can take from a fill. They do
  not protect against a pool contract exploit, and the push check takes the
  pool's word for its own price history.
- **Oracle dependency.** If Chainlink halts a B20 feed, executions revert
  `StaleOracle` and funds stay in the lending market earning yield. A halt
  stalls buys. It does not lose funds.
- **Aave rounding dust** (only if `AaveAdapter` is ever used; the launch
  deploy uses Morpho). Aave's redeem can burn fewer scaled units than the
  ledger debits. The leftover stays in the adapter, owned by no plan. It is the
  protocol's, never a user's shortfall (`ForkHard`).
- **The vault never holds the stock token**, so B20's issuer pause switch and
  transfer blocklist can only revert an execution, never strand a position.
