---
title: "DCA Vault Plugin"
description: "Start and stop scheduled tokenized-stock buys on DCA Vault — on-chain reads via chain_rpc_request and unsigned approve+createPlan to send_calls on Base Sepolia."
tags: [dca, vaults, yield, trading]
name: dca-vault
version: 0.1.0
integration: semantic-base-tool
chains: [base-sepolia]
requires:
  shell: none
  allowlist: []
  externalMcp: null
  cliPackage: null
auth: none
risk: [irreversible]
---

# DCA Vault Plugin

> [!IMPORTANT]
> Run Wallet MCP onboarding first (see SKILL.md). The user's wallet address — needed for every write and to read their plans — is fetched lazily via `get_wallets` when a flow needs it. This plugin is **100% on-chain**: it makes no HTTP calls and needs no allowlist.

## Overview

DCA Vault buys a tokenized stock on a schedule from one USDC deposit; the USDC still waiting is lent on Morpho and earns interest, and the stock bought is sent straight to the owner's wallet — the vault never holds it. This plugin reads the vault with `chain_rpc_request` (`eth_call`) and builds **unsigned calldata** from the baked-in [registry](#registry), submitted via Wallet MCP `send_calls`. No external service, no CLI, no allowlist.

This file targets the **Base Sepolia demo** (`base-sepolia`): the stock tokens and prices are demo tokens, not real B20, and the USDC is a faucet token with a public `drip()`. The demo vault runs an earlier revision of the contracts in this repository; the README says what differs. Mainnet (`base`) is not deployed yet; when it is, its addresses go in [Notes](#notes) and `base` is added to `chains`.

## Surface Routing

Everything routes through Wallet MCP's own on-chain tools, so the plugin behaves the same on every surface (Claude Code, Cursor, Codex, Claude.ai, ChatGPT). No shell, no allowlist.

| Capability | Path | Surface notes |
| - | - | - |
| List stocks, prices, deposits-paused | `chain_rpc_request` (`eth_call`) | Works everywhere. |
| Read the user's plans | `chain_rpc_request` (`eth_call`) | Works everywhere; block-fresh. |
| Start a plan | `chain_rpc_request` (reads) → `send_calls` (write) | Works everywhere. Base Sepolia only. |
| Stop a plan | `chain_rpc_request` (read) → `send_calls` (write) | Works everywhere. |

Operate only on `base-sepolia`. Always pass the chain **name** (`base-sepolia`), never the numeric id.

## Orchestration

All reads are `chain_rpc_request{ chain: "base-sepolia", method: "eth_call", params: [{ to, data }, "latest"] }`. Encode calldata as the 4-byte selector then each argument left-padded to a 32-byte word (`pad32`): a `uint` is its big-endian hex; an `address` is its 20 bytes left-padded to 32. See [Encoding](#encoding).

### Stocks and prices

The stocks are the baked-in [registry](#registry). For each, read the vault's oracle:

```
price     eth_call to=ORACLE data = 0x53084eff + pad32(token)  → (uint256 price, uint256 updatedAt); USD = price / 1e8
isFresh   eth_call to=ORACLE data = 0x34002f04 + pad32(token)  → bool; false means a first buy waits for the next price
paused    eth_call to=VAULT  data = 0x60da3e83                 → bool; if true, do not try to start a plan
```

### Read the user's plans

```
1. get_wallets → user
2. nextPlanId   eth_call to=VAULT data = 0x5f8d26b2 → N. Plan ids are 1 … N-1.
3. For each id, plans(id)  eth_call to=VAULT data = 0xb1620616 + pad32(id)
   → words: [0] owner (last 20 bytes), [1] routeId, [2] installment, [3] remainingPrincipal,
            [5] nextExecution, [6] interval, [8] active (1/0)
   Keep the ones whose owner == user. installment and remainingPrincipal are USDC (÷ 1e6);
   interval ÷ 86400 = days between buys; active=1 is running.
```

### Start a plan

The person says an amount, a stock, how often, and over how long. Work out the plan **exactly as the vault will**:

```
stepDays = everyN  × { day:1, week:7, month:30 }[everyUnit]
spanDays = overN   × { days:1, months:30, years:365 }[overUnit]
buys     = max(1, floor(spanDays / stepDays))
deposit  = round(amountUSDC × 1e6)                      (integer, USDC has 6 decimals)
installment = ceil(deposit / buys) = (deposit + buys - 1) \ buys   (integer division)
interval = stepDays × 86400
routeId  = the stock's id from the registry
```

**Refuse before sending** what the vault would revert (`BadParams`): `buys > 120`, `stepDays > 366`, or any buy under 1 USDC (`installment < 1000000`). Say which rule it is; do not reshape the plan unless the person asks.

Then, demo-only: if the user's USDC balance is 0, prepend a faucet drip.

```
balanceOf(user)  eth_call to=USDC data = 0x70a08231 + pad32(user)  → USDC ÷ 1e6
drip (demo USDC) data = 0x9f678cca    (no args; gives 1000 test USDC, once per 4h)
```

Build the batch and submit it (see [Submission](#submission)). After `get_request_status` confirms, read it back: `nextPlanId` → the new id is `N-1`; `plans(N-1)` should show `owner == user` and `active == 1`.

### Stop a plan

```
1. get_wallets → user
2. plans(id) → confirm owner == user and active == 1 (only the owner can stop it; the contract refuses otherwise)
3. send_calls with exitPlan(id). The USDC not yet spent returns to the wallet; stock already bought stays in it.
4. get_request_status → confirmed; plans(id).active should be 0.
```

## Submission

Target tool: **`send_calls`** (an EIP-5792 batch of unsigned `{ to, value, data }` calls). The plugin produces raw calldata; there is no semantic `swap`/`send` and no external service. Reads use `chain_rpc_request` and never touch `send_calls`.

Mapping into `send_calls`:

* **`chain`** — always `"base-sepolia"`.
* **`calls[]`**, ordered, **approval before the action**:
  * start → `[ (drip if balance 0,) approve(VAULT, deposit), createPlan(routeId, deposit, installment, interval) ]`
  * stop → `[ exitPlan(id) ]`
  * each call: `to` = the contract, `value` = `"0x0"`, `data` = selector + `pad32` args.

```
approve      to=USDC  data = 0x095ea7b3 + pad32(VAULT) + pad32(deposit)
createPlan   to=VAULT data = 0x714a0657 + pad32(routeId) + pad32(deposit) + pad32(installment) + pad32(interval)
exitPlan     to=VAULT data = 0xe86dbeb3 + pad32(id)
```

The approval is for **exactly the deposit**, never unlimited. After submission, poll `get_request_status(requestId)`; see `../references/approval-mode.md` for the approval URL flow and `../references/batch-calls.md` for batching.

## Example Prompts

**"What can I buy on DCA Vault, and at what price?"**

1. Read the [registry](#registry).
2. For each stock: `latestPrice` and `isFresh` on the oracle; `depositsPaused` on the vault.
3. List the stocks, their USD price, and note any whose first buy would wait.

**"Put 600 USDC into NVIDIA, weekly, for 3 months."**

1. `get_wallets` → user. Resolve NVDAc → routeId 1.
2. stepDays 7, spanDays 90 → buys 12; deposit 600000000; installment 50000000; interval 604800. Under all caps.
3. `balanceOf(user)`; if 0, prepend `drip`.
4. `send_calls(chain="base-sepolia", calls=[ approve(VAULT, 600000000), createPlan(1, 600000000, 50000000, 604800) ])`.
5. `get_request_status` → confirmed. `nextPlanId`, then `plans(N-1)` → report the new plan.

**"Buy NVIDIA every day for a year."**

1. stepDays 1, spanDays 365 → buys 365. Over the 120-buy cap.
2. Refuse: that is 365 buys, and a plan can have at most 120. Do not reshape it unless asked.

**"Stop my plan 3."**

1. `get_wallets` → user. `plans(3)` → confirm owner == user and active == 1.
2. `send_calls(chain="base-sepolia", calls=[ exitPlan(3) ])`.
3. `get_request_status` → confirmed. `plans(3).active` should be 0; the waiting USDC is back.

## Risks & Warnings

* **irreversible** — `send_calls` writes are on-chain and cannot be undone. Show the plan (stock, deposit, buys, each size, interval) and let the user review it in Coinbase Wallet's approval before they sign. The approval is for exactly the deposit, never unlimited; if the wallet shows a different amount or address, tell the user to reject it.

The vault's rules are enforced by the contract whoever signs: a plan over the caps reverts, and only a plan's owner can stop it. These tokens are Reg S and **not offered to US persons**; this is a testnet demo of that product. On mainnet no buy runs from Saturday 00:00 to Monday 01:00 UTC.

## Notes

### Registry

Base Sepolia (chain id 84532), verified against the deployed demo on 2026-10-12. The vault is the one the README links on the explorer.

| What | Address |
| - | - |
| Vault | `0x5713Ff26225F6127FF98747087607D483d0DFE68` |
| USDC (demo, has `drip()`) | `0x0122C1B9bf7195f9A832316011dfd683d7a90EF5` |
| Oracle | `0x60fd8F9672529E91cD4265cae1Ff5a49520B8529` |

| Stock | routeId | Token |
| - | - | - |
| NVDAc (NVIDIA) | 1 | `0x9bF3F751eF41426dCE35C58549C02EF4A329D66C` |
| GOOGLc (Alphabet) | 2 | `0x06E3de5F5d59C401Cd93378E402B3d6b7a5212Bf` |
| AAPLc (Apple) | 3 | `0xED4064b1F18Ff951eAaabeA1FadEfb0Eef4126E9` |
| METAc (Meta) | 4 | `0xB58cceBf978C76De1c1Bde2415288242ecCAF657` |

### Selectors

| Function | Selector |
| - | - |
| `createPlan(uint32,uint256,uint256,uint64)` | `0x714a0657` |
| `exitPlan(uint256)` | `0xe86dbeb3` |
| `plans(uint256)` | `0xb1620616` |
| `nextPlanId()` | `0x5f8d26b2` |
| `depositsPaused()` | `0x60da3e83` |
| `latestPrice(address)` (oracle) | `0x53084eff` |
| `isFresh(address)` (oracle) | `0x34002f04` |
| `approve(address,uint256)` (USDC) | `0x095ea7b3` |
| `drip()` (demo USDC) | `0x9f678cca` |
| `balanceOf(address)` | `0x70a08231` |

### Encoding

`pad32(x)` is `x` as big-endian hex with no `0x`, left-padded with `0` to 64 characters. A `uint` is its hex (e.g. `600000000` → `...23c34600`); an `address` is its 40 hex characters left-padded to 64. Concatenate the selector and the padded words, prefix `0x`. Example — `approve(VAULT, 600000000)`:

```
0x095ea7b3
  0000000000000000000000005713ff26225f6127ff98747087607d483d0dfe68
  0000000000000000000000000000000000000000000000000000000023c34600
```

### Mainnet

When the vault is on Base mainnet (`base`), add a Base registry here from `packages/config/addresses.base.json` (there USDC is real Coinbase USDC with no `drip()`, and the stocks are the ten real B20 tokens), add `base` to `chains`, and drop the faucet step. The reads, the calldata and the caps are the same.

### Not affiliated

This plugin is maintained with DCA Vault, not by Base. The `base/skills` repo does not take outside plugins today, so use it as a custom plugin (point your Wallet MCP at this file) until listing opens.
