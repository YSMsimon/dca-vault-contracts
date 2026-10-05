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
| R5-1 | Medium (disclosure) | One multisig holds the vault's admin and the oracle's admin, so the threat model's "at most 2% per fill" for a compromised admin understated that key. After a 48-hour public feed rotation it can take one due installment per plan per interval. Confirmed on mocks. | **Documented**, `docs/threat-model.md` *Worst case per key*, and **bounded in round 6** by the swap adapter's push check: the one-transaction version reverts. Pinning the route's feed in `_minOut` is deliberately not done (see Round 6). Round 6b tightened the push check and changed nothing else here: it stays a disclosed risk (see Round 6b). |
| R5-2 | Low at the $5,000 cap, Medium above about $8,000 of overdue buys on one route | A frozen feed reads fresh for 24 hours after its last print, and the pool breaker reads spot, so a caller can satisfy it in the same transaction. Found independently by three of the four reviewers. The threat model said "nothing is bought against a frozen price", which was false. | **Documented**, *Stale feeds*. **Bounded in round 6**: the one-transaction version reverts; a push left standing across a block boundary can still pass. This row said "Fixed in round 6" until the re-review (R6-1). **Tightened in round 6b**: the spot is held to five one-minute averages, so one such block is no longer enough, and the oracle reads not fresh on a weekend. Still bounded, not fixed. |
| R5-3 | Low | `Deploy.s.sol` started the admin handover before its last two calls. An early accept by the multisig would have left the setup window open with no pause recorded, and the multisig's own `finishSetup` would then have opened deposits. | **Fixed**: the pause is recorded before the handover starts. `ForkDeploy.t.sol` passes against Base. |
| R5-4 | Low | Whatever the deployer key sets before the multisig accepts stays set, and the deploy procedure did not re-read it. | **Documented**, `docs/threat-model.md` *Worst case per key*. The deploy procedure (a step-by-step runbook that is not published yet) now re-reads every setting and checks the deployer's transaction count after the accept. |
| R5-5 | Low | A deposit that does not divide by the installment leaves a final period as small as 2 wei: a plan the cap barely counts, and a buy of nothing. Confirmed: 300 such plans under a $5,000 cap. The web app rounds the installment up and cannot make one. | **Fixed in round 6.** |
| R5-6 | Low | No sequencer-uptime check: after an outage the last print reads fresh until the next one. Same exposure as R5-2 for that interval. | **Fixed in round 6**: `isFresh` is false while the sequencer is down and for an hour after. |
| R5-7 | Low | Nothing can be swept. Incentive tokens paid to the lending adapter's address, or tokens sent by mistake, stay there. Lost yield, never principal. | **Accepted and documented**, *Residual risks*. |
| R5-8 | Info | `_supply` accepts zero shares. Not reachable on MetaMorpho (its virtual-share offset would need a donation of about 2e15 USDC). | **Fixed in round 6** for a supply that mints exactly zero shares. (Round 6b: the 2e15 figure was never checked on chain, and the check catches exactly zero only. See R6-6.) |
| R5-9 | Info | `setFeeRecipient` accepts the vault's own address, which strands protocol fees. | **Fixed in round 6.** |
| R5-10 | Info | Several instant admin powers were missing from the worst-case list: raising the cap, cancelling honest queued changes, keeping the role. | **Documented.** |
| R5-11 | Info | `Deploy.local.s.sol` had no chain guard. | **Fixed**: it refuses any chain but 31337. |

Also from this round: the whole path, deposit to lend to buy to exit, was run
against **live Base state** as a read-only simulation with the real NVDAc
precompile and the real pool, and passed (0.42485317 NVDAc for a 100 USDC
buy; a feed 1.2% under the pool reverted `Slippage`, 10% over reverted
`PoolDiverged`). That is the closest a buy has come to a real chain. It is
not a mined transaction.

The contract logic is unchanged by this round. R5-2, R5-5, R5-6, R5-8 and
R5-9 are changes to it. They went in together as round 6, below, before any
mainnet deploy.

# Round 6 (2026-10-04): the round-5 contract findings, four fixed and two bounded

The contracts are immutable once deployed, and they are not deployed on
mainnet yet, so the code was changed for the five round-5 findings that
needed it before the deploy rather than before the cap is raised. Each
change is as small as it could be made, and each has a test that fails
without it.

**Corrected in round 6b.** This section was headed "the round-5 findings
fixed" and listed R5-2 as "Fixed". Round 6 fixed four of the round-5 contract
findings (R5-5, R5-6, R5-8, R5-9) and bounded two (R5-1 and R5-2). The
sentences below that overstated the push check are corrected where they
stand, with a note of what they used to say. Round 6b, at the end, is what
the re-review found and what was done about it.

| ID | What changed | Status | The test that proves it |
|---|---|---|---|
| R5-2 | `AerodromeSwapAdapter.swapExactIn` reads the pool's spot tick and its mean tick over the last `TWAP_WINDOW` = 300 seconds (`observe`), before the swap. More than `MAX_TWAP_DRIFT` = 100 ticks apart (about 1%), it reverts `PoolPushed(spotTick, twapTick)`; a pool with no observation that old reverts `NoPriceHistory`. A view, `ticks(pool)`, is the same read. The vault and `ISwapAdapter` are unchanged. (Round 6b replaced the one mean with five one-minute means, and `ticks(pool)` now returns three values: see Round 6b.) | **Bounded**: the one-transaction version reverts; a push left standing across a block boundary could still pass (R6-1). This cell said "Fixed". | `Round6.t.sol` (the R5-2 tests: the finding itself, a push in the same transaction, the band's exact edges, the rounding of the mean, a pool with no price history), and on the real pool's code and state `Fork.test_Fork_APushOnTheRealPoolIsCaught` |
| R5-1 | Nothing more than R5-2's change. The transaction that took an installment (set the feed, push the pool to match, execute, unwind) now reverts `PoolPushed`, because the pool's average is not the attacker's to set. (Round 6b: not theirs to set inside that transaction. Across blocks it can be moved, at a cost: R6-1.) | **Bounded**, not removed | `Round6.t.sol` (the R5-1 test) |
| R5-5 | `createPlan` reverts `BadParams` when `deposit % installment` is not zero and is under `MIN_INSTALLMENT`. | **Fixed** | `Round6.test_R5_5_ADustFinalPeriodIsRefused`, `testFuzz_R5_5_TheLastPeriodIsNeverDust` |
| R5-6 | `ChainlinkOracle` takes Chainlink's L2 sequencer uptime feed in its constructor (immutable; zero switches the check off, for local and test chains). `isFresh` is also false while that feed says the sequencer is down and for `SEQUENCER_GRACE` = 1 hour after it restarts. `Deploy.s.sol` passes Base's feed, `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`. | **Fixed**, failing open | `Round6.test_R5_6_NothingIsFreshWhileTheSequencerIsDownOrJustBack`, `test_R5_6_NoBuyInTheGraceAfterARestart`, `test_R5_6_AnUnreadableUptimeFeedIsIgnored`, `test_R5_6_GarbageFromTheUptimeFeedReadsAsDown`, `testFuzz_R5_6_IsFreshNeverRevertsAndFollowsTheRule`, and against the real feed `Fork.test_Fork_SequencerUptimeFeedIsReadAndGatesFreshness` |
| R5-8 | `_supply` reverts `ZeroShares` when the adapter mints none. Every supply goes through it. | **Fixed** | `Round6.test_R5_8_ASupplyThatMintsNoSharesReverts` |
| R5-9 | `setFeeRecipient` also refuses the vault, the yield adapter and the swap adapter (`BadParams`). | **Fixed** | `Round6.test_R5_9_TheFeeRecipientCannotBeTheVaultOrItsAdapters` |

"Fails without it" was checked by taking each change out again, one at a
time, and running the tests: removing the push check failed ten of the tests
`Round6.t.sol` had in this round, removing the rounding step failed the
rounding tests, and so on for the tail check, the zero-share check, the
recipient check, the sequencer check, its fail-open branch, its
future-timestamp guard and the grace.

**Why the push check works, and what it rests on.** A v3-style pool writes at
most one observation per block, before the first swap of that block that
moves its tick, from the tick it had before. So `observe([300, 0])` cannot
contain a swap made in the same transaction or the same block, and the push
appears whole as the difference between spot and average. That is a property
of the pool, not of this code, so it was checked on the pool itself: on a
fork, with a stand-in token etched at the B20's address so that the real
NVDAc pool could run a swap, a 750,000 USDC push moved the spot 719 ticks and
the average not at all; two seconds later the average had moved by its 2/300
share; left pushed for the whole window (a fork has no arbitrageurs) it
passed again. The mean is rounded toward negative infinity, as Uniswap's
`OracleLibrary.consult` does: the launch pools sit at negative ticks (USDC is
token0), where plain division is one tick too high.

(Round 6b: that paragraph is true of a push made in the same transaction or
block, and of nothing more. The fork test held the pool AT the pushed price,
and it took the whole window to pass. A pool left far PAST the pushed price
for one block moves the average just as far. That is R6-1.)

**R5-1 is bounded, and feed pinning is deliberately not done.** After round 5
the code fix on the table for R5-1 was to pin the route's feed in `_minOut`,
so that an oracle feed rotation would also have to pass the vault's route
queue. It was not taken, for two reasons. It adds a second public queue, but
it does not stop a key that holds both roles, and one multisig holding both
is the launch configuration: that key simply passes both queues. And it makes
every legitimate rotation stall buys on the route until the route is
re-queued and activated as well. The push check bounds the same attack
without either cost: whatever the feed says, the pool will not be bought from
more than about 1% away from its own five-minute average. What that key can
still take is in `docs/threat-model.md`, *Both roles at once*: about 1% of a
due installment in one transaction, and more by leaving a pool off-market
across at least one block boundary. (This said "more only by holding a pool
off-market across blocks". Round 6b: one block was enough under this round's
single average; under round 6b's five averages it takes a block in each of
five minutes.)

**R5-6 fails open, on purpose.** An uptime feed the oracle cannot read (it
reverts, has no code, answers short, or needs more than 100,000 gas) is
ignored. The address is immutable, and a check that failed closed would let a
feed Chainlink retires halt every buy for good. The price paid is that a dead
uptime feed is no protection and says nothing; `scripts/verify-base-addresses.mjs`
now reads it the way the oracle does. A feed that answers anything but "up"
reads as down, and a restart time in the future reads as "just restarted".

**What is still exposed** is listed in `docs/threat-model.md`, *Residual
risks*: a push of up to about 1%, a push left standing across at least one
block boundary, an honest fast market making buys wait, and the hours after a
sequencer outage beyond the first. The second is the one to weigh before the
cap is raised. Round 5's attack was one transaction, needed no capital of the
attacker's own and carried no risk. What is left of it needs the attacker's
own capital left at a wrong price across at least one block boundary. That is
a change in cost, not a proof: over a weekend, with the stock market shut,
nobody may be trading the pool back. (Corrected in round 6b. This paragraph
said "a push held across blocks for most of five minutes", "held at a wrong
price for minutes" and "a large change in cost". The re-review showed that
one block was enough, and that it paid above about 13,000 USDC of executable
installments at a 6% gap between feed and pool: R6-1. Since round 6b nothing
is bought on a weekend at all.)

**What else moved with these changes.**

- A plan can no longer end one period early from rounding alone (round 2,
  D7, had documented that it could). It needed a last period of a few wei,
  which is now refused. `Round2.test_D7_ALastSliceCanEndOnePeriodEarlyByWei`
  became `test_D7_RoundingCanNoLongerEndAPlanOnePeriodEarly`.
- Tests that happened to build plans with a dust last period build admissible
  ones now: `Invariants`' handler, two `Adv2` fuzz tests, `ForkAdv` and one
  `ForkHard` test. `Adv2.testFuzz_CreateParamsEdges` models the new rule but
  did not exercise it: the re-review found that it passed with the rule
  removed (R6-4, Round 6b).
- **Three harnesses did not fail when the rule went in, and should have been
  expected to.** `HardInvariants`' handler and the Echidna harness split a
  deposit by rounding the installment DOWN, which always leaves a last period
  of a few wei, and both count `BadParams` as an expected refusal. So both
  went on passing while creating almost no multi-period plan: `HardInvariants`
  made 55 plans across 514 runs where it had made about 700, and every
  invariant held on a nearly empty vault. `HalmosLedger.check_ledgerConservation`
  halved its deposit the same way and then assumed the create succeeded, which
  dropped every odd deposit. All three now round the installment up, as the
  web app does, and the counts are back (`DCA_INVARIANT_STATS=1` prints them).
  A green suite was not evidence here; the counters were.
- Every test mock of a pool that the real swap adapter is driven against
  answers `observe`.
- Gas. On forks of the real pools the push check adds between 21,000 and
  41,000 gas to a buy (the swap adapter's `swapExactIn`, with and without the
  check: the NVDAc pool at three weekday blocks and the METAc pool at one).
  The sequencer check adds one bounded read to `isFresh`; with the real
  uptime feed, `isFresh` costs about 28,000 gas.
- The read-only simulation of the whole path against live Base state (round
  5) was run again with this round's bytecode, by `scripts/rehearse-mainnet.sh`:
  on all four routes the deposit, the lending supply and the first buy
  executed with the real pools, the real B20 tokens and the real uptime feed,
  and each fill was inside the vault's bound. It is still a simulation, not a
  mined transaction.
- The Base Sepolia test deployment was built before this round. Its logic is
  now older than this repository's.

# Round 6b (2026-10-05): the re-review of round 6

Round 6 was reviewed again before anything was deployed, by two reviewers
working separately. One read the swap adapter and the oracle against the
real NVDAc pool's verified source and a Base fork. The other read the three
vault changes, the tests, the app's handling of the new errors, and these
documents. **Nothing Critical or High.** Both found the same Medium
independently: round 6's push check could be passed with one block, and the
documents said it could not. Round 6 bounded R5-2. It did not fix it.

This round tightens that check, stops buys on weekends, and corrects what the
documents said. It does not close R5-2 either.

| ID | Severity | Finding | Status |
|---|---|---|---|
| R6-1 | Medium | Round 6's push check compared the pool's spot tick with ONE 300-second mean tick. A mean of ticks is moved by tick-seconds, not by time: one 2-second block at about 87,600 ticks off, or six blocks at 14,600, moves the 300-second mean far enough for a 6% push to pass. The threat model said that took "most of five minutes", and this file said R5-2 was "Fixed". Found independently by both reviewers. Confirmed on the repository's mock pool, and on a Base fork with a pool made by the same factory as the NVDAc pool and liquidity shaped like it: with a 100,000 USDC installment 13 hours overdue and a feed print 20 hours old and 6% above the pool, the attacker ended with 5,005,012 USDC from 5,000,000 (six-block variant; the spike took 750,177 USDC of the attacker's own capital and about 750 USDC in pool fees). Break-even was about 13,000 USDC of executable installments at a 6% gap; under the 5,000 USDC launch cap, at that gap, the attack loses money. Medium and not Low because the contracts are immutable and the admin can raise the cap. | **Bounded further, not closed.** Five one-minute means in the swap adapter (change 1) and no buys on weekends in the oracle (change 2). The documents are corrected. |
| R6-2 | Low | A route's buys and deposits can be stalled on purpose. One excursion large enough to trip the push check makes every buy and every deposit on the route revert `PoolPushed` until it has left the window. Whoever does it gains nothing, and exits are untouched. Under round 6's rule the reviewer reasoned the cost on the NVDAc pool at about 720 USDC of pool fees per excursion, about 8,600 USDC an hour per route, plus exposure to arbitrage (from the measured liquidity; not run). | **Documented**, `docs/threat-model.md` (*The fill bound*, *Residual risks*). The reviewer asked for no fix. The optional one, letting `createPlan` skip its first buy when the venue refuses, was not taken: a deposit that lands in that window still reverts whole. The cost has not been worked out again for this round's rule, which a smaller excursion trips. |
| R6-3 | Low | `Round2.test_D7_RoundingCanNoLongerEndAPlanOnePeriodEarly` lost a live assertion in round 6. `assertGt(shortfall, 0)` was removed, leaving `assertLe(shortfall, 3)`, which passes when no `PlanShortfall` is emitted at all. The reviewer confirmed the shortfall is still emitted. | **Fixed.** The assertion is back. With the `PlanShortfall` emission deleted the test now fails; without the restored line it passed. |
| R6-4 | Low | `Adv2.testFuzz_CreateParamsEdges` did not test the rule it models. It passed with the tail check deleted and with both off-by-one changes to it, because its interval is an unbounded `uint64`, so its inputs were almost never admissible and never reached a dust tail. | **Fixed.** The generator bounds the interval to 1 to 366 days on most runs and builds the deposit as whole installments plus a tail, so both dust tails and admissible short ones are reached. It now fails with the tail check deleted and with each of the two off-by-one changes to it. |
| R6-5 | Low | The app could describe a reverted deposit as a waiting plan. `NoPriceHistory` was shown as "the price is paused" with "it can buy once the feed updates", but it reverts `createPlan` whole, so no plan exists. The copy for `PoolPushed` named the Chainlink price as the cause, which it is not. (The app is not in the public repository.) | **Fixed** in the app. `NoPriceHistory` is no longer shown as a waiting plan: it falls through to the plain failure, which names the error. The copy for `PoolPushed` no longer names a cause: it says that nothing was bought and that the USDC is still the person's. |
| R6-6 | Info | `ZeroShares` catches exactly zero only. A supply that mints one share-unit worth less than the deposit passes (confirmed on the mock lending adapter). | **Documented**, `docs/threat-model.md` (*Losses and the final installment*). The code is unchanged: the stricter check the reviewer offered as optional was not taken. `_supply` has one call site, in `createPlan`, so no execution can meet it. Round 5's "about 2e15 USDC" for how far out of reach this is on the pinned vault is now marked as unchecked; the reviewer's own figure, about 1e12 USDC for a 1 USDC deposit to an empty vault, is unchecked too. |
| R6-7 | Info | `setFeeRecipient` still admitted addresses that strand fees: the oracle, a route's token, a pool. Confirmed: fees claimed to the oracle stayed there. | **Fixed for the oracle** (change 3), **documented for the rest**: the list is not complete and cannot be. A two-step recipient was named as the complete answer and was not built. A stranded fee costs the fee recipient and nobody else. |
| R6-8 | Info | A last period of dust is still reachable through a lending loss. Round 6's rule holds at creation; what the last slice spends is what the plan's shares are worth. Confirmed on a mock: a last period that spent 1 wei, bought nothing, and reported a shortfall of 999,999,999. The plan completes cleanly. | **Documented**, `docs/threat-model.md` (*The TVL cap*). No change to the code: a loss is absorbed and reported, which is the design. |
| R6-9 | Info | Three harnesses no longer build a plan with a short admissible last period. `HardInvariants`, the Echidna harness and `HalmosLedger` now round the installment up, so every last period is within one wei per period of the installment. Only `Invariants.t.sol`'s handler builds last periods of any size from 1 USDC up, and the edge the rule creates (a last period of exactly 1 USDC) is pinned by two unit tests only. | **Fixed in two of the three.** `HardInvariants` and the Echidna harness have a seed-selected mode that builds whole installments plus a last period just over the minimum (`HardInvariants.test_handlerBuildsAShortTail` shows the handler reaches it). `HalmosLedger` is left as it is: its solver time is fragile and it was not touched. |
| R6-10 | Info | The rehearsal cannot tell a round-5 vault from a round-6 one: `scripts/rehearse-mainnet.sh` exercises none of round 6's three vault changes. It and `scripts/verify-base-addresses.mjs` repeat the adapter's and the oracle's constants instead of reading them. The test in the shared package's `plan.test.ts` that is named "agrees with the contract's rule" compares the TypeScript with a second TypeScript copy of the rule, not with the Solidity. | **Fixed for the rehearsal and the verifier, left for the app's test.** `scripts/rehearse-mainnet.sh` now expects `BadParams` for a 2-wei last period, for a last period one wei under 1 USDC, and for `setFeeRecipient` with the vault, each adapter and the oracle. `scripts/verify-base-addresses.mjs` now checks the constants it repeats against the `.sol` files. The shared package's test is unchanged: it still compares two TypeScript copies of the rule. |
| R6-11 | Info | The swap adapter's `catch` did not cover what its comments said. Return data from `observe` that does not decode fails outside the `catch` and reverts with no error name, not `NoPriceHistory`, and so does a `slot0` that reverts. All of them still revert the buy, and only a contract that is not a pool can produce them. Reasoned, not run. | **Fixed: the comments.** The adapter's natspec now says which cases revert `NoPriceHistory` and which revert bare. The behaviour is unchanged. `docs/threat-model.md` says the same. |
| R6-12 | Info | In the sequencer check, an uptime feed that answers 0 with a `startedAt` of 0 reads as up for longer than the grace. The reviewer recalled, and did not re-read, that Chainlink documents `startedAt` as never 0 on Base; it is consistent with failing open. Separately, `_sequencerUp` was internal, so nothing on chain showed what the oracle took the sequencer's state to be. | The first is **left** as it is. The second is **fixed**: `sequencerUp()` is a public view. |

The reviewer who read the documents also listed thirteen false, overstated
or stale statements: eleven in the threat model, this file and the public
README, one
in the swap adapter's natspec, and one in the app (R6-5). The ones in the
documents are corrected, and so is the adapter's natspec. The ones that
mattered:

- "a push of 5% needs 240 seconds", "for most of five minutes", "held at a
  wrong price for minutes" (threat model, this file): R6-1;
- R5-2 "Fixed" (this file), and "round 6 fixed what round 5 found in the
  contracts" (threat model, README): four were fixed and two bounded;
- "a price pushed in the same transaction or block cannot be bought at"
  (README): a push inside the band still goes through;
- the README's sequencer line left out that the check is skipped when the
  uptime feed cannot be read;
- the admin "cannot move user funds" (threat model, README), beside a section
  that says the key holding both roles can make due buys fill at a bad price;
- a zero-share supply "cannot happen at all" (threat model): R6-6;
- the last period "is held to" the minimum, with no "at creation" (threat
  model): R6-8.

## What changed in the code

**Change 1: five one-minute means in the swap adapter (R6-1).**
`AerodromeSwapAdapter` now reads `observe([300, 240, 180, 120, 60, 0])` and
takes five consecutive 60-second mean ticks (`TWAP_STEP` = 60, `TWAP_WINDOW`
= 300). The spot must be within `MAX_TWAP_DRIFT` = 100 ticks of EVERY one of
the five. `ticks(pool)` now returns three values, `(spot, low, high)`: the
spot, and the lowest and the highest of the five means.
`PoolPushed(spotTick, twapTick)` carries the mean furthest from the spot. The
vault and `ISwapAdapter` are unchanged.

What it stops that round 6 did not: a single excursion lands in one minute's
mean (two, if it is left standing across the boundary between two minutes),
the other minutes still disagree with the pushed spot, and the buy is
refused. One reviewer ran the rule on the fork against both attack states of
R6-1: round 6's check saw 1 tick of drift and passed, the five-mean check
saw 2,335 ticks and refused, and an honest pool read 0.

What it does not stop: an off-market block inside EACH of the five minutes,
sized so that each mean lands in the band. The first of them has to be more
than four minutes before the buy. Each leaves the attacker's own capital in
the pool across a block boundary, where anyone can trade against it. A push
left standing for two blocks across a minute boundary counts in both
minutes, so three pushes can do it; the pool is off-market for five blocks in
all either way. And there is a slow way: ONE push to the target, left
standing for about 285 of the 300 seconds, moves all five means to it and
passes. So against round 6 this changes the shape of the attack, not its
floor. The fast way now takes five off-market blocks in three to five
separate pushes, the first more than four minutes before the buy, where round
6 took one push of one to six blocks. The slow way costs one round trip of
pool fees, as before, and leaves the capital exposed for minutes instead of
seconds. The re-review of this round then measured all three shapes on a
fork: see *What passing the push check costs* below.

Tests, in `contracts/test/Round6b.t.sol`:
`test_R6b_OneBlockAtAnExtremeTickNoLongerPasses`,
`test_R6b_AnExcursionInFourOfTheFiveMinutesIsRefused`,
`test_R6b_AnExcursionInEveryMinuteStillPasses` (the residual, pinned),
`test_R6b_TheBandHoldsAgainstEveryMinute`,
`testFuzz_R6b_TheCheckIsTheFiveMeansRule`,
`test_R6b_AnHonestStepClearsWithinTheWindow`.

**Change 2: no buys on weekends, in the oracle.** `ChainlinkOracle` takes a
second constructor argument, `closedOnWeekends` (immutable; `Deploy.s.sol`
passes `true`; tests pass `false` unless they test the rule). When it is set,
`isFresh` is false from Saturday 00:00 UTC to Monday 01:00 UTC whatever the
feed says (`weekendClosed()`, `WEEKEND_LENGTH` = 49 hours). It is a pure date
rule.

Why: the B20 feeds stop for the weekend while the pools keep trading. Before
this, the 24-hour heartbeat alone kept Friday's last print "fresh" well into
Saturday, which is exactly the gap between feed and market that R5-2 and
R6-1 need.

The schedule comes from two pages, both read on 2026-10-05. Chainlink's
market-hours page (https://docs.chain.link/data-streams/market-hours) lists
the 24/5 US equities sessions and says the market is closed "weekends,
holidays, or unexpected closures; ~8:00pm Fri–8:00pm Sun ET". The Coinbase
B20 feeds page
(https://docs.chain.link/data-feeds/tokenized-equity-feeds/coinbase) says
"When underlying equity markets are closed (weekends, holidays, thin
overnight windows), the feed holds the last close" and "These feeds do not
have heartbeats during off-hours". 20:00 New York time is 00:00 UTC in summer
and 01:00 UTC in winter, so one fixed UTC window covers both: it shuts an
hour early on winter Fridays and opens an hour late on summer Mondays.

It was checked against the chain on 2026-10-05, on the NVDAc feed
(`0x04689a41629776563E6822F76f2e57D148d28513`, rounds from 2026-09-18 on).
The first print after a weekend came at Monday 00:00:31 UTC on 2026-09-21,
00:00:23 on 2026-09-28 and 00:00:43 on 2026-10-05. The last Friday prints
were at 19:55:33, 19:55:23 and 17:08:11 UTC, and there was no print between
Saturday 00:00 and Monday 00:00 UTC on any of the three weekends. Weekday
gaps between prints ran up to 14.3 hours. (An earlier draft of this
paragraph gave 08:10:17, 18:38:19 and 15.8 hours. Those came from a read
that had silently lost one round in six to rate limiting; the re-review
caught it and all 108 rounds were read again.)

`sequencerUp()` is now a public view (it was the internal `_sequencerUp`), so
a monitor can compare it with the uptime feed and see a fail-open (R6-12).

Tests: `test_R6b_WeekendBoundaries`,
`test_R6b_NoBuyOnASaturdayEvenWithAFreshPrint`,
`test_R6b_ADepositOnAWeekendOpensAPlanWithNoFirstBuy`,
`testFuzz_R6b_WeekendRuleMatchesTheCalendar`,
`test_R6b_WeekendRuleOffLeavesFreshnessAlone`,
`test_R6b_SequencerUpIsWhatIsFreshUses`.

**Change 3: the fee recipient cannot be the oracle (R6-7).**
`DcaVault.setFeeRecipient` also refuses the oracle's address (`BadParams`).
Its natspec now says the list is not complete and cannot be: a pool or a
token is still accepted and would strand the fees, which costs the fee
recipient and nobody else. Test: `test_R6b_TheFeeRecipientCannotBeTheOracle`.

## What was run on this round's code

- **Foundry, offline:** 148 pass, 0 fail, 5 skipped (the fork suites, which
  skip without an RPC). **On a fork of Base:** 27 pass, the five suites run
  one at a time and `Fork.t.sol` on one thread.
- **Each change taken out again.** The author of the tests built 38 mutants
  of the three contracts and the mainnet script in a copy (one 300-second
  mean restored, each of the five minutes dropped in turn, the band's
  comparison and the floor changed, the weekend rule removed, its length and
  its offset changed, the oracle check on the fee recipient removed, the
  tail rule deleted and moved by one, and others): every one fails at least
  one test. A second reviewer repeated the exercise independently with their
  own list and got the same answer offline. One gap, noted below (R6b-15):
  the fork suites alone do not notice a dropped middle minute.
- **The mainnet rehearsal** (`scripts/rehearse-mainnet.sh`, a local fork):
  96 checks pass, none fail, and one cannot run on a fork (the B20 buy). Its
  step 9 runs `createPlan` with a first buy on all four routes as a
  read-only call against the live node with this bytecode: all four went
  through on 2026-10-05. It also asks `isFresh` on live state one minute
  into the closure of 2026-10-03 (false, against a print 6.9 hours old) and
  one minute before it (true). A copy of the oracle with the weekend rule
  taken out of `isFresh` fails that row.
- **`scripts/verify-base-addresses.mjs`:** ALL OK.
- **Slither:** one new result, `weak-prng` on `weekendClosed`, argued in the
  threat model (*Accepted findings*). **Aderyn:** its unsafe-cast result now
  points at the two `int24` casts in `_ticks`, which sit behind the range
  check on the line before them.
- **Mythril,** on the creation bytecode with the mainnet constructor
  arguments, 900 seconds each: nothing for the swap adapter; nothing for the
  vault within that limit, which it reached; ten results for the oracle, all
  of them the design (threat model, *Accepted findings*). A first attempt on
  the source did not run at all (it could not download a compiler) and was
  discarded.
- **Echidna:** 11 properties hold over 200,302 calls. Its own Slither
  pre-pass failed to start, so this run had no Slither-derived seeds.
- **Halmos:** 18 of the 19 checks pass (`HalmosLedger` 3, `HalmosReaudit` 5,
  `HalmosRound3` 10 of 11). **One did not finish:**
  `HalmosRound3.check_boundsTwoCallsCannotLoosenEarly` was stopped after 2.5
  hours on a busy machine with no result. It took about half an hour on
  round 5's code. The functions it is about (`setBounds`, `queueBounds`,
  `activateBounds`) were not changed in round 6 or 6b; what changed is
  `createPlan`, which its two arbitrary calls can reach and whose new
  remainder is hard for the solver. That is an explanation, not a result:
  this check is NOT known to hold on this code.
- **Order of events.** Comments in the three contracts were corrected after
  the Halmos, Echidna and Mythril runs (the re-review's wording fixes; no
  code changed). The offline suite, the fork suites and the rehearsal were
  run again after the last of them.

## The re-review of round 6b (2026-10-05)

Two more reviewers, working separately, before anything was published. One
attacked the three contracts on a Base fork with the real NVDAc pool's code.
The other took the tests, the scripts, these documents and the app's
wording, and built mutants of their own. **Nothing Critical or High, and
nothing they ran pays at the 5,000 USDC cap** (at the two gaps between feed
and pool they ran, 6.2% and 1.3%). Three Mediums, all three in what
was WRITTEN, not in the code: these documents overstated what the five means
cost an attacker, three figures about the feed were wrong, and the site's
security page said there were no open Medium findings.

| ID | Severity | Finding | Status |
|---|---|---|---|
| R6b-1 | Low | **A buy that fell due on a weekend is open to anyone the moment the weekend ends.** `grace` counts from `nextExecution`, not from when a buy could first execute. Any buy due between Saturday 00:00 and Sunday 13:00 UTC is already 12 hours overdue at Monday 01:00:00, so a stranger can send it in the first block anyone can, with a push inside the band. A weekly plan opened on a Saturday is in that state for every buy of its life. Confirmed on the mock pool with the real vault, oracle and adapter: over four weeks the owner and the keeper revert `StaleOracle` at Monday 00:59:59, and at 01:00:00 a stranger's push, execute and unwind costs the plan 94 bps each time. This round introduced it by closing the weekend. Bounded by `minOut` (under 1% of the buy); measured pool fees for the push are 320 to 563 USDC per route, so it pays only above about 34,000 to 60,000 USDC executable on one route. | **Open.** Documented in the vault's natspec and the threat model. The fix is designed and not made: start the stranger's clock at the later of the due time and the end of the last closure, which needs one view on the oracle and one comparison in `executeDCA`. It changes `IPriceOracle`, so it was left for a round of its own, with its own tests and review, before mainnet. The keeper's hours need the same thought either way: it sends in US market hours only, which is after a stranger may. |
| R6b-2 | Low | **What passing the push check costs, measured for the first time.** See the table below. At a 6.2% gap the cheapest shape breaks even at about 7,600 USDC executable at once and loses money at the cap. The five means did not raise the break-even; they lengthened the exposure. | **Documented**, here and in the threat model (*The fill bound*). The cap is the control. |
| R6b-3 | Medium (documents) | These documents called round 6b "a cost multiplier" with "at least three round trips of pool fees" and said "five are needed now". One push held for about 285 of the 300 seconds passes with one round trip (confirmed on the mock pool), and three pushes pass where the text said five. | **Corrected** in the adapter's natspec, the threat model, this file and the README. |
| R6b-4 | Medium (documents) | Three figures about the feed were wrong: a first print after a weekend at "Monday 08:10:17" (it was 00:00:31), a last Friday print at "18:38:19" (19:55:23), and weekday gaps "up to 15.8 hours" (14.3). The read they came from had lost one round in six to rate limiting without saying so. | **Corrected.** All 108 rounds were read again, with retries, and the corrected paragraph says what happened. |
| R6b-5 | Medium (the app; not in this repository) | The site's security page said "Open findings, medium or above: None", said round 6 "fixed what they found", showed test counts from round 4, and said "the same code" runs on Base Sepolia. | **Corrected** in the app. |
| R6b-6 | Low | Sentences not true in every case they cover: "a push of more than about 1% in the same transaction or block is refused" (the band is on where the spot ends: after an honest 100-tick move, a 197-tick push passed and cost a plan 195 bps against the pool's honest price); "the oldest minute has to lie almost wholly after the step" (a 101-tick step clears at 241 seconds); and several in the app. | **Corrected.** |
| R6b-7 | Low | The rehearsal would have passed two wrong deployments: an adapter comparing against one mean (nothing read its constants or checked `ticks()` against the pool), and an oracle whose `isFresh` ignored the weekend rule (only the two flags were read). The address verifier is blind to both by construction. | **Fixed in the rehearsal:** it reads the six constants from the deployed contracts, checks `ticks()` against means worked out from the pool's own `observe`, and judges `isFresh` on live state inside and just before the last closure. The weekend row was checked against a mutant. The one-mean row cannot tell one mean from five while a pool has not moved for five minutes, and says so. The verifier's header now says what it cannot see. |
| R6b-8 | Low | The "STALE BUILD" assertion compares every contract the mainnet script deploys with a fresh build, but only the vault for the local and Sepolia scripts. | **Wording corrected** (`foundry.toml` and the deploy procedure). Not extended to the demo contracts. |
| R6b-9 | Info | Holidays, in practice. A Monday holiday is covered by the heartbeat: over Labor Day all four feeds were silent from Friday 2026-09-04 until Tuesday 00:00 UTC, 76 to 82 hours. A Friday or mid-week holiday is not: the last print reads fresh for most of the holiday. | **Documented.** Nothing pauses buys for a day: `disableRoute` is instant and switching back on waits 48 hours. |
| R6b-10 | Info | In winter the weekend window opens in the same second the feeds do; in summer an hour later. Reasoned from the schedule; winter cannot be checked on chain yet. On chain, a Monday's first print has been up to 1.18% from Friday's last. | **Documented** in the oracle's natspec and the threat model. A 50-hour window would give winter the same hour; left for the next round with R6b-1. |
| R6b-11 | Info | `HEARTBEAT` has no margin. A heartbeat print on the GOOGL feed landed 24 hours and 18 seconds after the one before it (2026-08-27 to 08-28), so for those seconds a live feed read stale. A deposit in that gap opens a plan with no first buy; a retry clears it. | **Left.** Harmless. |
| R6b-12 | Info | Stalling a route costs about what it did: one block at 3,030 ticks, 514 USDC of pool fees, refuses buys for 300 seconds (round 6's equivalent: 526). About 6,000 USDC an hour per route. No cheap way to keep a route refused was found. | **Documented.** |
| R6b-13 | Info | What the check costs an honest market, replayed over each pool's own 2,048 observations: NVDAc and GOOGLc never refused; AAPLc refused for 40 seconds and METAc for 74, both at Monday's US open (one 300-second mean: 0 and 6). | **Documented.** |
| R6b-14 | Info | Stale deploy bytecode: closed under the shipped `foundry.toml` (after body-only edits to all four contracts, a dry run of `Deploy.s.sol` with no `--force` produced creation code equal to a fresh build). Reopened by removing the line, by `FOUNDRY_DYNAMIC_TEST_LINKING=true` in the environment, or by a forge that ignores the key. With linking on, a same-length body edit deployed the old oracle silently. | **Documented**; the deploy procedure checks what forge resolved (`forge config`) before the deploy. |
| R6b-15 | Info | Two limits of the tests. The fork suites alone do not notice a dropped middle minute (the offline suite catches all five). `Round6.testFuzz_R5_2_TheMeanTickIsTheFloor` no longer fuzzes the full `int56` range, and its refusal branch repeats the contract's comparison; deterministic tests cover both. | **Left**, recorded. |

The same reviewer listed six sentences in the adapter's natspec, one in the
oracle's and one in the vault's that were false or overstated ("a push in
this transaction or block cannot pass" where a 95-tick push passes; "could
be moved that way by ONE such block" where the arithmetic needs 75,000
ticks, not 15,000; "and the breaker" where the breaker reads the pushed spot
and adds nothing; and others). All are corrected in the source.

### What passing the push check costs (R6b-2)

A Base fork at block 52,221,245 (Monday 2026-10-05 20:23 UTC): the real
NVDAc pool's code and state, a stand-in token at the stock's address, the
real vault and adapter, a feed whose last print is 20 hours old and 600 ticks
(6.18%) above the pool, a buy 12 hours overdue, a stranger as caller, and
nobody trading against the attacker, which is the attacker's best case.
Controls first: left alone, `PoolDiverged`; a push to the print in one
transaction, `PoolPushed`; one block at 90,000 ticks (1.85 million USDC in),
where the single 300-second mean reads exactly the strike and round 6 would
have passed, refused; six blocks at 15,000 ticks, refused.

Then the residual, which executes. The attacker adds their own liquidity
under the strike first (`pool.mint` is open to anyone); without it the pool
is too thin past about 600 ticks for the strike to fill at all. The plan got
654 to 666 bps less stock than the untouched pool would have given.

| Shape | Pushes | Block intervals exposed | USDC in per push | Paid over market per push, at risk | Pool fees |
|---|---|---|---|---|---|
| Five one-block pushes at 20,000 ticks | 5 | 5 | 543,800 | 25,600 | 2,713 |
| Three pushes (2 + 2 + 1 blocks) | 3 | 5 | 543,800 | 25,600 | 1,628 |
| One push to the print, held 300 s | 1 | 150 | 505,200 | 7,300 | 504 |

The attacker's net result in USDC, by how much is executable on the route at
once:

| Executable at once | Five pushes | Three pushes | Hold |
|---|---|---|---|
| 5,000 (the whole launch cap) | -2,315 | -1,255 | -166 |
| 10,000 | -1,955 | -905 | +175 |
| 50,000 | +890 | +1,862 | +2,863 |
| 100,000 | +4,451 | +5,324 | +6,227 |

Break-even at that gap: about 7,600 USDC (hold), 24,000 (three pushes),
41,000 (five pushes). At a 1.3% gap the shortfall was 215 bps; the hold lost
280 USDC at 5,000 and made 719 at 50,000, and three pushes lost money at
both. Not measured: whether anyone would trade against the attacker, what
block position costs, and anything on the real token's side. Reasoned, not
run: a large liquidity provider who withdrew first would cut both the cost
and the capital. Also by arithmetic, not run: the cost of the hold was about
500 USDC whatever the size of the buy, so the break-even falls as the gap
widens, and a gap of about 10% would bring it down to the cap. The widest
move between two consecutive prints on the four feeds from 2026-08-05 to
2026-10-05 was 1.87%, and the widest from a Friday's last print to the
Monday's first was 1.18%.

Read plainly: the five means did not raise the break-even. Round 6's figure,
about 13,000 USDC, was for one push held six blocks with no added liquidity.
The cheapest shape now is one push held for the whole window, at about
7,600. What the five means changed is exposure: the cheapest shape leaves
half a million USDC in the pool for 150 block intervals, where round 6
needed one to six. Whether that exposure is worth anything depends on who
is trading these pools at that hour, and that is not known.

## Considered and not done

- **A time-weighted median of the pool's raw observations.** It would make
  "held off-market for most of the window" true, because one block is under
  1% of the window. It needs a walk over the pool's observation ring, with
  gas that grows with how often the pool trades, and much more code in a
  contract that cannot be upgraded. It is recorded here as the stronger
  design for a later version.
- **Anything more for R5-1.** It stays a disclosed risk. The route's feed is
  not pinned in the vault, for the reasons Round 6 gives, and the deploy
  still hands the vault's admin and the oracle's admin to the same multisig.
  Splitting the two roles would not remove the power, because the oracle's
  admin alone can queue a feed change.
- **Letting `createPlan` skip its first buy when the venue refuses** (R6-2).
  A deposit whose first buy is refused by the push check reverts whole, as
  in round 6.
- **A two-step fee recipient** (R6-7). A stranded fee costs the fee
  recipient and nobody else.
- **A stricter zero-share check** (R6-6). It was offered as optional. The
  case it would catch is out of reach on the pinned vault by round 5's
  arithmetic and by the re-review's. Neither was checked on chain.

## What it costs

- **Gas.** About 80,000 more per buy than round 6's one-mean check. A
  reviewer measured the read alone on the real NVDAc pool, cold: 159,448 gas
  against 78,948. Round 6's own figure for what its check added to a buy was
  between 21,000 and 41,000.
- **A fast market waits longer.** After an honest move of more than about 1%,
  buys on that route are refused for up to 300 seconds. Under round 6 a 2%
  step cleared after 150 seconds. Now some of the oldest of the five minutes
  has to lie after the step, half of it for a 2% step and nearly all of it
  for a large one, so any step past the band waits more than 240 seconds and
  at most 300. A deposit whose first buy is refused this way reverts whole, as
  before.
- **Weekends.** A buy that falls due on a weekend waits until Monday 01:00
  UTC, or the next fresh print after it. A deposit on a weekend opens the
  plan with no first buy, the same path as any stale feed; it does not
  revert. Exits are never affected. The window is an hour wider than the
  feeds' own on one side or the other: on all three weekends read (2026-09-21,
  2026-09-28, 2026-10-05) the feed printed within a minute of Monday 00:00
  UTC, and this vault would have waited until 01:00.

## What is still open

- **R5-2 and R6-1 are bounded, not closed.** A push that ends within about 1%
  of all five means passes in one transaction; from the far edge of the band
  that is a move of up to about 2%. A larger one passes with an off-market
  block in each of five minutes, or with one push held for most of the five
  minutes. Measured (R6b-2): with a feed 6.2% above the pool and nobody
  trading against the attacker, the cheapest shape breaks even at about
  7,600 USDC executable at once. It loses money at the 5,000 USDC cap. **The
  cap must not be raised past that on the strength of this check.** The
  stronger design is under *Considered and not done*.
- **R6b-1: weekend-due buys are open to anyone when the weekend ends.**
  Under 1% of the buy, and unprofitable until tens of thousands of USDC are
  executable on one route. The fix is designed and waits for its own round.
- **Exchange holidays.** The feed holds its last value on a holiday as it
  does on a weekend, and the rule knows nothing about them. The heartbeat is
  still the only limit there, so a print can read fresh for up to 24 hours
  into a holiday. A Monday holiday is covered in practice (R6b-9); Thanksgiving
  (a Thursday), 25 December 2026 and 1 January 2027 (both Fridays) are not.
- **One Halmos check has no result on this code** (see *What was run*).
- **The calendar cannot be changed.** If the feeds one day print through the
  weekend, this vault still will not buy on one.
- **The 24-hour heartbeat itself.** A weekday print can be many hours old:
  the feed prints on a 0.5% move or the heartbeat, and gaps of up to 14.3
  hours were seen.
- **R5-1.** One multisig holds both admin roles. Disclosed, bounded by the
  push check, not removed.
- **The Base Sepolia test deployment** has none of this round either. Its
  swap adapter and oracle are stand-ins, and its vault predates round 6.
