#!/usr/bin/env bash
# Dress rehearsal of the Base mainnet deploy, on a local fork.
#
#   bash scripts/rehearse-mainnet.sh
#   ADMIN_MULTISIG=0xYourSafe KEEPER_ADDRESS=0xYourKeeper bash scripts/rehearse-mainnet.sh
#
# NOTHING HERE REACHES A REAL CHAIN. It starts its own anvil fork, runs the
# real contracts/script/Deploy.s.sol against it with anvil's public dev key,
# walks the steps that follow a deploy (the Safe accepts admin, allowlists the
# keeper and opens deposits; a deposit; an exit; the 48-hour queue), and stops
# the anvil it started.
#
# THREE THINGS KEEP IT THAT WAY, and none of them is "being careful":
#   1. Every send goes to http://127.0.0.1:$PORT, written out in this file, and
#      the script refuses to continue unless that endpoint answers
#      anvil_nodeInfo, a method no real node has.
#   2. The only keys that sign are anvil's dev accounts, which anvil prints in
#      its own banner. This script reads no .env and asks for no real key.
#      (forge loads the repo's .env by itself; the key and the RPC it uses
#      here are the ones on its command line below, not anything in there.)
#   3. THE FORK RUNS AS CHAIN 31337, NOT 8453. A transaction signed for a fork
#      that keeps chain id 8453 is a VALID BASE MAINNET TRANSACTION: same chain
#      id, and a fork starts every account at its mainnet nonce. Signing a
#      rehearsal with a real key on such a fork would produce the real deploy,
#      ready to be replayed by anyone who saw it. On 31337 a signature cannot
#      be replayed on Base at all. It also keeps the rehearsal's broadcast file
#      (contracts/broadcast/Deploy.s.sol/31337/) away from the real one (.../8453/),
#      which scripts/print-base-deployment.mjs reads.
#
# THE POSTURE IT CHECKS. Deploy.s.sol lists all four routes and ends with
# deposits PAUSED. So straight after the deploy: routes 1 to 4 are enabled,
# the setup window is closed, and createPlan reverts Paused. The Safe then
# accepts admin on the vault AND the oracle, allowlists the keeper, and only
# then opens deposits with setDepositsPaused(false). Opening is its own step,
# here and on the day.
#
# WHAT A FORK CAN AND CANNOT SHOW. B20 stock tokens are precompiles behind a
# one-byte 0xef stub; anvil's EVM cannot run them. So on the fork:
#   - the deploy, adapter binding, the four routes, finishSetup, the pause, the
#     admin handover, the keeper allowlist, opening deposits, the USDC deposit,
#     the Morpho supply leg, exitPlan and the 48-hour queue all run for real
#     against forked state. So do the reads the round-6 and 6b checks make:
#     the oracle's sequencer uptime feed and its weekend rule, and each pool's
#     five one-minute averages through the deployed swap adapter's ticks()
#     (step 2);
#   - a BUY cannot run. With a fresh feed createPlan's first buy fires and
#     reverts at the stub (balanceOf on the token -> OpcodeNotFound), so the
#     script shows that revert. Then, WHATEVER DAY IT IS RUN ON, it moves the
#     fork's clock past the feed's heartbeat, where a deposit opens the plan
#     with no first buy: the steps after that do not depend on the calendar.
#
# THE WEEKEND. The oracle Deploy.s.sol builds is closed from Saturday 00:00 to
# Monday 01:00 UTC: nothing is fresh then, whatever the feeds say. Run inside
# that window, step 6 says so instead of calling the feed stale, and step 9
# simulates the buys about 2 minutes after the feed's last update, or, when
# that is itself inside the closure, one minute before the closure began. Run
# outside it, nothing here changes. Either way the verdict means the same
# thing. Step 9 also JUDGES the rule on any day: it asks isFresh on live
# state one minute into the most recent closure (must be false, against a
# print that is hours old) and one minute before it (must be true).
# The buys are covered by step 9 instead: read-only eth_calls against the LIVE
# node, with the bytecode and storage this rehearsal just produced injected as
# a state override. The real node runs the precompile, so for each of the four
# routes the real createPlan, real swap and real B20 delivery are simulated end
# to end. No transaction, no key, no gas.
#
# ENV (all optional, none secret):
#   BASE_RPC_URL     fork source and live-node simulation. Default: the public
#                    endpoint, which rate-limits; a paid URL is steadier.
#   ADMIN_MULTISIG   the Safe. Impersonated on the fork. Default: anvil account 1.
#   KEEPER_ADDRESS   the keeper. Default: anvil account 2.
#   REHEARSAL_PORT   default 8571.
#   REHEARSAL_FORK_BLOCK  fork at this block instead of the head. A block in
#                    market hours exercises the fresh-feed branch of step 6,
#                    and one on a Saturday or Sunday the weekend branch.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."

FORK_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
PORT="${REHEARSAL_PORT:-8571}"
RPC="http://127.0.0.1:$PORT"
CHAIN=31337

# anvil's well-known dev accounts. Public, worthless, and the point.
DEV_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ADMIN="${ADMIN_MULTISIG:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"
KEEPER="${KEEPER_ADDRESS:-0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}"
DEPOSITOR=0x90F79bf6EB2c4f870365E785982E1f101E93b906
DEPOSITOR_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
# Holds no key anywhere: the `from` of the read-only live simulation.
PROBE=0xbD79B7E4EBB4429e715205d92adAbAFaf3b30F34
ZERO=0x0000000000000000000000000000000000000000

cfg() { node -e 'const c=require("./packages/config/addresses.base.json");console.log(process.argv[1].split(".").reduce((o,k)=>o[k],c))' "$1"; }
USDC="$(cfg core.USDC.address)"
MORPHO_VAULT="$(cfg yieldVault.address)"
USDC_HOLDER="$(cfg core.AaveV3aUSDC.address)"   # Aave's aUSDC: holds the pool's USDC
SEQ_FEED="$(cfg core.SequencerUptimeFeed.address)"
# The launch routes, one per line: "<id> <ticker> <token> <pool> <feed>". The
# id is the file's order from 1, which is what Deploy.s.sol lists them under
# and what the web app looks them up by.
ROUTES="$(node -e 'require("./packages/config/addresses.base.json").routes.forEach((r,i)=>console.log(i+1,r.ticker,r.token,r.pool,r.feed))')"
NROUTES="$(printf '%s\n' "$ROUTES" | wc -l | tr -d ' ')"
route() { printf '%s\n' "$ROUTES" | awk -v n="$1" -v f="$2" 'NR==n{print $f}'; }   # route <id> <field 2..5>
NVDAC="$(route 1 3)"; NVDAC_POOL="$(route 1 4)"; NVDAC_FEED="$(route 1 5)"
LAST="$NROUTES"; NEXT_ID=$((NROUTES + 1))
GPO=0x420000000000000000000000000000000000000F   # OP-stack GasPriceOracle

FAILS=0; NOTRUN=0
say()    { printf '\n== %s\n' "$1"; }
pass()   { printf '  PASS     %s\n' "$1"; }
fail()   { printf '  FAIL     %s\n' "$1"; FAILS=$((FAILS + 1)); }
notrun() { printf '  NOT RUN  %s\n' "$1"; NOTRUN=$((NOTRUN + 1)); }
note()   { printf '           %s\n' "$1"; }
lc()     { printf '%s' "$1" | tr 'A-F' 'a-f'; }
utc()    { node -e 'const d=new Date(Number(process.argv[1])*1000);console.log(["Sun","Mon","Tue","Wed","Thu","Fri","Sat"][d.getUTCDay()]+" "+d.toISOString().slice(0,19).replace("T"," ")+" UTC")' "$1"; }
eq()     { if [ "$(lc "$2")" = "$(lc "$3")" ]; then pass "$1 = $2"; else fail "$1 is $2, expected $3"; fi; }
rd()     { cast call "$@" --rpc-url "$RPC" | awk 'NR==1{print $1}'; }
rdall()  { cast call "$@" --rpc-url "$RPC" | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//'; }
live()   { sleep 1; cast "$@" --rpc-url "$FORK_URL"; }
# expect_revert <label> <Error or Error(types)> <cast call args...>
expect_revert() {
  local label="$1" sig="$2"; shift 2
  case "$sig" in *"("*) ;; *) sig="$sig()" ;; esac
  local name="${sig%%(*}" sel out; sel="$(cast sig "$sig")"
  out="$(cast call "$@" --rpc-url "$RPC" 2>&1 || true)"
  if printf '%s' "$out" | grep -q -e "$name" -e "$sel"; then pass "$label reverts $name"
  else fail "$label: expected revert $name, got: $(printf '%s' "$out" | head -1 | cut -c1-160)"; fi
}
send()   { cast send "$@" --rpc-url "$RPC" >/dev/null; }
as_admin()   { cast rpc anvil_impersonateAccount "$ADMIN" --rpc-url "$RPC" >/dev/null
               cast rpc anvil_setBalance "$ADMIN" 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null; }
not_admin()  { cast rpc anvil_stopImpersonatingAccount "$ADMIN" --rpc-url "$RPC" >/dev/null; }
ROUTE_SIG='routes(uint32)(address,address,address,uint8,bool)'
ROUTE_ARG='(uint32,(address,address,address,uint8,bool))'
PLAN_SIG='createPlan(uint32,uint256,uint256,uint64)'

# ------------------------------------------------------------------ anvil
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is in use. Set REHEARSAL_PORT to a free one."; exit 1
fi
TMP="$(mktemp -d -t dca-rehearsal)"
# Two spellings rather than an array of flags: macOS ships bash 3.2, where an
# EMPTY array under `set -u` is itself an unbound-variable error.
if [ -n "${REHEARSAL_FORK_BLOCK:-}" ]; then
  anvil --fork-url "$FORK_URL" --fork-block-number "$REHEARSAL_FORK_BLOCK" --chain-id "$CHAIN" --port "$PORT" --host 127.0.0.1 \
    --retries 10 --fork-retry-backoff 1500 --compute-units-per-second 100 >"$TMP/anvil.log" 2>&1 &
else
  anvil --fork-url "$FORK_URL" --chain-id "$CHAIN" --port "$PORT" --host 127.0.0.1 \
    --retries 10 --fork-retry-backoff 1500 --compute-units-per-second 100 >"$TMP/anvil.log" 2>&1 &
fi
ANVIL_PID=$!
# Only the anvil this script started, by its pid. Never pkill.
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 90); do
  cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
  kill -0 "$ANVIL_PID" 2>/dev/null || { echo "anvil exited:"; tail -20 "$TMP/anvil.log"; exit 1; }
  sleep 1
done

# THE GUARD. Run before anything is signed.
case "$RPC" in http://127.0.0.1:*) ;; *) echo "REFUSING: $RPC is not 127.0.0.1"; exit 1 ;; esac
cast rpc anvil_nodeInfo --rpc-url "$RPC" >/dev/null 2>&1 || { echo "REFUSING: $RPC does not answer anvil_nodeInfo"; exit 1; }
[ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN" ] || { echo "REFUSING: $RPC is not chain $CHAIN"; exit 1; }

FORK_BLOCK="$(cast block-number --rpc-url "$RPC")"
echo "Rehearsal fork: $RPC (anvil pid $ANVIL_PID, chain $CHAIN) of Base mainnet at block $FORK_BLOCK"
echo "admin (Safe stand-in) $ADMIN    keeper $KEEPER"

# ----------------------------------------------------------------- deploy
say "1. Deploy.s.sol, broadcast to the local fork"
# --force, ALWAYS. A script carries the creation code of what it deploys
# inside its own build artifact, and forge 1.8.3 (dynamic_test_linking, on by
# default) does not rebuild a script when only a function BODY in
# contracts/src changed: without --force this step can deploy the code as it
# was before the last edit, and every check below would then be describing a
# vault the source no longer says. Measured in round 6b
# (contracts/test/DeployScripts.t.sol, _sameCode). The real deploy needs the
# same flag, or a `forge clean` first, for the same reason.
if ! ADMIN_MULTISIG="$ADMIN" forge script contracts/script/Deploy.s.sol:Deploy --force \
      --rpc-url "$RPC" --private-key "$DEV_KEY" --broadcast >"$TMP/deploy.txt" 2>&1; then
  tail -40 "$TMP/deploy.txt"; fail "forge script failed"; echo; echo "REHEARSAL FAILED at the deploy."; exit 1
fi
RUN="contracts/broadcast/Deploy.s.sol/$CHAIN/run-latest.json"
eval "$(node -e '
  const r = require("./" + process.argv[1]);
  const tx = (n) => r.transactions.find((t) => t.transactionType === "CREATE" && t.contractName === n);
  const at = (n) => tx(n).contractAddress;
  const gas = r.receipts.reduce((s, x) => s + BigInt(x.gasUsed), 0n);
  const ok = r.receipts.every((x) => x.status === "0x1");
  const vaultBlock = Number(BigInt(r.receipts.find((x) => x.transactionHash === tx("DcaVault").hash).blockNumber));
  console.log(`ORACLE=${at("ChainlinkOracle")} YIELD=${at("MorphoAdapter")} SWAP=${at("AerodromeSwapAdapter")} VAULT=${at("DcaVault")} GAS=${gas} NTX=${r.receipts.length} ALLOK=${ok} VAULT_BLOCK=${vaultBlock}`);
' "$RUN")"
[ "$ALLOK" = "true" ] && pass "$NTX transactions, all status 1, $GAS gas" || fail "a deploy transaction reverted"
note "oracle $ORACLE  yieldAdapter $YIELD  swapAdapter $SWAP  vault $VAULT"

# Bytecode and storage of the deployment, for the live simulation in step 9.
# Slots follow `forge inspect DcaVault storage-layout`: 0 admin,
# 2 feeRecipient+feeBps+bounds, 3 tvlCap, 5 the pause/setup flags,
# 12 nextPlanId, 14 the reentrancy lock, routes[id] in three slots under 8;
# and the oracle's 0 admin and feedOf[token] under 2.
st()   { printf '%s:%s:%s' "$1" "$2" "$(cast storage "$1" "$2" --rpc-url "$RPC")"; }
plus() { node -e 'console.log("0x"+(BigInt(process.argv[1])+BigInt(process.argv[2])).toString(16).padStart(64,"0"))' "$1" "$2"; }
ov_state() {
  local out base id tok
  out="$(st "$VAULT" 0),$(st "$VAULT" 2),$(st "$VAULT" 3),$(st "$VAULT" 5),$(st "$VAULT" 12),$(st "$VAULT" 14),$(st "$ORACLE" 0)"
  while read -r id _ tok _ _ <&3; do
    base="$(cast index uint32 "$id" 8)"
    out="$out,$(st "$VAULT" "$base"),$(st "$VAULT" "$(plus "$base" 1)"),$(st "$VAULT" "$(plus "$base" 2)"),$(st "$ORACLE" "$(cast index address "$tok" 2)")"
  done 3<<EOF
$ROUTES
EOF
  printf '%s' "$out"
}
OV_CODE="$ORACLE:$(cast code "$ORACLE" --rpc-url "$RPC"),$YIELD:$(cast code "$YIELD" --rpc-url "$RPC"),$SWAP:$(cast code "$SWAP" --rpc-url "$RPC"),$VAULT:$(cast code "$VAULT" --rpc-url "$RPC")"
OV_AS_DEPLOYED="$(ov_state)"   # deposits paused, deployer still admin

say "2. What the deploy left behind: four routes, the window closed, deposits PAUSED"
eq "vault.usdc()"            "$(rd "$VAULT" 'usdc()(address)')" "$USDC"
eq "vault.adapter()"         "$(rd "$VAULT" 'adapter()(address)')" "$YIELD"
eq "vault.swapper()"         "$(rd "$VAULT" 'swapper()(address)')" "$SWAP"
eq "vault.oracle()"          "$(rd "$VAULT" 'oracle()(address)')" "$ORACLE"
eq "yieldAdapter.vault()"    "$(rd "$YIELD" 'vault()(address)')" "$VAULT"
eq "yieldAdapter.vault4626()" "$(rd "$YIELD" 'vault4626()(address)')" "$MORPHO_VAULT"
eq "swapAdapter.vault()"     "$(rd "$SWAP" 'vault()(address)')" "$VAULT"
eq "vault.tvlCap()"          "$(rd "$VAULT" 'tvlCap()(uint256)')" "5000000000"
eq "vault.feeBps()"          "$(rd "$VAULT" 'feeBps()(uint16)')" "0"
eq "vault.maxSlippageBps()"  "$(rd "$VAULT" 'maxSlippageBps()(uint16)')" "100"
eq "vault.maxDeviationBps()" "$(rd "$VAULT" 'maxDeviationBps()(uint16)')" "500"
eq "vault.feeRecipient()"    "$(rd "$VAULT" 'feeRecipient()(address)')" "$ADMIN"
eq "oracle.sequencerUptimeFeed()" "$(rd "$ORACLE" 'sequencerUptimeFeed()(address)')" "$SEQ_FEED"
# Round 6b. The oracle is built CLOSED ON WEEKENDS: immutable, like the uptime
# feed, so a deploy without it could not be put right. Then its two public
# views, each against its own source at one and the same fork block:
# weekendClosed() against the UTC calendar, and sequencerUp() against the
# uptime feed as read here.
eq "oracle.closedOnWeekends()" "$(rd "$ORACLE" 'closedOnWeekends()(bool)')" "true"
# The numbers the two checks run on, read from what was just deployed rather
# than repeated from the source: a deployment built with other constants, or
# with the single-average adapter (which has no TWAP_STEP), fails here.
eq "oracle.WEEKEND_LENGTH() (49 hours)"  "$(rd "$ORACLE" 'WEEKEND_LENGTH()(uint256)')"  "176400"
eq "oracle.HEARTBEAT() (24 hours)"       "$(rd "$ORACLE" 'HEARTBEAT()(uint256)')"       "86400"
eq "oracle.SEQUENCER_GRACE() (1 hour)"   "$(rd "$ORACLE" 'SEQUENCER_GRACE()(uint256)')" "3600"
eq "swapAdapter.TWAP_WINDOW() (300 s)"   "$(rd "$SWAP" 'TWAP_WINDOW()(uint32)')"        "300"
eq "swapAdapter.TWAP_STEP() (60 s)"      "$(rd "$SWAP" 'TWAP_STEP()(uint32)')"          "60"
eq "swapAdapter.MAX_TWAP_DRIFT() (100 ticks)" "$(rd "$SWAP" 'MAX_TWAP_DRIFT()(int24)')" "100"
NOW_BLOCK="$(cast block-number --rpc-url "$RPC")"
NOW_TS="$(cast block "$NOW_BLOCK" -f timestamp --rpc-url "$RPC")"
BY_CALENDAR="$(node -e 'const d=new Date(Number(process.argv[1])*1000),w=d.getUTCDay();console.log(w===6||w===0||(w===1&&d.getUTCHours()<1))' "$NOW_TS")"
eq "oracle.weekendClosed() at $(utc "$NOW_TS") (closed Sat 00:00 to Mon 01:00 UTC)" \
   "$(cast call "$ORACLE" 'weekendClosed()(bool)' --block "$NOW_BLOCK" --rpc-url "$RPC")" "$BY_CALENDAR"
set -- $(cast call "$SEQ_FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --block "$NOW_BLOCK" --rpc-url "$RPC" | awk '{print $1}' | tr '\n' ' ')
BY_FEED="$(node -e 'const [answer,since,now]=process.argv.slice(1).map(Number);console.log(answer===0&&now>=since&&now-since>=3600)' "${2:-1}" "${3:-0}" "$NOW_TS")"
eq "oracle.sequencerUp() (the uptime feed answers ${2:-nothing}, since ${3:-?}; up means 0 and for an hour)" \
   "$(cast call "$ORACLE" 'sequencerUp()(bool)' --block "$NOW_BLOCK" --rpc-url "$RPC")" "$BY_FEED"
while read -r id t tok pool feed <&3; do
  eq "vault.routes($id) $t"  "$(rdall "$VAULT" "$ROUTE_SIG" "$id")" "$tok $pool $feed 0 true"
  eq "oracle.feedOf($t)"     "$(rd "$ORACLE" 'feedOf(address)(address)' "$tok")" "$feed"
  # The read the swap adapter makes before every buy: the pool's spot tick,
  # and the lowest and highest of its own five one-minute mean ticks. A pool
  # that cannot answer it is a route that cannot buy. How far apart they are
  # is the market's business: more than 100 ticks from either a buy waits,
  # and that is said rather than failed.
  TICKS="$(cast call "$SWAP" 'ticks(address)(int24,int24,int24)' "$pool" --block "$NOW_BLOCK" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//' || true)"
  if printf '%s' "$TICKS" | grep -Eq '^-?[0-9]+ -?[0-9]+ -?[0-9]+$'; then
    set -- $TICKS
    OVER=$(( $1 - $2 )); UNDER=$(( $3 - $1 ))
    pass "swapAdapter.ticks($t pool): spot $1, its five 60 s means run from $2 to $3 (the band is 100 ticks from each)"
    if [ "$OVER" -gt 100 ] || [ "$UNDER" -gt 100 ]; then
      note "outside the band: a buy on $t would revert PoolPushed until every one of the five averages catches up."
    fi
    # The same five means, worked out here from the pool's own observe() at
    # the same block: floor((cum[i+1] - cum[i]) / 60) for each minute. What the
    # adapter calls the lowest and the highest must be the lowest and highest
    # of these. (When the pool has not moved in five minutes all five are
    # equal, and this row cannot tell five averages from one. The constants
    # above and the source verification after the deploy are what do.)
    WANT="$(cast call "$pool" 'observe(uint32[])(int56[],uint160[])' '[300,240,180,120,60,0]' --block "$NOW_BLOCK" --rpc-url "$RPC" 2>/dev/null | head -1 | node -e '
      let line = require("fs").readFileSync(0, "utf8").split("\n")[0] || "";
      line = line.replace(/^\[/, "").replace(/\]\s*$/, "").replace(/\[[^\]]*\]/g, "");
      const cum = (line.match(/-?\d+/g) || []).map(BigInt);
      if (cum.length !== 6) { console.log("unreadable"); process.exit(0); }
      const means = [];
      for (let i = 0; i < 5; i++) { const d = cum[i + 1] - cum[i]; let m = d / 60n; if (d < 0n && d % 60n !== 0n) m -= 1n; means.push(m); }
      const lo = means.reduce((a, b) => (b < a ? b : a)), hi = means.reduce((a, b) => (b > a ? b : a));
      console.log(`${lo} ${hi}`);' || true)"
    eq "swapAdapter.ticks($t pool) low and high against the pool's own observe([300,240,180,120,60,0])" "$2 $3" "$WANT"
  else
    fail "swapAdapter.ticks($t pool) did not answer: a buy on this route would revert NoPriceHistory"
  fi
done 3<<EOF
$ROUTES
EOF
eq "vault.routes($NEXT_ID).token (no route past the last)" "$(rd "$VAULT" "$ROUTE_SIG" "$NEXT_ID")" "$ZERO"
eq "vault.setupFinished()"   "$(rd "$VAULT" 'setupFinished()(bool)')" "true"
eq "vault.depositsPaused()"  "$(rd "$VAULT" 'depositsPaused()(bool)')" "true"
expect_revert "initRoute($NEXT_ID) after finishSetup" SetupClosed "$VAULT" "initRoute$ROUTE_ARG" "$NEXT_ID" "($NVDAC,$NVDAC_POOL,$NVDAC_FEED,0,true)" --from "$DEPLOYER"
expect_revert "createPlan straight after the deploy" Paused "$VAULT" "$PLAN_SIG" 1 100000000 10000000 86400 --from "$DEPOSITOR"

say "3. The \"deployment\" object for addresses.base.json, straight after the deploy"
# The same script the real run uses, pointed at the fork. It marks its output
# as a rehearsal, and what it reads is the chain, not the broadcast file.
PRINTED="$(BASE_RPC_URL="$RPC" node scripts/print-base-deployment.mjs --keeper "$KEEPER" --run "$RUN" 2>"$TMP/printer-notes.txt" || true)"
if node -e '
  const [line, vault, block, routes] = process.argv.slice(1);
  if (!line.startsWith("REHEARSAL ONLY")) { console.log("  FAIL     the printer did not mark a fork run as a rehearsal: " + line.slice(0, 80)); process.exit(1); }
  const d = JSON.parse(line.slice(line.indexOf("{")));
  const want = Object.fromEntries(routes.trim().split("\n").map((l) => l.split(" ")).map(([id, t]) => [t, Number(id)]));
  const bad = [];
  if (JSON.stringify(d.routeIds) !== JSON.stringify(want)) bad.push(`routeIds ${JSON.stringify(d.routeIds)}, expected ${JSON.stringify(want)}`);
  if (d.vault.toLowerCase() !== vault.toLowerCase()) bad.push(`vault ${d.vault}`);
  if (d.deployBlock !== Number(block)) bad.push(`deployBlock ${d.deployBlock}, expected ${block}`);
  for (const k of ["oracle", "yieldAdapter", "swapAdapter", "keeper"]) if (!/^0x[0-9a-fA-F]{40}$/.test(d[k] ?? "")) bad.push(`${k} missing`);
  if (bad.length) { for (const b of bad) console.log("  FAIL     " + b); process.exit(1); }
  console.log(`  PASS     routeIds = ${JSON.stringify(d.routeIds)}`);
  console.log(`  PASS     deployBlock = ${d.deployBlock}, the block of the vault creation receipt`);
  console.log(`           ${JSON.stringify(d)}`);
' "$PRINTED" "$VAULT" "$VAULT_BLOCK" "$ROUTES"; then :; else FAILS=$((FAILS + 1)); sed 's/^/           /' "$TMP/printer-notes.txt" | tail -8; fi
note "and what it says about the vault at this point, before the Safe has done anything:"
grep -E 'admin|PAUSED|OPEN|allowlisted|NOT enabled|setup window' "$TMP/printer-notes.txt" | sed 's/^ */             /' || true

say "4. Admin handover (two-step): the Safe accepts on the vault AND the oracle"
eq "vault.admin() before accept"   "$(rd "$VAULT" 'admin()(address)')" "$DEPLOYER"
eq "vault.pendingAdmin()"          "$(rd "$VAULT" 'pendingAdmin()(address)')" "$ADMIN"
eq "oracle.pendingAdmin()"         "$(rd "$ORACLE" 'pendingAdmin()(address)')" "$ADMIN"
expect_revert "acceptAdmin from a stranger" NotPendingAdmin "$VAULT" 'acceptAdmin()' --from "$DEPOSITOR"
# Stated, not judged: the pause is only as strong as whoever is admin, and
# until the Safe accepts that is still the deployer key.
if cast call "$VAULT" 'setDepositsPaused(bool)' false --from "$DEPLOYER" --rpc-url "$RPC" >/dev/null 2>&1; then
  note "until the Safe accepts, the DEPLOYER key is still admin and could open deposits itself: accept promptly."
fi
as_admin
send "$VAULT" 'acceptAdmin()' --from "$ADMIN" --unlocked
send "$ORACLE" 'acceptAdmin()' --from "$ADMIN" --unlocked
eq "vault.admin()"         "$(rd "$VAULT" 'admin()(address)')" "$ADMIN"
eq "oracle.admin()"        "$(rd "$ORACLE" 'admin()(address)')" "$ADMIN"
eq "vault.pendingAdmin()"  "$(rd "$VAULT" 'pendingAdmin()(address)')" "$ZERO"
eq "oracle.pendingAdmin()" "$(rd "$ORACLE" 'pendingAdmin()(address)')" "$ZERO"
expect_revert "setKeeper from the old deployer" NotOwner "$VAULT" 'setKeeper(address,bool)' "$KEEPER" true --from "$DEPLOYER"
expect_revert "setDepositsPaused(false) from the old deployer" NotOwner "$VAULT" 'setDepositsPaused(bool)' false --from "$DEPLOYER"
# Rounds 6 and 6b: the fee recipient cannot be the vault, either adapter or
# the oracle. Nothing can be swept from any of the four, so fees claimed there
# would stay for good. Calls, not sends: the recipient is left as deployed.
expect_revert "setFeeRecipient(the vault)"         BadParams "$VAULT" 'setFeeRecipient(address)' "$VAULT"  --from "$ADMIN"
expect_revert "setFeeRecipient(the yield adapter)" BadParams "$VAULT" 'setFeeRecipient(address)' "$YIELD"  --from "$ADMIN"
expect_revert "setFeeRecipient(the swap adapter)"  BadParams "$VAULT" 'setFeeRecipient(address)' "$SWAP"   --from "$ADMIN"
expect_revert "setFeeRecipient(the oracle)"        BadParams "$VAULT" 'setFeeRecipient(address)' "$ORACLE" --from "$ADMIN"
if cast call "$VAULT" 'setFeeRecipient(address)' "$KEEPER" --from "$ADMIN" --rpc-url "$RPC" >/dev/null 2>&1; then
  pass "setFeeRecipient(an ordinary address) is accepted (control: the four above are refused for what they are)"
else
  fail "setFeeRecipient(an ordinary address) reverted: the four refusals above prove nothing"
fi
eq "vault.feeRecipient(), unchanged" "$(rd "$VAULT" 'feeRecipient()(address)')" "$ADMIN"

say "5. The Safe allowlists the keeper, and THEN, as its own step, opens deposits"
send "$VAULT" 'setKeeper(address,bool)' "$KEEPER" true --from "$ADMIN" --unlocked
eq "vault.keepers(keeper)" "$(rd "$VAULT" 'keepers(address)(bool)' "$KEEPER")" "true"
eq "depositsPaused after the handover and the keeper" "$(rd "$VAULT" 'depositsPaused()(bool)')" "true"
expect_revert "createPlan, still" Paused "$VAULT" "$PLAN_SIG" 1 100000000 10000000 86400 --from "$DEPOSITOR"
expect_revert "setDepositsPaused(false) from a stranger" NotOwner "$VAULT" 'setDepositsPaused(bool)' false --from "$DEPOSITOR"
send "$VAULT" 'setDepositsPaused(bool)' false --from "$ADMIN" --unlocked
eq "depositsPaused after the Safe's setDepositsPaused(false)" "$(rd "$VAULT" 'depositsPaused()(bool)')" "false"
eq "vault.setupFinished() (opening deposits does not reopen the window)" "$(rd "$VAULT" 'setupFinished()(bool)')" "true"
not_admin
OV_OPEN="$(ov_state)"   # the Safe is admin, deposits open, no plan yet

say "6. A deposit: 100 USDC from an impersonated holder, 10 USDC a day, route 1"
cast rpc anvil_impersonateAccount "$USDC_HOLDER" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$USDC_HOLDER" 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null
send "$USDC" 'transfer(address,uint256)' "$DEPOSITOR" 1000000000 --from "$USDC_HOLDER" --unlocked
cast rpc anvil_stopImpersonatingAccount "$USDC_HOLDER" --rpc-url "$RPC" >/dev/null
send "$USDC" 'approve(address,uint256)' "$VAULT" 100000000 --private-key "$DEPOSITOR_KEY"

# Round 6 (R5-5): the LAST period is held to the 1 USDC minimum too. A deposit
# that leaves a dust tail is refused before anything moves.
expect_revert "createPlan with a 2-wei last period (100.000002 USDC at 10 a day)" BadParams "$VAULT" "$PLAN_SIG" 1 100000002 10000000 86400 --from "$DEPOSITOR"
expect_revert "createPlan with a last period one wei under 1 USDC"               BadParams "$VAULT" "$PLAN_SIG" 1 100999999 10000000 86400 --from "$DEPOSITOR"

# Is anything fresh at the fork block, and if not, why not. Three answers, and
# the day of the week picks between them; none of them is a failure.
if [ "$(rd "$ORACLE" 'isFresh(address)(bool)' "$NVDAC")" = "true" ]; then
  note "the NVDA feed is FRESH at the fork block: createPlan's first buy will fire."
  OUT="$(cast call "$VAULT" "$PLAN_SIG" 1 100000000 10000000 86400 --from "$DEPOSITOR" --rpc-url "$RPC" 2>&1 || true)"
  if printf '%s' "$OUT" | grep -qi "revert"; then
    notrun "createPlan with a fresh feed reverts ON A FORK, as expected: the first buy calls the B20 0xef stub, which anvil cannot run. Covered by step 9."
  else
    fail "createPlan with a fresh feed did not revert on the fork. B20 may no longer be a stub: re-read Fork.t.sol's test_Fork_B20IsNativePrecompile."
  fi
elif [ "$(rd "$ORACLE" 'weekendClosed()(bool)')" = "true" ]; then
  note "nothing is fresh at the fork block: the oracle's WEEKEND RULE is closed (Sat 00:00 to Mon 01:00 UTC), whatever the feed's age. A plan opens with no first buy."
else
  note "the NVDA feed is not fresh at the fork block and it is not the weekend rule: its last print is past the 24 h heartbeat, or the sequencer check says no. A plan opens with no first buy."
fi
# Whichever it was, put the fork where the answer cannot change under the
# steps below. A feed that is only closed by the weekend rule turns fresh at
# Monday 01:00 UTC, and a run that started at 00:55 would find step 7's
# executeDCA no longer reverting StaleOracle. Past its heartbeat the fork's
# frozen feed is stale on any day of the week.
note "moving the fork's clock 25 h on, past the feed's 24 h heartbeat: from here on the feed is stale whatever the day."
cast rpc evm_increaseTime 90000 --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null
eq "oracle.isFresh(NVDAc)" "$(rd "$ORACLE" 'isFresh(address)(bool)' "$NVDAC")" "false"

send "$VAULT" "$PLAN_SIG" 1 100000000 10000000 86400 --private-key "$DEPOSITOR_KEY"
PLAN="$(rdall "$VAULT" 'plans(uint256)(address,uint32,uint256,uint256,uint256,uint64,uint64,uint32,bool)' 1)"
set -- $PLAN
eq "plan 1 owner" "$1" "$DEPOSITOR"
eq "plan 1 remainingPrincipal" "$4" "100000000"
eq "plan 1 active" "$9" "true"
SHARES="$5"
eq "MetaMorpho.balanceOf(yieldAdapter) = the plan's shares" "$(rd "$MORPHO_VAULT" 'balanceOf(address)(uint256)' "$YIELD")" "$SHARES"
WORTH="$(rd "$YIELD" 'assetsOf(uint256)(uint256)' "$SHARES")"
if [ "$WORTH" -ge 99999990 ] && [ "$WORTH" -le 100000010 ]; then pass "the shares are worth $WORTH of 100000000 (ERC-4626 rounds down)"; else fail "the shares are worth $WORTH, expected ~100000000"; fi
eq "vault holds no USDC" "$(rd "$USDC" 'balanceOf(address)(uint256)' "$VAULT")" "0"

say "7. Execute while the feed is frozen, then exit"
expect_revert "executeDCA as the owner"  StaleOracle "$VAULT" 'executeDCA(uint256)' 1 --from "$DEPOSITOR"
expect_revert "executeDCA as the keeper" StaleOracle "$VAULT" 'executeDCA(uint256)' 1 --from "$KEEPER"
expect_revert "exitPlan from a stranger" NotOwner    "$VAULT" 'exitPlan(uint256)' 1 --from "$KEEPER"
BEFORE="$(rd "$USDC" 'balanceOf(address)(uint256)' "$DEPOSITOR")"
send "$VAULT" 'exitPlan(uint256)' 1 --private-key "$DEPOSITOR_KEY"
BACK=$(( $(rd "$USDC" 'balanceOf(address)(uint256)' "$DEPOSITOR") - BEFORE ))
if [ "$BACK" -ge 99999990 ]; then pass "exitPlan returned $BACK of 100000000"; else fail "exitPlan returned $BACK of 100000000"; fi
eq "vault.totalPrincipal()"     "$(rd "$VAULT" 'totalPrincipal()(uint256)')" "0"
eq "vault.totalManagedShares()" "$(rd "$VAULT" 'totalManagedShares()(uint256)')" "0"

say "8. After launch every route change waits 48 hours: disable route $LAST, then re-enable it"
# Not a launch step: all four routes are listed by the deploy. This is the
# incident drill, and the only way a route is enabled from here on.
LT="$(route "$LAST" 2)"; LTOK="$(route "$LAST" 3)"; LPOOL="$(route "$LAST" 4)"; LFEED="$(route "$LAST" 5)"
as_admin
send "$VAULT" 'disableRoute(uint32)' "$LAST" --from "$ADMIN" --unlocked
eq "vault.routes($LAST) $LT after disableRoute (instant)" "$(rdall "$VAULT" "$ROUTE_SIG" "$LAST")" "$LTOK $LPOOL $LFEED 0 false"
expect_revert "createPlan on the disabled route" RouteDisabled "$VAULT" "$PLAN_SIG" "$LAST" 100000000 10000000 86400 --from "$DEPOSITOR"
send "$VAULT" "queueRoute$ROUTE_ARG" "$LAST" "($LTOK,$LPOOL,$LFEED,0,true)" --from "$ADMIN" --unlocked
expect_revert "activateRoute before 48 h" 'TimelockActive(uint64)' "$VAULT" 'activateRoute(uint32)' "$LAST" --from "$ADMIN"
cast rpc evm_increaseTime 172860 --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null
send "$VAULT" 'activateRoute(uint32)' "$LAST" --from "$ADMIN" --unlocked
eq "vault.routes($LAST) $LT after 48 h and activateRoute" "$(rdall "$VAULT" "$ROUTE_SIG" "$LAST")" "$LTOK $LPOOL $LFEED 0 true"
not_admin

# ------------------------------------------------ the leg a fork cannot run
say "9. The buys, simulated against the LIVE node (read-only eth_call, state override)"
# createPlan's first buy needs isFresh: a print inside the 24 h heartbeat AND a
# block outside the oracle's weekend closure (Sat 00:00 to Mon 01:00 UTC). So
# the block to simulate at is:
#   - the head, when it is outside the closure and the feed is young;
#   - otherwise about 2 minutes after the NVDA feed's last update;
#   - and if THAT is inside a closure too (the feed's last print of the week
#     can land at or after Saturday 00:00 UTC), one minute before the closure
#     began, where the print then in force was fresh.
ROUND="$(live call "$NVDAC_FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)"
set -- $ROUND
UPDATED="${4:-0}"
HEAD="$(live block-number 2>/dev/null || echo 0)"
HEAD_TS="$(live block "$HEAD" -f timestamp 2>/dev/null || echo 0)"
if [ "$UPDATED" = "0" ] || [ "$HEAD" = "0" ]; then
  notrun "could not read the live feed or head from $FORK_URL"
else
  eval "$(node -e '
    const [head, headTs, updated] = process.argv.slice(1).map(Number);
    const DAY = 86400, WEEK = 7 * DAY, LEN = 49 * 3600;
    const since = (t) => (t + 5 * DAY) % WEEK;   // seconds since Saturday 00:00 UTC
    const closed = (t) => since(t) < LEN;        // ChainlinkOracle.weekendClosed()
    const age = headTs - updated;
    let ts = headTs, why = `the live NVDA feed is ${age} s old and the weekend rule is open: simulating at the head`;
    if (closed(headTs) || age > 86000) {
      ts = updated + 120;
      why = (closed(headTs) ? "the live head is inside the weekend closure" : `the live NVDA feed is ${age} s old (frozen)`)
        + ": simulating about 2 minutes after the last update of the feed";
      if (closed(ts)) { ts = ts - since(ts) - 60; why += "; that is inside the weekend closure, so one minute before the closure began instead"; }
    }
    const at = head - Math.ceil((headTs - ts) / 2);   // Base blocks are 2 s
    console.log(`AT=${at} AT_WHY="${why}: block ${at}, about ${new Date(ts * 1000).toISOString()}"`);
  ' "$HEAD" "$HEAD_TS" "$UPDATED")"
  note "$AT_WHY"
  slot() { cast index address "$1" "$2"; }

  # THE WEEKEND RULE, JUDGED. closedOnWeekends() and weekendClosed() are read
  # in step 2, but an oracle whose isFresh ignored them would pass those rows.
  # So ask isFresh itself, on live state, one minute into the most recent
  # weekend closure and one minute before it. Inside, the feed's last print is
  # hours old, well within the 24 h heartbeat, so only the rule can make the
  # answer false. Just before it, the same print has to read fresh.
  eval "$(node -e '
    const [head, headTs] = process.argv.slice(1).map(Number);
    const DAY = 86400, WEEK = 7 * DAY;
    const sat = headTs - ((headTs + 5 * DAY) % WEEK);          // the most recent Saturday 00:00 UTC
    const blockAt = (ts) => head - Math.ceil((headTs - ts) / 2); // Base blocks are 2 s
    console.log(`WK_IN=${blockAt(sat + 60)} WK_OUT=${blockAt(sat - 60)} WK_SAT=${sat}`);
  ' "$HEAD" "$HEAD_TS")"
  WK_IN_TS="$(live block "$WK_IN" -f timestamp 2>/dev/null || echo 0)"
  WK_OUT_TS="$(live block "$WK_OUT" -f timestamp 2>/dev/null || echo 0)"
  WK_UPD="$(live call "$NVDAC_FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --block "$WK_IN" 2>/dev/null | awk 'NR==4{print $1}' || true)"
  IN_FRESH="$(live call "$ORACLE" 'isFresh(address)(bool)' "$NVDAC" --block "$WK_IN" --override-code "$OV_CODE" --override-state-diff "$OV_OPEN" 2>&1 || true)"
  IN_CLOSED="$(live call "$ORACLE" 'weekendClosed()(bool)' --block "$WK_IN" --override-code "$OV_CODE" --override-state-diff "$OV_OPEN" 2>&1 || true)"
  OUT_FRESH="$(live call "$ORACLE" 'isFresh(address)(bool)' "$NVDAC" --block "$WK_OUT" --override-code "$OV_CODE" --override-state-diff "$OV_OPEN" 2>&1 || true)"
  OUT_CLOSED="$(live call "$ORACLE" 'weekendClosed()(bool)' --block "$WK_OUT" --override-code "$OV_CODE" --override-state-diff "$OV_OPEN" 2>&1 || true)"
  if printf '%s' "$WK_UPD" | grep -q '^[0-9][0-9]*$' && [ "$WK_IN_TS" != "0" ] && [ "$WK_OUT_TS" != "0" ] \
     && printf '%s%s%s%s' "$IN_FRESH" "$IN_CLOSED" "$OUT_FRESH" "$OUT_CLOSED" | grep -Eq '^(true|false){4}$'; then
    WK_AGE=$(( WK_IN_TS - WK_UPD ))
    if [ "$WK_AGE" -lt 86400 ] && [ "$WK_IN_TS" -ge "$WK_SAT" ] && [ "$WK_OUT_TS" -lt "$WK_SAT" ]; then
      eq "oracle.weekendClosed() at $(utc "$WK_IN_TS"), inside the last closure (live state)" "$IN_CLOSED" "true"
      eq "oracle.isFresh(NVDAc) there, with a print only $WK_AGE s old: the weekend rule alone says no" "$IN_FRESH" "false"
      eq "oracle.weekendClosed() at $(utc "$WK_OUT_TS"), a minute before it" "$OUT_CLOSED" "false"
      eq "oracle.isFresh(NVDAc) there, against the same print" "$OUT_FRESH" "true"
    else
      notrun "the weekend rule on live state: the blocks picked do not straddle Saturday 00:00 UTC with a print inside the heartbeat (in $WK_IN_TS, out $WK_OUT_TS, print age $WK_AGE s)"
    fi
  else
    notrun "the weekend rule on live state: the RPC did not answer at blocks $WK_IN / $WK_OUT (historical state with a state override unsupported?): $(printf '%s' "$IN_FRESH" | head -1 | cut -c1-160)"
  fi
  USD_PROBE="$USDC:$(slot "$PROBE" 9):$(cast to-uint256 100000000),$USDC:$(slot "$VAULT" "$(slot "$PROBE" 10)"):$(cast to-uint256 100000000)"
  USD_VAULT="$USDC:$(slot "$VAULT" 9):$(cast to-uint256 10000000),$USDC:$(slot "$SWAP" "$(slot "$VAULT" 10)"):$(cast to-uint256 10000000)"

  # The posture, on real state: with the storage exactly as the deploy leaves
  # it, a deposit is refused.
  AS_DEPLOYED="$(live call "$VAULT" "$PLAN_SIG(uint256)" 1 100000000 10000000 86400 \
        --from "$PROBE" --block "$AT" --override-code "$OV_CODE" --override-state-diff "$OV_AS_DEPLOYED,$USD_PROBE" 2>&1 || true)"
  if printf '%s' "$AS_DEPLOYED" | grep -q -e "Paused" -e "$(cast sig 'Paused()')"; then
    pass "as deployed (deposits paused), createPlan on live state reverts Paused"
  elif printf '%s' "$AS_DEPLOYED" | grep -q '^[0-9]'; then
    fail "as deployed, createPlan on live state SUCCEEDED: the deploy does not leave deposits paused"
  else
    notrun "the live simulation did not answer (state override or historical state unsupported by this RPC?): $(printf '%s' "$AS_DEPLOYED" | head -1 | cut -c1-200)"
  fi

  # Then with the storage as the Safe leaves it after step 5, one deposit per
  # route. A returned plan id only proves a buy if the vault's own oracle
  # calls that route's feed fresh AT THAT BLOCK, so ask it first.
  while read -r id t tok pool feed <&3; do
    FRESH="$(live call "$ORACLE" 'isFresh(address)(bool)' "$tok" --block "$AT" --override-code "$OV_CODE" --override-state-diff "$OV_OPEN" 2>&1 || true)"
    if [ "$FRESH" != "true" ]; then
      notrun "$t: the oracle does not call its feed fresh at block $AT in the live simulation ($(printf '%s' "$FRESH" | head -1 | cut -c1-100)), so no buy would fire. Run again in market hours."
      continue
    fi
    PX="$(live call "$feed" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --block "$AT" 2>/dev/null | awk 'NR==2{print $1}' || true)"
    # (a) the whole deposit: USDC pull, Morpho supply, first buy, B20 to the owner.
    ID="$(live call "$VAULT" "$PLAN_SIG(uint256)" "$id" 100000000 10000000 86400 \
          --from "$PROBE" --block "$AT" --override-code "$OV_CODE" --override-state-diff "$OV_OPEN,$USD_PROBE" 2>&1 || true)"
    # (b) the swap adapter alone, as the vault, with no minOut: what the pool pays.
    OUT_RAW="$(live call "$SWAP" 'swapExactIn(address,address,uint256,uint256,address)(uint256)' "$pool" "$tok" 10000000 0 "$PROBE" \
          --from "$VAULT" --block "$AT" --override-code "$OV_CODE" --override-state-diff "$USD_VAULT" 2>&1 || true)"
    OUT="$(printf '%s' "$OUT_RAW" | awk 'NR==1{print $1}')"
    if [ "$ID" = "1" ] && printf '%s' "$OUT" | grep -q '^[0-9][0-9]*$' && printf '%s' "$PX" | grep -q '^[0-9][0-9]*$'; then
      node -e '
        const [t, id, out, px] = [process.argv[1], process.argv[2], BigInt(process.argv[3]), BigInt(process.argv[4])];
        const minOut = (10000000n * 10n ** 10n * 9900n) / (px * 10000n);
        const paid = 10 / (Number(out) / 1e8), ref = Number(px) / 1e8, bps = (paid / ref - 1) * 1e4;
        if (out < minOut) { console.log(`  FAIL     ${t}: the pool paid ${out}, under the vault bound ${minOut}`); process.exit(1); }
        console.log(`  PASS     ${t}: createPlan(route ${id}, 100 USDC, 10 USDC/day) on live state returned plan id 1 - deposit, Morpho supply and the first buy executed`);
        console.log(`           10 USDC -> ${(Number(out) / 1e8).toFixed(8)} ${t} = $${paid.toFixed(4)} a share; feed $${ref.toFixed(2)} (${Math.abs(bps).toFixed(1)} bps ${bps >= 0 ? "over" : "under"}); vault minOut ${minOut}, got ${out}`);
      ' "$t" "$id" "$OUT" "$PX" || FAILS=$((FAILS + 1))
    elif printf '%s%s' "$ID" "$OUT_RAW" | grep -q -i -e "revert"; then
      fail "$t: the live simulation REVERTED. createPlan: $(printf '%s' "$ID" | head -1 | cut -c1-200) | swapExactIn: $(printf '%s' "$OUT_RAW" | head -1 | cut -c1-200)"
    else
      notrun "$t: the live simulation did not answer: $(printf '%s' "$ID" | head -1 | cut -c1-200)"
    fi
  done 3<<EOF
$ROUTES
EOF
fi

# ------------------------------------------------------------------- cost
say "10. Gas and cost of the deploy"
GP="$(live gas-price 2>/dev/null || echo 0)"
L1=0
for h in $(node -e 'for (const x of require("./" + process.argv[1]).receipts) console.log(x.transactionHash)' "$RUN"); do
  RAW="$(cast tx "$h" --raw --rpc-url "$RPC")"
  FEE="$(live call "$GPO" 'getL1Fee(bytes)(uint256)' "$RAW" 2>/dev/null | awk 'NR==1{print $1}' || echo 0)"
  L1="$(node -e 'console.log((BigInt(process.argv[1]) + BigInt(process.argv[2] || 0)).toString())' "$L1" "${FEE:-0}")"
done
node -e '
  const [gas, gp, l1, n] = process.argv.slice(1).map(BigInt);
  const l2 = gas * gp, eth = (w) => (Number(w) / 1e18).toFixed(9);
  console.log(`           ${n} transactions, ${gas} gas x ${Number(gp) / 1e9} gwei (cast gas-price, live) = ${eth(l2)} ETH`);
  console.log(`           + L1 data fee (GasPriceOracle.getL1Fee, live)                         = ${eth(l1)} ETH`);
  console.log(`           = ${eth(l2 + l1)} ETH. Each initRoute costs ~50k gas less on the real chain, where the B20 decimals() probe answers.`);
' "$GAS" "$GP" "$L1" "$NTX"

echo
if [ "$FAILS" -gt 0 ]; then echo "REHEARSAL FAILED: $FAILS check(s) failed, $NOTRUN not run."; exit 1; fi
if [ "$NOTRUN" -gt 0 ]; then echo "REHEARSAL PASSED, with $NOTRUN step(s) that cannot run on a fork or were not run: see NOT RUN above."
else echo "REHEARSAL PASSED."; fi
echo "Nothing was sent to a real chain. anvil pid $ANVIL_PID is stopped on exit; its log: $TMP/anvil.log"
