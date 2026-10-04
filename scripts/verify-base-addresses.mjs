#!/usr/bin/env node
/**
 * Re-verify packages/config/addresses.base.json against live Base mainnet.
 *
 *   node scripts/verify-base-addresses.mjs            # table, exit 1 on any MISMATCH
 *   BASE_RPC_URL=https://... node scripts/verify-base-addresses.mjs
 *
 * READ-ONLY: eth_chainId, eth_getCode, eth_call, eth_getBlockByNumber. It
 * holds no key and sends nothing.
 *
 * Why it exists: Deploy.s.sol hardcodes addresses from that file, the file says
 * "verified on 2026-09-21", and a wrong address there is a drained plan. This
 * is the pre-flight for the mainnet deploy: the same questions, asked again
 * on the day.
 *
 * What it checks
 *   core        USDC (symbol, decimals), Morpho Blue, Aave pool and aUSDC: code
 *               exists and the contracts name each other.
 *   yieldVault  ERC-4626, asset() is USDC, MORPHO() is the core Morpho Blue,
 *               totalAssets reported.
 *   routes      token code is EXACTLY the one-byte B20 stub 0xef and the node
 *               answers decimals() = 8; the pool pairs USDC with that token,
 *               tickSpacing and observationCardinality match, liquidity > 0;
 *               the feed is 8 decimals, its description names the stock, and
 *               its age is reported.
 *   script      contracts/script/Deploy.s.sol repeats the addresses instead of
 *               reading the file, so: every constant equals the file, every
 *               route is listed under the id the web app looks it up by (the
 *               file's order, from 1) with its own pool and feed, and the
 *               script still records setDepositsPaused(true) before the admin
 *               handover starts and ends with finishSetup(), so the deploy
 *               leaves deposits paused.
 *
 * A STALE FEED IS NOT A MISMATCH. B20 feeds are 24/5 and frozen over the
 * weekend, so `feed age` is reported as INFO with a note, never as a failure.
 * A feed older than MAX_FEED_AGE_DAYS (5) is a failure: that is not a weekend.
 */
import { readFileSync } from "node:fs";

const RPC = process.env.BASE_RPC_URL || "https://mainnet.base.org";
const PACE_MS = Number(process.env.VERIFY_PACE_MS ?? 250);
const HEARTBEAT = 86_400;
const MAX_FEED_AGE_DAYS = 5;
const B20_STUB = "0xef";

const cfg = JSON.parse(readFileSync(new URL("../packages/config/addresses.base.json", import.meta.url), "utf8"));
const deploySol = readFileSync(new URL("../contracts/script/Deploy.s.sol", import.meta.url), "utf8");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The public endpoint rate-limits hard: pace every call and back off on a 429. */
let id = 0;
async function rpc(method, params) {
  let last;
  for (let attempt = 0; attempt < 8; attempt++) {
    await sleep(PACE_MS + attempt * 1500);
    try {
      const res = await fetch(RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
      });
      if (res.status === 429) { last = "429 rate limited"; continue; }
      const j = await res.json();
      if (j.error) {
        // An execution revert is an ANSWER, not a transport failure: do not retry it.
        if (/revert|execution/i.test(j.error.message ?? "") || j.error.code === 3) {
          return { reverted: j.error.message ?? "reverted" };
        }
        last = j.error.message;
        continue;
      }
      return { result: j.result };
    } catch (e) {
      last = String(e?.message ?? e);
    }
  }
  throw new Error(`${method} failed after retries: ${last}`);
}

const call = async (to, data) => rpc("eth_call", [{ to, data }, "latest"]);
const code = async (a) => (await rpc("eth_getCode", [a, "latest"])).result;

// ---- minimal ABI decoding: static words, addresses, and one dynamic string.
const word = (hex, i) => hex.slice(2 + 64 * i, 2 + 64 * (i + 1));
const uint = (hex, i = 0) => BigInt("0x" + (word(hex, i) || "0"));
const int = (hex, i = 0) => BigInt.asIntN(256, uint(hex, i));
const addr = (hex, i = 0) => "0x" + word(hex, i).slice(24);
const str = (hex) => {
  const off = Number(uint(hex, 0)) / 32;
  const len = Number(uint(hex, off));
  return Buffer.from(hex.slice(2 + 64 * (off + 1), 2 + 64 * (off + 1) + len * 2), "hex").toString("utf8");
};
const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
const pad = (a) => a.slice(2).toLowerCase().padStart(64, "0");

const SEL = {
  symbol: "0x95d89b41", decimals: "0x313ce567", name: "0x06fdde03",
  asset: "0x38d52e0f", totalAssets: "0x01e1d114", MORPHO: "0x3acb5624",
  token0: "0x0dfe1681", token1: "0xd21220a7", tickSpacing: "0xd0c93a7c",
  liquidity: "0x1a686502", slot0: "0x3850c7bd", factory: "0xc45a0155",
  description: "0x7284e416", latestRoundData: "0xfeaf968c", owner: "0x8da5cb5b",
  UNDERLYING: "0xb16a19de", POOL: "0x7535d246", getReserveData: "0x35ea6a75",
  balanceOf: "0x70a08231",
};

const rows = [];
let mismatches = 0;
function row(field, expected, actual, ok) {
  // ok: true | false | null (INFO: reported, not judged)
  const verdict = ok === null ? "INFO" : ok ? "OK" : "MISMATCH";
  if (ok === false) mismatches++;
  rows.push([field, String(expected), String(actual), verdict]);
}
/** A read that must answer; a revert is recorded as the actual value. */
async function read(to, data, decode) {
  const r = await call(to, data);
  if (r.reverted !== undefined) return { ok: false, value: `reverted (${r.reverted})` };
  if (!r.result || r.result === "0x") return { ok: false, value: "empty return" };
  try { return { ok: true, value: decode(r.result), raw: r.result }; }
  catch (e) { return { ok: false, value: `undecodable (${e.message})` }; }
}
async function expectCode(field, a) {
  const c = await code(a);
  const bytes = (c.length - 2) / 2;
  row(`${field} code`, "> 0 bytes", `${bytes} bytes`, bytes > 0);
  return c;
}
async function expectEq(field, to, data, decode, expected, cmp = same) {
  const r = await read(to, data, decode);
  row(field, expected, r.value, r.ok && cmp(r.value, expected));
  return r;
}

// ------------------------------------------------------------------ chain
const chainId = Number(BigInt((await rpc("eth_chainId", [])).result));
row("chainId", cfg.chainId, chainId, chainId === cfg.chainId);
if (chainId !== cfg.chainId) {
  print();
  console.error(`\nThe RPC is chain ${chainId}, not ${cfg.chainId}. Nothing else was checked.`);
  process.exit(1);
}
const head = (await rpc("eth_getBlockByNumber", ["latest", false])).result;
const now = Number(BigInt(head.timestamp));
const headNo = Number(BigInt(head.number));

// ------------------------------------------------------------------- core
const { USDC, MorphoBlue, AaveV3Pool, AaveV3aUSDC } = cfg.core;

await expectCode("core.USDC", USDC.address);
await expectEq("core.USDC symbol()", USDC.address, SEL.symbol, str, "USDC", (a, b) => a === b);
await expectEq("core.USDC decimals()", USDC.address, SEL.decimals, (h) => Number(uint(h)), USDC.decimals, (a, b) => a === b);

await expectCode("core.MorphoBlue", MorphoBlue.address);
{
  const r = await read(MorphoBlue.address, SEL.owner, addr);
  row("core.MorphoBlue owner()", "answers, non-zero", r.value, r.ok && BigInt(r.value) !== 0n);
}

await expectCode("core.AaveV3Pool", AaveV3Pool.address);
// ReserveDataLegacy: aTokenAddress is the 9th word.
await expectEq("core.AaveV3Pool getReserveData(USDC).aToken", AaveV3Pool.address,
  SEL.getReserveData + pad(USDC.address), (h) => addr(h, 8), AaveV3aUSDC.address);

await expectCode("core.AaveV3aUSDC", AaveV3aUSDC.address);
{
  const r = await read(AaveV3aUSDC.address, SEL.symbol, str);
  row("core.AaveV3aUSDC symbol()", "an aUSDC symbol", r.value, r.ok && /usdc/i.test(r.value));
}
await expectEq("core.AaveV3aUSDC decimals()", AaveV3aUSDC.address, SEL.decimals, (h) => Number(uint(h)), AaveV3aUSDC.decimals, (a, b) => a === b);
await expectEq("core.AaveV3aUSDC UNDERLYING_ASSET_ADDRESS()", AaveV3aUSDC.address, SEL.UNDERLYING, addr, USDC.address);
await expectEq("core.AaveV3aUSDC POOL()", AaveV3aUSDC.address, SEL.POOL, addr, AaveV3Pool.address);

// -------------------------------------------------------------- yieldVault
const yv = cfg.yieldVault;
await expectCode("yieldVault", yv.address);
await expectEq("yieldVault name()", yv.address, SEL.name, str, yv.name, (a, b) => a === b);
await expectEq("yieldVault asset()", yv.address, SEL.asset, addr, USDC.address);
await expectEq("yieldVault MORPHO()", yv.address, SEL.MORPHO, addr, MorphoBlue.address);
{
  const r = await read(yv.address, SEL.totalAssets, (h) => uint(h));
  const usd = r.ok ? Number(r.value) / 1e6 : 0;
  // Fork.t.sol's own floor: under $1M means the address is wrong or the vault has emptied.
  row("yieldVault totalAssets()", `> $1,000,000 (file says $${yv.tvlUsd.toLocaleString("en-US")})`,
    r.ok ? `$${usd.toLocaleString("en-US", { maximumFractionDigits: 0 })} (${r.value} raw)` : r.value, r.ok && usd > 1_000_000);
}

// ------------------------------------------------------------------ routes
for (const rt of cfg.routes) {
  const t = rt.ticker;
  const stock = t.replace(/c$/, ""); // NVDAc -> NVDA

  const tokenCode = await code(rt.token);
  row(`${t} token code`, `exactly ${B20_STUB} (B20 stub)`, tokenCode.length > 42 ? `${(tokenCode.length - 2) / 2} bytes` : tokenCode, tokenCode === B20_STUB);
  await expectEq(`${t} token decimals()`, rt.token, SEL.decimals, (h) => Number(uint(h)), rt.decimals, (a, b) => a === b);
  await expectEq(`${t} token symbol()`, rt.token, SEL.symbol, str, t, (a, b) => a === b);

  await expectCode(`${t} pool`, rt.pool);
  const t0 = await read(rt.pool, SEL.token0, addr);
  const t1 = await read(rt.pool, SEL.token1, addr);
  const pairOk = t0.ok && t1.ok &&
    ((same(t0.value, USDC.address) && same(t1.value, rt.token)) || (same(t1.value, USDC.address) && same(t0.value, rt.token)));
  row(`${t} pool token0/token1`, "USDC and the token, either order", `${t0.value} / ${t1.value}`, pairOk);
  await expectEq(`${t} pool tickSpacing()`, rt.pool, SEL.tickSpacing, (h) => Number(int(h)), rt.tickSpacing, (a, b) => a === b);
  {
    const r = await read(rt.pool, SEL.liquidity, (h) => uint(h));
    row(`${t} pool liquidity()`, "> 0", r.value, r.ok && r.value > 0n);
  }
  const s0 = await read(rt.pool, SEL.slot0, (h) => ({ sqrtP: uint(h, 0), tick: Number(int(h, 1)), card: Number(uint(h, 3)), unlocked: uint(h, 5) === 1n }));
  row(`${t} pool slot0().observationCardinality`, rt.observationCardinality, s0.ok ? s0.value.card : s0.value, s0.ok && s0.value.card === rt.observationCardinality);
  {
    const r = await read(rt.pool, SEL.factory, addr);
    row(`${t} pool factory()`, "reported", r.value, null);
  }

  await expectCode(`${t} feed`, rt.feed);
  await expectEq(`${t} feed decimals()`, rt.feed, SEL.decimals, (h) => Number(uint(h)), rt.feedDecimals, (a, b) => a === b);
  {
    const r = await read(rt.feed, SEL.description, str);
    row(`${t} feed description()`, `names ${stock}`, r.value, r.ok && new RegExp(`\\b${stock}\\b`, "i").test(r.value));
  }
  const rd = await read(rt.feed, SEL.latestRoundData, (h) => ({ roundId: uint(h, 0), answer: int(h, 1), updatedAt: Number(uint(h, 3)), answeredIn: uint(h, 4) }));
  if (!rd.ok) {
    row(`${t} feed latestRoundData()`, "answers", rd.value, false);
    continue;
  }
  const px = Number(rd.value.answer) / 1e8;
  row(`${t} feed answer`, "> 0", `$${px.toFixed(2)}`, rd.value.answer > 0n);
  const age = now - rd.value.updatedAt;
  const fresh = age >= 0 && age <= HEARTBEAT;
  const note = fresh
    ? "fresh: the vault would buy"
    : "STALE for the vault (isFresh=false): deposits open a plan with no first buy, executions revert StaleOracle. Expected Fri close to Mon open";
  row(`${t} feed age (s)`, `<= ${HEARTBEAT} to be fresh; <= ${MAX_FEED_AGE_DAYS}d to be alive`,
    `${age} s (${(age / 3600).toFixed(1)} h), updatedAt ${new Date(rd.value.updatedAt * 1000).toISOString()} - ${note}`,
    age >= 0 && age <= MAX_FEED_AGE_DAYS * 86_400 ? null : false);

  // Pool spot vs feed, the same decoding AerodromeSwapAdapter.poolPrice uses.
  if (s0.ok && t0.ok && s0.value.sqrtP > 0n) {
    const ratioX128 = (s0.value.sqrtP * s0.value.sqrtP) >> 64n;
    const usdcIsToken0 = same(t0.value, USDC.address);
    const pool8 = usdcIsToken0 ? ((1n << 128n) * 10n ** 10n) / ratioX128 : (ratioX128 * 10n ** 10n) >> 128n;
    const ref8 = rd.value.answer;
    const diff = pool8 > ref8 ? pool8 - ref8 : ref8 - pool8;
    const bps = Number((diff * 100_000n) / ref8) / 10;
    // The vault's circuit breaker is 500 bps and its fill bound 100 bps. Over a
    // weekend the pool drifts off a frozen feed, so this is INFO unless absurd.
    row(`${t} pool spot vs feed`, "< 2000 bps (decoding sanity; breaker is 500, fill bound 100)",
      `$${(Number(pool8) / 1e8).toFixed(2)} vs $${px.toFixed(2)} = ${bps.toFixed(1)} bps${pool8 > ref8 ? " over" : " under"}`, bps < 2000 ? null : false);
  }

  // What the pool holds, in dollars, next to what the file recorded. INFO: it
  // moves every block; a pool that has emptied is what this is here to show.
  {
    const u = await read(USDC.address, SEL.balanceOf + pad(rt.pool), (h) => uint(h));
    const s = await read(rt.token, SEL.balanceOf + pad(rt.pool), (h) => uint(h));
    if (u.ok && s.ok) {
      const usd = Number(u.value) / 1e6 + (Number(s.value) / 10 ** rt.decimals) * px;
      const was = rt.poolLiquidityUsd;
      row(`${t} pool holdings`, `file says $${was.toLocaleString("en-US")}`,
        `$${usd.toLocaleString("en-US", { maximumFractionDigits: 0 })} (${(Number(u.value) / 1e6).toFixed(0)} USDC + ${(Number(s.value) / 10 ** rt.decimals).toFixed(2)} ${t}), ${((usd / was - 1) * 100).toFixed(0)}% vs file`,
        usd > 0 ? null : false);
    } else {
      row(`${t} pool holdings`, "balanceOf answers for both tokens", `${u.value} / ${s.value}`, false);
    }
  }
}

// ------------------------------------------------- Deploy.s.sol's constants
// The script does not read the JSON: it repeats the addresses. They must agree,
// for every route the file lists, and each must be listed under the id the web
// app will look it up by (the file's order, 1-based).
{
  const want = { USDC: USDC.address, MORPHO_VAULT: yv.address };
  for (const rt of cfg.routes) {
    const K = rt.ticker.toUpperCase(); // NVDAc -> NVDAC
    want[K] = rt.token;
    want[`${K}_POOL`] = rt.pool;
    want[`${K}_FEED`] = rt.feed;
  }
  for (const [name, expected] of Object.entries(want)) {
    const m = deploySol.match(new RegExp(`address constant ${name}\\s*=\\s*(0x[0-9a-fA-F]{40})`));
    row(`Deploy.s.sol ${name}`, expected, m ? m[1] : "not found", !!m && same(m[1], expected));
  }
  cfg.routes.forEach((rt, i) => {
    const K = rt.ticker.toUpperCase();
    // _list(vault, <id>, TOKEN, TOKEN_POOL, TOKEN_FEED) and oracle.setFeed(TOKEN, TOKEN_FEED)
    const listed = deploySol.match(new RegExp(`_list\\(\\s*vault\\s*,\\s*(\\d+)\\s*,\\s*${K}\\s*,\\s*(\\w+)\\s*,\\s*(\\w+)\\s*\\)`));
    const got = listed ? `id ${listed[1]}, ${listed[2]}, ${listed[3]}` : "not listed";
    row(`Deploy.s.sol lists ${rt.ticker}`, `id ${i + 1}, ${K}_POOL, ${K}_FEED`, got,
      !!listed && Number(listed[1]) === i + 1 && listed[2] === `${K}_POOL` && listed[3] === `${K}_FEED`);
    const fed = new RegExp(`oracle\\.setFeed\\(\\s*${K}\\s*,\\s*${K}_FEED\\s*\\)`).test(deploySol);
    row(`Deploy.s.sol oracle.setFeed(${K}, ${K}_FEED)`, "present", fed ? "present" : "missing", fed);
  });
  // The launch posture: the deploy must not open deposits. The pause has to
  // be recorded BEFORE the admin handover starts (a pause set during setup
  // survives finishSetup, whoever sends it), finishSetup() has to come after
  // the handover, and nothing in the script may lift the pause.
  const body = deploySol.replace(/\/\/.*$/gm, "");
  const iPause = body.indexOf("vault.setDepositsPaused(true);");
  const iHandover = body.indexOf("vault.transferAdmin(");
  const iFinish = body.indexOf("vault.finishSetup();");
  const pausedThenFinished = iPause >= 0 && iHandover > iPause && iFinish > iHandover
    && !body.includes("vault.setDepositsPaused(false)");
  row("Deploy.s.sol: setDepositsPaused(true), then transferAdmin, then finishSetup()", "in that order (deploy leaves deposits PAUSED)",
    pausedThenFinished ? "in that order" : "missing or out of order: this script could OPEN deposits", pausedThenFinished);
}

print();
console.log(`\nhead block ${headNo}, ${new Date(now * 1000).toISOString()} (${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][new Date(now * 1000).getUTCDay()]} UTC), rpc ${new URL(RPC).host}`);
console.log(`file says verifiedAt ${cfg.verifiedAt}`);
console.log(mismatches === 0 ? "ALL OK (INFO rows are reported, not judged)" : `${mismatches} MISMATCH - do not deploy`);
process.exit(mismatches === 0 ? 0 : 1);

function print() {
  const head = ["field", "expected", "actual", ""];
  const w = [0, 1, 2].map((i) => Math.min(i === 2 ? 200 : 62, Math.max(head[i].length, ...rows.map((r) => r[i].length))));
  const line = (r) => `${r[0].padEnd(w[0])} | ${r[1].padEnd(w[1])} | ${r[2].padEnd(w[2])} | ${r[3]}`;
  // Mismatches first, so a bad address is the first thing on the screen.
  const bad = rows.filter((r) => r[3] === "MISMATCH");
  if (bad.length) {
    console.log("MISMATCHES");
    for (const r of bad) console.log(line(r));
    console.log();
  }
  console.log(line(head));
  console.log(w.map((n) => "-".repeat(n)).join("-|-") + "-|---------");
  for (const r of rows) console.log(line(r));
}
