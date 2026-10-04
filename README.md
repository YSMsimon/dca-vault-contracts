# DCA Vault contracts

Deposit USDC once, and the vault buys a tokenised stock for you on a schedule.
The part that has not been spent yet is lent out, and the interest it earns
buys more of the same stock.

**Status: not deployed on Base mainnet, and not audited by anyone outside.**
A test deployment with stand-in tokens runs on Base Sepolia
([vault](https://base-sepolia.blockscout.com/address/0x5713Ff26225F6127FF98747087607D483d0DFE68),
verified). It was built from an earlier revision of this code. Since then only
comments have changed in `contracts/src`, so the logic is the same, but the
verified source on the explorer differs from this repository in its comments.
The site is at [dcavault.xyz](https://dcavault.xyz) and says deposits are not
open.

This repository is the contracts, their tests and the review write-ups. The
web app, the keeper and the indexer are not published here.

## What is here

| Path | What |
|---|---|
| `contracts/src/DcaVault.sol` | The vault: plans, the share ledger, the admin surface |
| `contracts/src/adapters/` | Chainlink price reads, the Aerodrome swap, Morpho lending. `AaveAdapter.sol` is a second lending adapter that no script here deploys |
| `contracts/src/mocks/` | Test and testnet stand-ins. Not production code |
| `contracts/test/` | Unit, fuzz, invariant, fork, Halmos and Echidna suites |
| `contracts/script/` | Deploy scripts: mainnet, Base Sepolia, local |
| `scripts/` | Helpers: the Halmos and fork-test runners, a rehearsal of the mainnet deploy on a local fork, and a re-check of the mainnet addresses |
| `docs/threat-model.md` | What each key can and cannot do, and the risks accepted rather than solved |
| `docs/hardening-plan.md` | Every finding from five internal review rounds, and what was done about it |
| `packages/config/addresses.base.json` | The Base mainnet addresses the deploy uses, with how each was verified |

## Who can do what

| | Can | Cannot |
|---|---|---|
| **Plan owner** | Start a plan. Stop it on any day the lending market can pay. | Touch anyone else's plan. |
| **Keeper** | Send a buy once it is due. | Change the stock, the amount, the destination or the schedule. Withdraw anything. |
| **Anyone** | Send a buy that is 12 hours overdue. | The same limits as the keeper. |
| **Admin** | Pause new deposits, switch off a route, set the fee up to 10% of interest. Add a route, loosen the price limit or change a price feed after 48 hours in public. | Move user funds. Block `exitPlan`. Upgrade anything: there is no proxy. |

`docs/threat-model.md` has the exact list, function by function.

## Launch posture

Set in `contracts/script/Deploy.s.sol`, not in a config file:

- Fee 0. It can only ever be taken from interest, and the code caps it at 10%.
- A $5,000 cap on outstanding principal: money deposited and not yet spent
  or withdrawn. The vault refuses a deposit that would take it past that. The
  admin can raise the cap.
- Admin is handed to a multisig in two steps.
- The deploy ends with deposits **paused**. Opening them is a separate act by
  the multisig.

## Build and test

Needs [Foundry](https://book.getfoundry.sh/).

```
git clone --recurse-submodules https://github.com/YSMsimon/dca-vault-contracts
cd dca-vault-contracts
forge build
BASE_RPC_URL=off forge test
```

`BASE_RPC_URL=off` skips the five suites that read real Base state. To run
those too, point it at a Base RPC:

```
BASE_RPC_URL=<a Base RPC> forge test
```

Three of them (`ForkAdapters`, `ForkAdv`, `ForkHard`) pin an old block, so
the RPC has to serve archive state. Use one with a key. The public endpoint
(`https://mainnet.base.org`) serves that block but rate-limits: one suite on
its own passes, and all five together, with no local cache, lost 12 of their
24 tests to HTTP 429 when tried on 2026-10-04. With `BASE_RPC_URL` unset the
fork suites fall back to the public endpoint, so a plain `forge test` can
show those failures.

## What has been checked

Five rounds of internal review. The first four each fixed what the last one
found and ran everything again: Slither, Aderyn, Mythril, Halmos, Echidna,
and Foundry fuzz and invariant tests. The fifth was four separate
read-throughs before the source was published. `docs/hardening-plan.md` lists
every finding, including the ones that are still open.

None of that is an audit. If you are reading this to decide whether to trust
the code with money, read `docs/threat-model.md`, in particular the section
on residual risks.

## One thing a fork cannot test

The stock tokens are B20 tokens, which on Base are precompiles: their code is
the single byte `0xef`, and a standard EVM cannot execute a call to them. A
fork test can deploy the vault, deposit, lend and exit, but it cannot make a
buy.

The whole path, deposit to lend to buy to exit, has been run read-only
against live Base state, where the real node executes the precompile, and it
passed (Round 5 in `docs/hardening-plan.md`). That is a simulation, not a
mined transaction: no buy has been executed on a real chain yet.

## Reporting a vulnerability

Use **Report a vulnerability** on this repository's Security tab. It is
private. There is no paid bounty yet.

## Licence

MIT.
