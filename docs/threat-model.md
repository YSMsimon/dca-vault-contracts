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
hands the vault to `DEMO_OWNER` too.

## Actors

| Actor | Can do | Cannot do |
|---|---|---|
| **Plan owner** | Create a plan. Execute their own plan from the moment it is due. Exit at any time the lending market can pay (see *Exits*). | Touch another plan. Execute before `nextExecution`. |
| **Keeper** (allowlisted by admin) | Call `executeDCA` on any plan from the moment it is due. There is no grace wait for a keeper. | Change the asset, the amount, the destination or the schedule. Withdraw anything. Execute before `nextExecution`. |
| **Anyone** | Call `executeDCA` once `nextExecution + grace` has passed (`grace` = 12 hours, a constant). Call `claimFees()`, which pays the current `feeRecipient` and nobody else. | The same limits as a keeper. |
| **Vault admin** | The instant and delayed powers listed below. | Move user funds. Touch `exitPlan`. Change a route's token or pool. Swap the adapter, swapper or oracle, which are immutable. Upgrade anything, because there is no proxy. |
| **Oracle admin** | List a feed for a token that has none (instant). Queue a feed change for a **listed** token (48 hours, then a 7-day window to activate it). | Change a listed token's feed without the 48-hour delay. Activate a queued change after its window has closed. Queue a change for an unlisted token (`NoFeed`). |
| **Route venue** (pool) | Receive exactly `spend` USDC and deliver stock to the owner. | Fill below `minOut`. The adapter measures what the owner actually received, and the vault checks it again. Collect more or less than `amountIn`. |
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
| `setFeeRecipient` | instantly | non-zero |
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
who moves the pool inside the band in the same transaction passes it. What
holds against that caller is the fill bound above, which is measured against
the feed.

**A premium above the bound fails closed.** If the pool trades more than
`maxSlippageBps` over the feed (inside the 5% breaker, say 1.5% over a 1%
bound), no fill can reach `minOut` and every execution reverts. The plan waits
— its funds keep earning — until the premium comes back inside the bound or
admin raises the bound through the 48-hour queue. It never buys worse than the
bound (`Round2.test_D7_APremiumAboveTheBoundFailsClosed`).

**`createPlan`'s first buy fails closed too.** With a fresh feed, period 1
executes inside `createPlan`, under exactly the same bounds. If that buy
cannot fill inside them (`PoolDiverged`, `SlippageExceeded`, a venue refusing
below `minOut`), the whole deposit reverts and no USDC moves: the depositor
keeps their money and can try again later. With a stale feed there is no first
buy at all (see *Stale feeds*).

## Stale feeds

An execution with a stale feed **reverts `StaleOracle`**, on a weekday or a
weekend. Stale means `isFresh` is false: the last update is more than 24 hours
old, the timestamp is zero, or the timestamp is in the future. Coinbase B20
feeds are 24/5 and stop printing at Friday's close.

**A frozen feed still reads fresh for 24 hours after its last print.** That is
what a 24-hour heartbeat means, and it was misstated here before the
2026-10-04 review ("nothing is bought against a frozen price"). For up to a
day after the last print, a buy can execute against that print: a deposit's
first buy, the plan owner's own call, or anyone's call once a buy is 12 hours
overdue. The fill is bounded at `maxSlippageBps` against **that print**, not
against where the market has moved since. If the pool has drifted below the
print, a caller can push it back inside the bound, execute, and unwind in one
transaction, and keep the difference. Measured on the live NVDAc pool, a push
of that size costs about $700 in pool fees, so with a 5% to 8% weekend gap it
pays only once the overdue buys on one route add up to roughly $8,000. Under
the $5,000 cap it does not pay. **It has to be closed before the cap is
raised**: the fix is to read the pool through a short time-weighted average,
which a same-transaction push cannot move. The same window opens after a
sequencer outage, because there is no sequencer-uptime check.

The keeper (not in this repository) sends buys only in US market hours, and
on Base mainnet that gate cannot be switched off. That limits the keeper. It
does not limit the owner, or a stranger after the 12-hour grace, and the
keeper has no holiday calendar.

A **deposit** made while the feed is stale does not revert. The plan opens
already due, with no first buy, and the next fresh print executes it. Otherwise
the deposit button would fail every weekend. Inside the 24 hours after the
last print the feed is not stale, so the first buy is attempted as usual.

`ChainlinkOracle.isFresh` **never reverts**. A feed that reverts (deprecated,
paused, access-controlled) or returns malformed data reads as not fresh. It
used to bubble the feed's revert, and `createPlan` asks `isFresh` before its
first buy, so a dead feed blocked deposits as well as executions.

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

- `installment ≥ MIN_INSTALLMENT` = 1 USDC. The LAST period is not held to
  that: a deposit that does not divide leaves a tail as small as 2 wei, which
  is a plan the cap barely counts and a buy of nothing (2026-10-04 review,
  open). The fix is one line in `createPlan`, refusing a tail under the
  minimum. The web app rounds the installment up, so it never makes one.
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

**A plan can end one period early from rounding alone.** If the remaining
principal is a few wei above one installment and ERC-4626 rounding has left the
plan's shares worth a few wei *less* than that principal, the second-to-last
slice already cannot be covered by an exact withdraw, so it takes the redeem-all
path: it spends everything the plan has, reports a shortfall of a few wei, and
completes. The owner receives all of their money's worth of stock one period
sooner, less those wei (`Round2.test_D7_ALastSliceCanEndOnePeriodEarlyByWei`).

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
`setFeeRecipient`. The vault's USDC balance is always exactly the unclaimed
fees plus anything donated to it (`HardInvariants.invariant_vaultUsdcIsDonationsPlusFees`).

## Worst case per key

**Keeper key stolen.** The thief pays gas to do what the keeper was going to do
anyway. They choose the block of an execution that is already due, which is
worth at most `maxSlippageBps` against the feed on that fill. They cannot
redirect funds. Admin revokes the key with `setKeeper(k, false)`.

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
reason for the delay. Disabling the route (instant, on the vault) stops it.

**Both roles at once, which is the launch configuration.** The deploy hands
the vault's admin and the oracle's admin to the SAME multisig, so the two
paragraphs above are one key, and its worst case is larger than either says.
The vault prices off whatever feed the oracle currently has for the token; it
does not re-check the route's own `feed` at execution. A compromised multisig
queues a feed of its own that mirrors the real price for the 48 public hours,
activates it, makes itself a keeper, and then in one transaction sets its
feed's price, pushes the pool to match, executes, and unwinds. The breaker
sees no deviation. Confirmed on mocks in the 2026-10-04 review: a 10,000 USDC
installment bought 1% of what it should have. The limit is **one due
installment per plan per interval**, plus the yield swept with it. Principal
not yet due stays in the lending market and `exitPlan` still works, so the
defence is the one the delay exists for: `FeedQueued` is public for 48 hours,
and a user who sees a feed change they do not recognise exits. "Disabling the
route stops it" assumes the vault's admin is not the attacker. A queued feed
is only as trustworthy as the check that it is a real Chainlink proxy, which
nothing on chain makes. Pinning the route's feed in `_minOut`, so a rotation
also has to pass the vault's own queue, would make splitting the two roles
mean something; it is not done.

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
`slot0()`'s other five fields and `latestPrice`'s `updatedAt` inside the vault
are not needed. Freshness comes from `isFresh`, which applies the heartbeat,
the zero-timestamp and the future-timestamp checks in one place. (Since round
3 the oracle reads `latestRoundData` itself in assembly and range-checks
`roundId` and `answeredInRound` too; only `startedAt` is unread.) The one
return value that mattered, the assets `adapter.withdraw` actually delivered,
is used now: the vault spends what arrived, not what it asked for.

**`assembly` in `ChainlinkOracle._read` and `DcaVault._checkRoute`**
(Informational, new in round 3; it replaces round 2's `low-level-calls` on the
same two reads). Both are one `staticcall` with a fixed-size output buffer,
which is the point: Solidity's `staticcall` copies *all* return data into
memory, and a feed or token that returns a megabyte runs the caller out of
gas in the copy (F3). `_read` gives the feed 100,000 gas (a real proxy needs under 20k; a feed that needs more reads as not fresh instead of running the caller's transaction out of gas, round 4), copies at most 160 bytes and decodes the five
words with explicit range checks, so a dead or garbage feed is `false`, never
a revert (D4). `_checkRoute` gives the `decimals()` probe 50,000 gas and one
word, so a token whose code cannot run in this EVM burns only that (F1).
Neither can change state. `SafeTransfer`'s `low-level-calls` are unchanged
and predate the plan.

**`timestamp` comparisons.** These are inherent to a scheduler. The worst a
Base sequencer could do is move `nextExecution` by seconds on a
one-day-or-longer interval. The 48-hour delays and the 7-day activation
windows (`_checkWindow`) are likewise measured in seconds.

## The Base Sepolia demo

The testnet deploy (`Deploy.sepolia.s.sol`) runs on the demo mocks, and its
threat model is a passer-by with free gas.

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
- **Friday's price is good for 24 hours.** See *Stale feeds*. Does not pay
  under the launch cap; has to be fixed before the cap is raised.
- **One multisig holds both admin roles.** See *Worst case per key*.
- **Nothing can be swept.** USDC or shares sent to the vault or an adapter by
  mistake stay there, and so would any incentive tokens a lending market paid
  to the adapter's address. Plans earn the base rate only.
- **Yield adapter risk is not diversified.** One lending market holds every
  plan's idle capital, and the adapter is immutable. Gauntlet USDC Prime was
  chosen for zero B20 stock-collateral exposure, but a MetaMorpho bad-debt
  event still hits every plan. The ledger turns that into a proportional
  shortfall, not a revert. That holds because the pinned vault is MetaMorpho
  v1.0, which marks bad debt into its share price; a v1.1 vault keeps the
  share price up, and there early exits would be paid in full and late ones
  would revert.
- **Route venue risk.** There is one Aerodrome pool per ticker. The fill bound
  caps what a manipulated pool can take from a fill. It does not protect
  against a pool contract exploit.
- **Oracle dependency.** If Chainlink halts a B20 feed, executions revert
  `StaleOracle` and funds stay in the lending market earning yield. A halt
  stalls buys. It does not lose funds.
- **Aave rounding dust** (only if `AaveAdapter` is ever used; the launch
  deploy uses Morpho). Aave's redeem can burn fewer scaled units than the
  ledger debits. The leftover stays in the adapter, owned by no plan. It is the
  protocol's, never a user's shortfall (`ForkHard`).
- **The vault never holds the stock token**, so B20's issuer pause switch and
  transfer blocklist can only revert an execution, never strand a position.
