# Hardening plan (2026-09-28)

> **How to read this.** It is the working record of the internal review
> rounds, kept as written, with later rounds annotating earlier ones. It
> covers the whole system, so some sections are about the keeper, the indexer
> and the web app, which are not in the public repository; they are left in so
> the record is complete. Commit hashes and branch names refer to the private
> development history. "Re-audit" in a test or file name means an internal
> re-test: nobody outside has audited this code. The newest round is at the
> end.

The hard test of commit `2087ae8` found no Critical issues. It ran three passes:

- **Static:** Slither, Aderyn, Mythril, Halmos.
- **Dynamic:** heavy forge invariants, a new stateful suite, Echidna, and Base and Base Sepolia forks.
- **Off-chain:** the indexer and keeper against anvil and Postgres, with reorgs, RPC faults, restarts and racing keepers.

This file lists every finding, the fix chosen, and how the fix is proven. A fix is done when its reproduction test from the hard test fails before the change and passes after it. Every one of those tests joins the suite.

The order of work is:

1. Contracts and off-chain fixes, in parallel.
2. Integrate on `hardening`.
3. Re-run the same three passes.
4. **Only after that**, redeploy to Base Sepolia and run the passes again against the new deployment. That step is not part of this branch. (A first Sepolia deployment, made on 2026-09-24 before this plan, is the "live Sepolia deploy" that D1 below says was affected. It is abandoned. `contracts/deployments/baseSepolia.json` is the redeploy of 2026-09-30, made after round 4.)

## Contracts

| # | Sev | Finding | Fix |
|---|---|---|---|
| C1 | High | `admin` can never be transferred and there is no timelock. `setRoute` can re-point a live route at a fake pool. The same applies to `ChainlinkOracle`. | Two-step `transferAdmin` / `acceptAdmin` on the vault and the oracle. Route changes and feed changes are **queued** and take effect after `ADMIN_DELAY` (48h). Disabling a route stays instant. A route id's token and pool can never change once set, so a new venue needs a new route id. Every setter emits an event. |
| C2 | High | `minOut` comes from the pool's own spot price, so a sandwich can cost up to the 5% divergence band. | Compute `minOut` from the **Chainlink reference**: `amountIn / refPx × (1 − maxSlippageBps)`. `maxSlippageBps` defaults to 100 bps and covers both the pool's premium and the impact. The pool price stays only as the circuit breaker. The total cost against the feed is then bounded by one number, which the threat model states. |
| C3 | Medium | After any lending loss or rounding drift, the final installment panics (0x11) forever. | The last slice redeems **all** of the plan's shares and spends whatever comes back. Earlier slices clamp `want` to what the plan's shares are worth. A shortfall is a loss the plan absorbs; it is never a revert. |
| C4 | Low | A one-installment plan panics at create when the share price is not 1.0. | Same fix as C3. |
| C5 | Low | A stale weekday feed does not stop executions, and admin's band is ignored while the feed is stale. | A stale feed **reverts** `StaleOracle`, and executions wait. The keeper already only runs in market hours. `setFeed` checks `decimals() == 8`, and the oracle rejects `updatedAt == 0` and future timestamps. |
| C6 | Low | A 1-wei installment lets one plan hold the whole TVL cap for free. | `installment >= MIN_INSTALLMENT` (1 USDC) and at most `MAX_PERIODS` (120) periods. Cap changes emit events. The docs describe the cap as outstanding principal. |
| C7 | Low | A fee recipient on USDC's blocklist would block every exit. There is no fee-recipient setter. | Fees accrue to a balance claimed with `claimFees()`, so fee delivery can never block an exit. Add `setFeeRecipient` (admin, with an event). A partial exit at 100% utilisation is **not** added; the threat model says so plainly. |
| C8 | Low | A huge interval truncates `nextExecution` into the past. | `interval <= MAX_INTERVAL` (366 days), plus a checked cast. |
| C9 | Low (demo) | Anyone can mint demo USDC and fill the Sepolia cap. | `DemoUSDC.mint` is limited to the owner and the demo adapter. Visitors get funds through the rate-limited drip. |
| C10 | Info | `Route.feed` is never read, `SafeTransfer` passes on an address with no code, and the Aerodrome adapter trusts the pool's reported deltas. | Check the route's feed against `oracle.feedOf` when the route is queued. Add an `extcodesize` check to `SafeTransfer`. The adapter measures the recipient's balance change and requires `owed == amountIn`. |
| C11 | Info | The invariant handler catches every revert, so it cannot see a Panic. The threat model disagrees with the code on keeper grace, and it claims a timelock and a 50 bps bound that did not exist. | The handler catches only the expected custom errors. The hard test's suite (`HardInvariants`, repros, Echidna harness) joins `contracts/test`. `docs/threat-model.md` is rewritten to match the code after this plan. |

## Indexer

| # | Sev | Finding | Fix |
|---|---|---|---|
| I1 | High | The first buy, which runs inside `createPlan`, is never counted. | Apply the plan update only when the execution insert actually inserted a row, and drop the block-number guard. |
| I2 | High | `CHUNK = 2000` means the indexer cannot sync against public Base Sepolia, which allows 1,000 blocks per `getLogs`. | Make the chunk size configurable (default 1,000) and halve it on a range-limit error. |
| I3 | Medium | A reorg deeper than 12 blocks corrupts data permanently. | Store the hash of the last indexed block. On each sync, compare it with the chain. On a mismatch, walk back to the common ancestor, delete rows above it, and re-index. |
| I4 | Medium | `getLogs` served by a lagging node loses events. | Before applying a range, confirm the node serving logs has the range's end block (look it up by hash). Otherwise retry the range. |
| I5 | Medium | Out-of-order logs undercount executions. | Sort logs by `(blockNumber, logIndex)`. I1 also makes the result independent of order. |
| I6 | Medium | `installment` and `next_execution` are never written, and an exit leaves `remaining_principal` set. | Read `plans(id)` at the event's block. Zero the principal on exit. |
| I7 | Medium | The documented backfill does not backfill. | Change `on conflict do nothing` to `do update` for plan creation fields. |
| I8 | Low | A chunk is not atomic, and every log costs one extra RPC. | One DB transaction per chunk, and block timestamps cached per block. |
| I9 | Low | Silent defaults: no RPC means mainnet, and no vault means no address filter. | Require both variables and check `eth_chainId` at start. |
| I10 | Info | The deploy block itself is never scanned. | Scan from `DEPLOY_BLOCK`. |

## Keeper

| # | Sev | Finding | Fix |
|---|---|---|---|
| K1 | High | A reverted transaction is logged "ok" and clears the backoff. | Check `rc.status`. A revert is a failure and counts toward the alert. |
| K2 | Medium | The RPC URL, including any API key, is written to the logs. | Log only the host. Log errors by `shortMessage`, never the whole viem error. |
| K3 | Medium | There is no gas-price ceiling. | Add `MAX_GAS_GWEI`. Above it the keeper defers and logs why. |
| K4 | Medium | A stuck transaction blocks the tick, and ticks overlap and clash on nonces. | An in-flight guard around `tick()`, a receipt timeout shorter than the cron interval, and a fee-bumped replacement on the same nonce. |
| K5 | Low | Custom errors are not decoded. | Use the full `dcaVaultAbi` from `@dca/config`. |
| K6 | Low | Two replicas with one key clash on nonces. | A nonce manager, and the docs say one replica only. |
| K7 | Low | Every tick reads every plan ever created. | Batch the reads with multicall. |

## Shared

| # | Sev | Finding | Fix |
|---|---|---|---|
| S1 | Low | The same-block activity feed is ordered wrongly. | Carry `log_index` and sort by `(block, logIndex)`. |

## Proof

- `forge test`, including the new suites, at the hard test's settings (2,000 runs × 200 depth), plus Echidna. The committed `foundry.toml` runs the invariant suites at 256 × 64 so an ordinary `forge test` stays quick; the heavy run is `FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=200 BASE_RPC_URL=off forge test`.
- Slither, Aderyn, Mythril and Halmos with the same detectors. New findings are triaged the same way.
- Worker and indexer tests, and the off-chain scenarios (reorgs, lagging RPC, restarts, racing keepers, gas spike, stuck transactions) against anvil and Postgres.
- The full e2e suite, because the web app reads the same ABI.

# Round 2 (2026-09-28)

The same three passes were re-run against `188d6d5`, by independent reviewers.

- **Round 1 results:** C1–C11 are fixed. Of the off-chain items, 16 of 18 are fixed; I4 and K5 are partly fixed.
- **New findings:** a smaller set, listed below.

The rules are the same as round 1:

- Each finding's reproduction test must fail before the change and pass after it.
- Every such test joins the suite.
- The three passes run again afterwards.
- The Base Sepolia deploy still waits until they come back clean.

The re-test's reproduction tests were `Repros2`, `Adv2`, `Adv3`, `AdvInvariants`, `ForkAdv`, `AuditPoC2`, `HalmosReaudit`, and a set of off-chain ones. They are not published as they were written; the ones that were kept are in `contracts/test`, rewritten to assert the fix (see the status note below).

## Contracts

| # | Sev | Finding | Fix |
|---|---|---|---|
| D1 | High (demo) | `DemoYieldAdapter` inherits the mock's ungated `supply`/`redeem`/`withdraw`. Anyone can drain every plan's pooled USDC, and every exit then panics. This also affects the live Sepolia deploy. (That was the first deployment, of 2026-09-24, now abandoned. The address in `contracts/deployments/baseSepolia.json` is the 2026-09-30 redeploy, which has this fix.) | Gate all three with `onlyVault`, bound to the vault address the deploy script predicts. The mocks used by the tests get the same gate, unless a test needs the open version (in which case name it for that). |
| D2 | Medium | Queued route and feed changes never expire. A pending route survives `disableRoute`. `queueFeed` accepts an unlisted token. A loosening `setBounds` is instant. | Activation is allowed only in `[eta, eta + 7 days]`. After that the entry has expired and must be queued again. `disableRoute` deletes the pending entry. `queueFeed` requires a listed token. `setBounds` tightening stays instant, and loosening goes through the same delay. |
| D3 | Info | The Aerodrome callback is not one-shot. | Clear `_expectedIn`/`_activePool` inside the callback before paying. |
| D4 | Info | `isFresh` reverts when the feed reverts, which blocks deposits. | Wrap the call in try/catch and return false. (Replaced in round 3 by F3: the feed is now read by one bounded assembly `staticcall`, `ChainlinkOracle._read`, and there is no try/catch.) |
| D5 | Low (demo) | The faucet is per address, so Sybil drips can fill the demo cap. | Give the faucet a global daily budget, and set the Sepolia cap far above it. Mainnet docs say plainly that the cap is first come, first served. |
| D6 | Info | `Route.feed` goes stale after a feed rotation. A non-8-decimal stock fails as `PoolDiverged`. | Readers use `oracle.feedOf`, and the field is documented as the feed at admission. `_checkRoute` requires `decimals() == 8`, with its own error. |
| D7 | Info | Docs. | The threat model covers expiry, the first-come cap, a last slice ending one period early from rounding (a few wei), and fail-closed on a premium above the slippage bound. |

**Contracts status (branch `fix2-contracts`).** D1–D7 are done. Each finding's
test is in `contracts/test/Round2.t.sol` (`test_D1_*` … `test_D7_*`); the
re-test's `Adv2`, `Adv3`, `AdvInvariants` and `ForkAdv` joined `contracts/test`,
and its passing Halmos checks joined `contracts/test/halmos/HalmosReaudit.t.sol`
(`HALMOS_CONTRACT=HalmosReaudit bash scripts/halmos.sh`). Where the code asked
for a closer reading of the fix:

- D1: the test mocks are gated by a `bindVault` their deployer calls, because
  several unit tests reuse one adapter across vaults. `DemoYieldAdapter` takes
  the vault in its constructor and can never be re-bound.
- D2: loosening `setBounds` is instant only while no plan has ever existed, the
  same setup window `initRoute` has. A loosening of either bound queues the
  pair; `cancelBounds` drops it. (Superseded in round 3 by F4: the setup
  window now closes at `finishSetup`, not at the first plan.)
- D3: besides disarming inside the callback, `swapExactIn` now reverts if the
  callback never ran.
- D6: the `decimals() == 8` check in `_checkRoute` is on the route's **stock
  token** (`BadTokenDecimals`), which is what made a wide stock fail as
  `PoolDiverged`. Feeds were already checked by the oracle.

## Off-chain

| # | Sev | Finding | Fix |
|---|---|---|---|
| E1 | Medium | A lagging or split load-balanced logs node can still lose events for good (I4 is partial). | Every sync re-scans an overlap window (default the last 64 blocks, configurable). This is safe because inserts are idempotent and aggregates are derived. |
| E2 | Medium | A lagging eth_call node writes a plan as empty, permanently. | Treat "header not found" and similar errors as lag: retry and do not advance. Reject any state read whose owner is zero or disagrees with the event. |
| E3 | Low | The pruned-state fallback reads the unconfirmed head. | Fall back to the confirmed tip (head − confirmations). |
| E4 | Low | The version re-index keeps the old indexer's orphan rows. | On a version bump, delete executions, exits and completion fields in the same transaction, then re-index. |
| E5 | Medium | A lending shortfall is invisible in the feed. | Store `PlanShortfall`. The shared activity model gains a shortfall event. The feed says the plan ended early and how much was lost, in text in the feed's existing style. The API selects it. |
| E6 | Medium | The keeper has no chain-id check. | `run()` compares `getChainId()` with the configured chain and refuses to start on a mismatch. |
| E7 | Low | A fee bump racing the mined original is logged as a failure. | When a replacement fails, check the receipts of the earlier hashes before calling it a failure. |
| E8 | Low | Errors in the send path are not decoded (K5 is partial). | Pass `abi: dcaVaultAbi` to both `writeContract` calls. |
| E9 | Info | Throughput is 5 per tick. | `MAX_PER_TICK` is configurable and documented. |

# Round 3 (2026-09-29)

The same three passes were re-run against `1c76e23`.

**What the re-test confirmed**

- C1–C11 are fixed.
- D1–D7 are fixed, with small residuals.
- 26 of the 27 off-chain items are fixed; E1 is partial.
- No finding lets anyone take user funds.

**Where the new findings come from.** Most are side effects of the round-2 fixes themselves. The rules are unchanged. The re-test's reproductions were `AuditPoC3`, `HalmosRound3`, `R3Ported`, `R3New`, `R3Invariants`, and a set of off-chain ones. They are not published as they were written; what was kept is named in the status notes below.

## Contracts

| # | Sev | Finding | Fix |
|---|---|---|---|
| F1 | Medium | The mainnet deploy cannot run. `_checkRoute`'s `decimals()` staticcall hits the B20 `0xef` precompile stub, which a forked EVM cannot execute. The check reads 0, reverts `BadTokenDecimals(0)`, and `forge script` fails before broadcasting. No test routes a real B20. | A token with no code is still refused. A token whose `decimals()` answers must answer 8. A token with code whose `decimals()` cannot be read in this EVM is accepted: the route's feed-vs-pool divergence check still catches a wrong-decimals token as `PoolDiverged`. Add a fork test that runs the real `Deploy.s.sol` against Base mainnet without broadcasting. (Narrowed in round 4 by H1: an unreadable `decimals()` is now accepted only for the B20 stub.) |
| F2 | Low | A tightening `setBounds` leaves a pending loosening in place, so an incident response can be undone at eta. | A tightening deletes `pendingBounds` and emits `BoundsCancelled`. |
| F3 | Low/Info | A hostile or malformed feed can still block deposits or panic: out-of-range round ids read as fresh and then `latestPrice` reverts; an `int256.max` answer overflows `diff*10000`; a returndata bomb runs `isFresh` out of gas. | Read the feed in assembly with a bounded copy (at most 160 bytes). Apply the same decode and range checks as `latestPrice`: `uint80` round ids and a sane price ceiling. `latestPrice` rejects answers above the ceiling, so no downstream arithmetic can overflow. |
| F4 | Low | Deposits are open from deployment, so a first `createPlan` can land between `initRoute` calls and close setup early. | Setup ends explicitly. Deposits are paused from the constructor. A new `finishSetup()` (admin) closes the setup window and unpauses deposits. `initRoute` and instant loosening are only possible before `finishSetup()`. All deploy scripts call it last. (Changed in round 4 by H3: a pause set during setup is kept through `finishSetup`. The mainnet `Deploy.s.sol` sets one, so its `finishSetup` closes the window and leaves deposits paused.) |
| F5 | Info | With `DEMO_OWNER` set, the Sepolia deploy leaves vault `admin` and `feeRecipient` with the deployer. | That branch also calls `transferAdmin(owner)` and `setFeeRecipient(owner)`. |
| F6 | Info | The permanent invariant handlers barely exercise `executeDCA`: 17 successful executes in 202×200. | The handlers pick an active plan and warp to its due time. `afterInvariant` asserts a minimum number of successful executes. The round-3 model-based `R3Invariants` joins the suite. |
| F7 | Info | Docs. | The threat model says that `createPlan`'s first buy also fails closed. It also documents the faucet's midnight burst and that one large transaction a day can keep the demo faucet dry. |

**Contracts status (branch `fix3-contracts`).** F1–F7 are done. Each finding
was first shown on `32b197e` by the re-test's own reproductions (they passed
there by demonstrating it; F5 by deploying the old script to an anvil fork of
Base Sepolia with `DEMO_OWNER` set). The permanent tests are
`contracts/test/Round3.t.sol` (`test_F1_*` … `test_F7_*`),
`DeployScripts.t.sol` (F4, F5), `ForkDeploy.t.sol` (F1: the real
`Deploy.s.sol` on a Base mainnet fork, no broadcast), `R3Invariants.t.sol`
(F6) and three new checks in `contracts/test/halmos/HalmosRound3.t.sol`
(`HALMOS_CONTRACT=HalmosRound3 bash scripts/halmos.sh`), which fail on
`32b197e` and pass now. Where the code asked for a closer reading of the fix:

- F1: besides the three-way rule, the `decimals()` probe gets 50,000 gas and
  copies one word. On a fork the B20 stub burned every unit of gas it was
  forwarded (393M in the old simulation). The deploy scripts now read the
  broadcaster with `vm.readCallers()` instead of `msg.sender`, so a test can
  run them in-process; under `forge script` the two are the same account.
- F3: `MAX_PRICE` is 1e16 ($100,000,000 a share at 8 decimals). `latestPrice`
  now reverts `BadPrice` for a feed that reverts or answers short; it used to
  bubble the feed's own revert. The vault asks `isFresh` first, so it never
  saw either.
- F4: `setDepositsPaused(false)` before `finishSetup` reverts with a new
  `SetupOpen` error. Without it the admin could open deposits with the setup
  window still open, which is the state F4 exists to rule out. A second
  `finishSetup` reverts `SetupClosed`. `Deploy.s.sol` calls it after the
  two-step `transferAdmin`, as its last call; the deployer is admin until the
  multisig accepts either way.
- F6: picking an active plan and warping to its due time was not enough for
  the hostile suites, whose switches (premium, stale feed, liquidity cap,
  disabled route, ratcheted bounds) persist until something resets them. Each
  gets a calm execute that resets the world through the real paths (the 48h
  queues included) and then executes; `afterInvariant` asserts every calm
  execute lands. With executes running, HardInvariants' flat 3-wei tolerance
  on "exit under principal without a loss" was beaten by 4 wei after 3–4
  exact withdraws: the documented D7 rounding. That tolerance is now per
  ledger operation of the plan. `DCA_INVARIANT_STATS=1` writes per-run counts.
- F7: the midnight burst and the one-transaction drain are documented and
  pinned by `test_F7_*`, not fixed.

## Off-chain

| # | Sev | Finding | Fix |
|---|---|---|---|
| G1 | Medium | A reorg during the overlap re-scan leaves orphaned rows for good. The chunk starts below `last`, so the parent-hash check finds no stored checkpoint and is skipped. | After fetching any chunk that spans stored checkpoints, re-read those checkpoint blocks, and roll back on any mismatch before committing. |
| G2 | Medium | The `INDEX_VERSION` rebuild empties the feed and then refills it chunk by chunk, which would take minutes to an hour on mainnet. | Rebuild into shadow tables and swap them in within one transaction. If that proves infeasible, the API returns an explicit "reindexing" state and the feed says so. |
| G3 | Low | The overlap bound is silent, and idle syncs got expensive: 134 calls against 4. | Warn when a re-scan recovers events. Run a periodic deeper sweep (configurable). Skip `plans()` and block re-reads for re-scanned logs already in the DB. |
| G4 | Low | `MAX_PER_TICK` is not bounded by the cron interval. The gas cap and market hours are only checked at tick start. | Each tick gets a time budget that ends before the next cron fire. Gas price and market hours are re-checked before every send. Config rejects values that cannot fit the budget, including a too-small receipt timeout. |
| G5 | Info | Rounding-sized shortfalls produce alarming feed items. | Below a dust threshold (under one cent), no shortfall item is shown and the plan is not marked "ended early". The stored row stays for audit. |
| G6 | Info | An unmigrated DB is fatal to the indexer and the web route. | The indexer applies `schema.sql` (idempotent) at start. The README states the upgrade order. |
| G7 | Info | A stale test name. | Rename. |

**Off-chain status (branch `fix3-offchain`).** G1–G7 are done. Each finding's
test fails on `32b197e` and passes after: `apps/indexer/src/indexer.db.test.ts`
(`G1:` … `G6:`), `readpath.db.test.ts` (G5, through the real route),
`apps/worker/src/keeper.test.ts` (`G4:`) and `packages/shared/src/activity.test.ts`
(G5). Where the code asked for a closer reading of the fix:

- G1: after the fetch, the **newest** stored checkpoint in `[from − 1, to]` is
  re-read, not every one. A block hash commits to all its ancestors, so if the
  newest is canonical so is every older one, as long as the stored checkpoints
  form one chain — which this check now keeps true. Reading all of them would
  have cost the deep sweep (G3) dozens of calls. A rollback goes to the newest
  canonical checkpoint *below* the stale one. `INDEX_VERSION` is 4, so a
  database a version-3 indexer may have left orphaned rows in is re-derived.
- G2: shadow tables worked, so there is no "reindexing" state and no new copy.
  The copy is built in the `dca_reindex` schema from `schema.sql`; the live
  tables keep serving and keep being indexed meanwhile; an interrupted rebuild
  resumes; the swap takes its locks `NOWAIT` and retries, so it can never
  deadlock a reader.
- G3: the deep sweep is `INDEXER_SWEEP_BLOCKS` (1,000) deep, every
  `INDEXER_SWEEP_EVERY_BLOCKS` (150) indexed blocks, and on the sync after any
  re-scan that recovered events (`sync_state.swept_block`). Events the
  database already holds cost no reads: an idle sync is 5 calls (7 in a fresh
  process), from ~130.
- G4: the budget ends 30 s before the next cron fire. A send starts only if a
  full receipt wait fits before it. `MAX_PER_TICK × 2 s` plus one stuck send
  (`KEEPER_RECEIPT_TIMEOUT_MS × (1 + KEEPER_MAX_BUMPS)`) must fit in 570 s,
  which is 150 with the defaults, and the receipt timeout must be at least
  10 s.
- G5: the threshold is `SHORTFALL_DUST` in `@dca/shared` (10,000 units, one
  cent), applied by the indexer's feed and the browser's RPC feed alike. The
  sub-cent copy (`activity.shortfallRounding`) could no longer be shown and is
  gone.
- G7: the renamed test is I6's pruned-state fallback, which reads the confirmed
  tip since E3.

# Round 4 (2026-09-30)

The same three passes were re-run against `d495c33`.

**Result:** no Critical, High or Medium finding, and nothing that lets anyone take user funds. C1–C11, D1–D7 and F1–F7 all hold. The real mainnet `Deploy.s.sol` now simulates on a Base fork.

**Contracts:** the author chose to fix the three contract items before the Sepolia redeploy.

| # | Sev | Finding | Fix |
|---|---|---|---|
| H1 | Low | `_checkRoute` admitted any token with code whose `decimals()` could not be read. With a pool pushed to 8dp parity, an unreadable 18dp token filled at 1e-10 of fair value, inside the slippage bound. The pool-price backstop only holds while the pool is honestly priced. | An unreadable `decimals()` is accepted only when the token's code hash is `keccak256(hex"ef")`, the B20 stub. Every other unreadable token reverts `BadTokenDecimals(0)`. |
| H2 | Info | The feed read forwarded all gas, so a fresh but gas-hungry feed made every deposit run out of gas. | `ChainlinkOracle._read` gives the feed `FEED_GAS` = 100,000. A feed that needs more reads as not fresh. |
| H3 | Info | `finishSetup` lifted a pause that the admin had set on purpose during setup. | A pause set during setup is kept through `finishSetup` (it emits `DepositsPausedSet(true)`) and is lifted later with `setDepositsPaused(false)`. |

Proof:
- H1: `Round3.test_F1_TheDecimalsRuleByCase` and `test_F1_AnUnreadableWrongDecimalsTokenIsRefused`. These replace the round-3 test that asserted the old backstop.
- H2: `test_R4_AGasHungryFeedReadsNotFreshAndCheaply`. It fails with the old `gas()` forwarding.
- H3: `test_F4_FinishSetupClosesTheWindowOnceAndOpensDeposits` (updated), `test_R4_FinishSetupOpensDepositsWhenNotPausedInSetup`, and the `R3Invariants` model.

**Off-chain:** the round-4 items are Low or Info. They did not block the contract deploy. The reproductions (`g2-poll`, `g1hole`, `g6-lockqueue`, `g6-rpcdown`, `sweep-window`, `keeper4`, `g2-two`) are not published.

| # | Sev | Finding | Fix |
|---|---|---|---|
| J1 | Low | A version-bump rebuild freezes live indexing. The live tables are indexed once, before the rebuild starts, and the rebuild then runs from the deploy block to the tip in one go. For as long as it takes, the feed stands still, and the index swapped in ends where the rebuild started (an event made during a 17 s rebuild showed 45 s later). | The rebuild runs in slices (15 s). The live tables are indexed before every slice, and each slice takes its own tip, so the index swapped in reaches at least as far as the one it replaces. |
| J2 | Low | With a chunk smaller than the overlap re-scan (64 blocks), a reorg that lands after the sync's first look leaves orphaned rows for good. The chunk that spans the fork point ends below the cursor, the newest checkpoint inside it is older than the fork, so G1's check passes. | Every chunk re-reads the **newest** stored checkpoint after its fetch, not the newest one inside its range. Same cost: one block read per chunk. |
| J3 | Low | `schema.sql` at start takes `ACCESS EXCLUSIVE` on the live tables (`alter table … add column if not exists` does, even with nothing to add), with no timeout. Behind one long reader it queues, and every reader of the feed queues behind it (measured: the feed stalled for the reader's whole 20 s). With the RPC down at start, it is re-applied every 30 s. | Applied once per process, and not at all when the database already holds this exact file (its hash is stamped in a `schema_applied` row). When there is something to apply, the existing tables are locked `NOWAIT` first and the attempt retried, so the DDL never waits in the lock queue. |
| J4 | Low | The deep sweep's window is anchored at the cursor. Events a lagging logs node hid just beyond the overlap are lost for good if the indexer then advances more than the sweep depth before the next sweep (downtime, a long catch-up). | The window also reaches back to where the previous sweep left blocks short of their depth (`swept_block + 1 − (SWEEP − SWEEP_EVERY)`). Every block is swept at least once from that far above it, however the cursor moved. |
| J5 | Info | The browser's RPC feed orders same-block events differently from the indexer's feed. | Done. Both feeds sort with one comparator, `newestFirst` in `packages/shared/src/activity.ts`; the browser feed now carries each log's index. Test: `activity.test.ts`, "one order for every feed". |
| J6 | Info | The keeper's per-send overhead is not in the tick's time budget: four round trips (gas price, simulation, block, priority fee) before each send, waited for one after another. On an RPC answering 1.5 s late a tick ended 1.7 s past its deadline. | The gas price, the simulation and the fee estimate are asked together (one batch; two round trips where there were four). The budget is checked again immediately before the send: if a receipt wait no longer fits, nothing is sent. |
| J7 | Low | Two indexers started at once on an older index clash on the shadow schema: one fails on `pg_namespace`, both build into one shadow, and after one swaps, the other fails every sync with `relation "dca_reindex.sync_state" does not exist`. | One builder, under a transaction-level advisory lock held while it works on the shadow. The other stands by and looks again on its next sync. Whether to resume or recreate the shadow is decided under the lock. Every write checks the index version in its own transaction, so an indexer older than the index it finds refuses to write into it. |

**Off-chain status (branch `r5-offchain`).** J1–J4, J6 and J7 are done there,
and J5 in the web app beside them. Each finding's test fails on `e274b7b` and passes after:
`apps/indexer/src/indexer.db.test.ts` (`J1:` … `J4:`, `J7:`) and
`apps/worker/src/keeper.test.ts` (`J6:`). Where the code asked for a closer
reading of the fix:

- J1: a slice ends only past the re-scan window and with the cursor moved, so
  every slice makes progress. A sync that rebuilds does only that; the next
  sync carries on from the swapped-in index.
- J2: `INDEX_VERSION` is 6, so a database an older indexer may have left
  orphaned rows in (J2) or missing events in (J4) is re-derived.
- J3: the check for "already applied" reads `pg_class`, not `to_regclass()`.
  A session that looked a table up before another session created it can keep
  answering "no such table" from its cache; a catalog read makes it look again.
- J4: a rollback pulls `swept_block` down to the ancestor, because the blocks
  above it are indexed afresh and no sweep has covered them.
- J6: the send itself is still viem's three round trips (nonce, gas estimate,
  broadcast). Measured through the real transport, a send went from eight
  round trips to six. Replacing the rest would mean hand-rolling the nonce and
  the gas limit on the path that moves money, for a keeper that sends a handful
  of transactions a day. Not done.
- J7: the lock is transaction-level and held in an open transaction, so it
  works through a transaction-mode pooler and is released if the builder dies.
  The builder pings that session between slices; if it is gone, the rebuild
  stops and resumes on the next sync.

Two changes came with the deployment work, not from a finding:

- **A sync that finds nothing to write sends the database nothing**
  (`INDEXER_IDLE_FLUSH_BLOCKS`, 1,800 by default in the entry point; 0, the
  old behaviour, by default in `createIndexer`). An idle poll used to cost 8
  statements, 3 of them writes (the checkpoint, its pruning, the cursor). The
  cursor and the newest checkpoint are now kept in memory between syncs and
  written with the next event, on a reorg, and once the stored cursor is that
  many blocks behind. The database's own invariants are unchanged: rows at or
  below its cursor, a checkpoint at the cursor, checkpoints that form one
  chain. The tests are the `a poll that finds nothing writes nothing` block.
- **`KEEPER_IGNORE_MARKET_HOURS` is refused on Base mainnet.** It used to be
  ignored there without a word. `keeperConfigFromEnv` and `createKeeper` both
  throw (`market hours on Base mainnet cannot be switched off`).

# Round 5 (2026-10-04): four independent reviews before the source was published

Before the contracts were made public, four reviewers read them separately,
each through one lens, without seeing each other's work: money flow and
accounting; privileged roles, the setup window and the deploy scripts; the
oracle, the swap and the lending adapters; and whether everything about to be
published was true and safe to publish. Where a reviewer suspected a bug they
had to confirm it with a test, not argue it.

**Result: nothing Critical or High.** No sequence of calls was found that
makes the vault pay more than it holds, pays one plan from another's claim,
takes a fee from principal, or gets around a privileged check. Every claim in
the threat model's actor table held in the code. What was wrong was mostly
what the documents said.

| ID | Severity | Finding | Status |
|---|---|---|---|
| R5-1 | Medium (disclosure) | One multisig holds the vault's admin and the oracle's admin, so the threat model's "at most 2% per fill" for a compromised admin understated that key. After a 48-hour public feed rotation it can take one due installment per plan per interval. Confirmed on mocks. | **Documented**, `docs/threat-model.md` *Worst case per key*. Pinning the route's feed in `_minOut` is the code fix; it reverses the accepted D6 choice and is not done. |
| R5-2 | Low at the $5,000 cap, Medium above about $8,000 of overdue buys on one route | A frozen feed reads fresh for 24 hours after its last print, and the pool breaker reads spot, so a caller can satisfy it in the same transaction. Found independently by three of the four reviewers. The threat model said "nothing is bought against a frozen price", which was false. | **Documented**, *Stale feeds*. **Open: must be fixed before the cap is raised**, by reading the pool through a short TWAP. |
| R5-3 | Low | `Deploy.s.sol` started the admin handover before its last two calls. An early accept by the multisig would have left the setup window open with no pause recorded, and the multisig's own `finishSetup` would then have opened deposits. | **Fixed**: the pause is recorded before the handover starts. `ForkDeploy.t.sol` passes against Base. |
| R5-4 | Low | Whatever the deployer key sets before the multisig accepts stays set, and the deploy procedure did not re-read it. | **Documented**, `docs/threat-model.md` *Worst case per key*. The deploy procedure (a step-by-step runbook that is not published yet) now re-reads every setting and checks the deployer's transaction count after the accept. |
| R5-5 | Low | A deposit that does not divide by the installment leaves a final period as small as 2 wei: a plan the cap barely counts, and a buy of nothing. Confirmed: 300 such plans under a $5,000 cap. The web app rounds the installment up and cannot make one. | **Open.** One line in `createPlan`. |
| R5-6 | Low | No sequencer-uptime check: after an outage the last print reads fresh until the next one. Same exposure as R5-2 for that interval. | **Open**, with R5-2. |
| R5-7 | Low | Nothing can be swept. Incentive tokens paid to the lending adapter's address, or tokens sent by mistake, stay there. Lost yield, never principal. | **Accepted and documented**, *Residual risks*. |
| R5-8 | Info | `_supply` accepts zero shares. Not reachable on MetaMorpho (its virtual-share offset would need a donation of about 2e15 USDC). | Open. One line. |
| R5-9 | Info | `setFeeRecipient` accepts the vault's own address, which strands protocol fees. | Open. One line. |
| R5-10 | Info | Several instant admin powers were missing from the worst-case list: raising the cap, cancelling honest queued changes, keeping the role. | **Documented.** |
| R5-11 | Info | `Deploy.local.s.sol` had no chain guard. | **Fixed**: it refuses any chain but 31337. |

Also from this round: the whole path, deposit to lend to buy to exit, was run
against **live Base state** as a read-only simulation with the real NVDAc
precompile and the real pool, and passed (0.42485317 NVDAc for a 100 USDC
buy; a feed 1.2% under the pool reverted `Slippage`, 10% over reverted
`PoolDiverged`). That is the closest a buy has come to a real chain. It is
not a mined transaction.

The contract logic is unchanged by this round. R5-2, R5-5, R5-6, R5-8 and
R5-9 are changes to it and will go in together, with their own tests, before
any mainnet deploy that raises the cap.
