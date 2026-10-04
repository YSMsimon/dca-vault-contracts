#!/usr/bin/env node
/**
 * Print the `"deployment"` object for packages/config/addresses.base.json.
 *
 *   node scripts/print-base-deployment.mjs --keeper 0xKEEPER
 *   node scripts/print-base-deployment.mjs --keeper 0xKEEPER --run contracts/broadcast/Deploy.s.sol/8453/run-latest.json
 *
 * It PRINTS; it edits nothing. The web app (not in this repository) is in
 * pre-launch mode while that key is `null` and turns on when it is filled
 * in, so the paste is a deliberate human step.
 *
 * THE SITE AND THE VAULT OPEN SEPARATELY. Deploy.s.sol leaves deposits
 * PAUSED. Pasting this object turns the site on; it does not open the vault.
 * The Safe does that later with setDepositsPaused(false), and this script
 * says which state the vault is in.
 *
 * READ-ONLY. It reads the broadcast file forge wrote, then asks the chain
 * (BASE_RPC_URL, default https://mainnet.base.org) and Sourcify to confirm
 * every field instead of trusting the file:
 *
 *   vault, oracle, yieldAdapter, swapAdapter
 *       the CREATE transactions in the broadcast, and each address must hold
 *       code on the chain RIGHT NOW. A broadcast from a fork rehearsal has
 *       addresses that exist nowhere; pasting those ships an app pointed at
 *       nothing. Refused.
 *   deployBlock
 *       the block of the vault's creation transaction, from the chain's own
 *       receipt, not from the script's simulation-time block.number.
 *   routeIds
 *       read from the vault: routes(1..MAX_ROUTE_ID), kept when enabled and
 *       when the token is one addresses.base.json lists. Deploy.s.sol lists
 *       all four in the deploy itself, so straight after it this is
 *       {"NVDAc":1,"GOOGLc":2,"AAPLc":3,"METAc":4}. A route that is missing
 *       or disabled is named, and left out.
 *   keeper
 *       the address you pass. Warned about (not refused) when the vault does
 *       not have it allowlisted yet.
 *   verified
 *       "sourcify" only if Sourcify holds a match for all four contracts.
 *       Otherwise the key is left out.
 *
 * ON A LOCAL FORK (the RPC answers anvil_nodeInfo) it runs as a rehearsal:
 * any chain id is accepted, Sourcify is not asked, and the line it prints is
 * prefixed "REHEARSAL ONLY, DO NOT PASTE:". scripts/rehearse-mainnet.sh uses
 * that to check the object the real run will produce. On a real node the
 * chain must be 8453.
 */
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};
const RUN = opt("run", "contracts/broadcast/Deploy.s.sol/8453/run-latest.json");
const KEEPER = opt("keeper", process.env.KEEPER_ADDRESS);
const RPC = process.env.BASE_RPC_URL || "https://mainnet.base.org";
const CHAIN_ID = 8453;
const MAX_ROUTE_ID = 16;

const die = (msg) => { console.error(`\n${msg}`); process.exit(1); };
if (!KEEPER || !/^0x[0-9a-fA-F]{40}$/.test(KEEPER)) {
  die("usage: print-base-deployment.mjs --keeper 0x<address the keeper bot signs as> [--run <run-latest.json>]");
}

const cfg = JSON.parse(readFileSync(new URL("../packages/config/addresses.base.json", import.meta.url), "utf8"));
let run;
try { run = JSON.parse(readFileSync(RUN, "utf8")); }
catch { die(`Cannot read ${RUN}. Run this from the repo root after the broadcast, or pass --run.`); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let id = 0;
async function rpc(method, params) {
  let last;
  for (let attempt = 0; attempt < 8; attempt++) {
    await sleep(250 + attempt * 1500);
    try {
      const res = await fetch(RPC, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
      });
      if (res.status === 429) { last = "429 rate limited"; continue; }
      const j = await res.json();
      if (j.error) { last = j.error.message; if (j.error.code === -32601) break; continue; }
      return j.result;
    } catch (e) { last = String(e?.message ?? e); }
  }
  throw new Error(`${method}: ${last}`);
}
const call = (to, data) => rpc("eth_call", [{ to, data }, "latest"]);
const word = (hex, i) => hex.slice(2 + 64 * i, 2 + 64 * (i + 1));
const addrOf = (hex, i = 0) => "0x" + word(hex, i).slice(24);
const pad = (a) => a.slice(2).toLowerCase().padStart(64, "0");
const same = (a, b) => a.toLowerCase() === b.toLowerCase();

/**
 * EIP-55, via cast: node has SHA3-256 but not Keccak-256. `cast` on PATH
 * first, then foundryup's default location. Falls back to the input.
 */
function checksum(a) {
  for (const cast of ["cast", `${process.env.HOME}/.foundry/bin/cast`]) {
    try {
      return execFileSync(cast, ["to-check-sum-address", a], { stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
    } catch { /* not there: try the next one */ }
  }
  return a;
}

// ---- 1. the four contracts, from the broadcast
const created = (name) => {
  const t = run.transactions.find((x) => x.transactionType === "CREATE" && x.contractName === name);
  if (!t) die(`${RUN} has no CREATE of ${name}. Is this a Deploy.s.sol broadcast?`);
  return { address: t.contractAddress, hash: t.hash };
};
const vault = created("DcaVault");
const parts = {
  vault: vault.address,
  oracle: created("ChainlinkOracle").address,
  yieldAdapter: created("MorphoAdapter").address,
  swapAdapter: created("AerodromeSwapAdapter").address,
};

// ---- 2. the chain has to agree
const chainId = Number(BigInt(await rpc("eth_chainId", [])));
// anvil_nodeInfo is a method no real node has. Only a local fork may be any
// chain other than Base, and what is printed for it cannot be pasted as is.
let rehearsal = false;
try { await rpc("anvil_nodeInfo", []); rehearsal = true; } catch { /* a real node: good */ }
if (chainId !== CHAIN_ID && !rehearsal) die(`The RPC is chain ${chainId}, not ${CHAIN_ID}.`);
if (Number(run.chain) !== chainId) {
  die(`${RUN} is a broadcast to chain ${run.chain}, but the RPC is chain ${chainId}. Nothing printed.`);
}

for (const [k, a] of Object.entries(parts)) {
  const c = await rpc("eth_getCode", [a, "latest"]);
  if (!c || c === "0x") {
    die(`${k} ${a} has NO CODE on chain ${chainId} via ${new URL(RPC).host}.\n` +
      `That broadcast did not land on this chain - it is a fork rehearsal's, or the deploy failed part-way. Nothing printed.`);
  }
}
const receipt = await rpc("eth_getTransactionReceipt", [vault.hash]);
if (!receipt) die(`No receipt on chain for the vault's creation tx ${vault.hash}. Nothing printed.`);
if (receipt.status !== "0x1") die(`The vault's creation tx ${vault.hash} reverted. Nothing printed.`);
if (!same(receipt.contractAddress, parts.vault)) die("The receipt's contractAddress is not the broadcast's vault. Nothing printed.");
const deployBlock = Number(BigInt(receipt.blockNumber));

// The vault has to be wired to the other three: these are immutables.
for (const [k, sel] of [["oracle", "0x7dc0d1d0"], ["yieldAdapter", "0x03eadcfc"], ["swapAdapter", "0x2b3297f9"]]) {
  // oracle() / adapter() / swapper()
  const got = addrOf(await call(parts.vault, sel));
  if (!same(got, parts[k])) die(`vault.${k} is ${got}, the broadcast says ${parts[k]}. Nothing printed.`);
}

// ---- 3. route ids, as the vault holds them now
const byToken = new Map(cfg.routes.map((r) => [r.token.toLowerCase(), r.ticker]));
const routeIds = {};
for (let i = 1; i <= MAX_ROUTE_ID; i++) {
  const r = await call(parts.vault, "0x263af8e8" + i.toString(16).padStart(64, "0")); // routes(uint32)
  const token = addrOf(r, 0);
  const enabled = BigInt("0x" + word(r, 4)) === 1n;
  if (BigInt(token) === 0n) continue;
  const ticker = byToken.get(token.toLowerCase());
  if (!ticker) { console.error(`  ! route ${i} is token ${token}, which addresses.base.json does not list - left out`); continue; }
  if (!enabled) { console.error(`  ! route ${i} (${ticker}) is disabled - left out`); continue; }
  if (routeIds[ticker]) { console.error(`  ! ${ticker} is on routes ${routeIds[ticker]} and ${i} - keeping ${routeIds[ticker]}`); continue; }
  routeIds[ticker] = i;
}
if (Object.keys(routeIds).length === 0) die("The vault has no enabled route. Nothing printed.");
const missing = cfg.routes.map((r) => r.ticker).filter((t) => !routeIds[t]);

// ---- 4. keeper, admin, switches: context for the human, on stderr
const keeperOk = BigInt(await call(parts.vault, "0x3bbd64bc" + pad(KEEPER))) === 1n; // keepers(address)
const admin = addrOf(await call(parts.vault, "0xf851a440"));
const pending = addrOf(await call(parts.vault, "0x26782247"));
const oracleAdmin = addrOf(await call(parts.oracle, "0xf851a440"));
const oraclePending = addrOf(await call(parts.oracle, "0x26782247"));
const setupFinished = BigInt(await call(parts.vault, "0x10e506a0")) === 1n;
const depositsPaused = BigInt(await call(parts.vault, "0x60da3e83")) === 1n;

// ---- 5. Sourcify
let verified = 0;
for (const a of rehearsal ? [] : Object.values(parts)) {
  try {
    const j = await (await fetch(`https://sourcify.dev/server/v2/contract/${CHAIN_ID}/${a}`)).json();
    if (j.match === "exact_match" || j.match === "match") verified++;
  } catch { /* counted as not verified */ }
}

const deployment = {
  vault: checksum(parts.vault),
  oracle: checksum(parts.oracle),
  yieldAdapter: checksum(parts.yieldAdapter),
  swapAdapter: checksum(parts.swapAdapter),
  keeper: checksum(KEEPER),
  deployBlock,
  routeIds,
  ...(verified === 4 ? { verified: "sourcify" } : {}),
};

const note = (s) => console.error(s);
note("");
if (rehearsal) note("  !! THIS RPC IS ANVIL. These addresses exist on a local fork only. DO NOT PASTE THIS.");
note(`  chain ${chainId} via ${new URL(RPC).host}, vault created in block ${deployBlock}`);
note(`  vault admin ${checksum(admin)}${BigInt(pending) !== 0n ? `  (pending: ${checksum(pending)} has NOT accepted yet)` : ""}`);
note(`  oracle admin ${checksum(oracleAdmin)}${BigInt(oraclePending) !== 0n ? `  (pending: ${checksum(oraclePending)} has NOT accepted yet)` : ""}`);
note(`  setupFinished ${setupFinished}, depositsPaused ${depositsPaused}`);
if (!setupFinished) note("  ! the setup window is still OPEN: finishSetup() has not landed. The deploy did not finish.");
note(depositsPaused
  ? "  deposits are PAUSED, as the deploy leaves them. Pasting this turns the SITE on; the vault stays shut until the Safe sends setDepositsPaused(false)."
  : "  deposits are OPEN: createPlan takes money now.");
if (!keeperOk) note(`  ! ${checksum(KEEPER)} is NOT allowlisted: keepers(keeper) is false. setKeeper(keeper, true) from the admin first.`);
if (missing.length) note(`  ! NOT enabled on the vault: ${missing.join(", ")}. The deploy lists all four; the site would offer a route that reverts. Find out why before pasting.`);
if (rehearsal) note("  (a fork: Sourcify not asked, so \"verified\" is left out)");
else if (verified !== 4) note(`  ! Sourcify holds ${verified}/4 of these contracts, so "verified" is left out. Verify them there (forge verify-contract --verifier sourcify), then run this again.`);
note(`\n  Replace  "deployment": null  in packages/config/addresses.base.json with:\n`);

console.log(`${rehearsal ? "REHEARSAL ONLY, DO NOT PASTE: " : ""}"deployment": ${JSON.stringify(deployment)}`);
