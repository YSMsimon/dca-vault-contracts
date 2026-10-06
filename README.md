# DCA Vault contracts

Deposit USDC once, and the vault buys a tokenised stock for you on a schedule.
The part that has not been spent yet is lent out, and the interest it earns
buys more of the same stock.

**Status: not deployed on Base mainnet, and not audited by anyone outside.**
A test deployment with stand-in tokens runs on Base Sepolia
([vault](https://base-sepolia.blockscout.com/address/0x5713Ff26225F6127FF98747087607D483d0DFE68),
verified). It was built from an EARLIER revision of this code, and the logic
has changed since: the verified source on the explorer is not what is in this
repository. Rounds 6 and 6b in `docs/hardening-plan.md` list the changes. In
short, the vault there accepts a plan whose last period is a few wei, accepts
a supply that mints no shares, and lets the fee recipient be the vault
itself. The two changes to the swap adapter and the price oracle do not show
there either way, because the test deployment uses stand-ins for both. It
also has none of round 6b: its vault lets the fee recipient be the oracle,
and its stand-ins have neither the five-average check nor the weekend rule.
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
| `docs/hardening-plan.md` | Every finding from six internal review rounds and a re-review of the sixth, and what was done about it |
| `packages/config/addresses.base.json` | The Base mainnet addresses the deploy uses, with how each was verified |

## Who can do what

| | Can | Cannot |
|---|---|---|
| **Plan owner** | Start a plan. Stop it on any day the lending market can pay. | Touch anyone else's plan. |
| **Keeper** | Send a buy once it is due. | Change the stock, the amount, the destination or the schedule. Withdraw anything. |
| **Anyone** | Send a buy that is 12 hours overdue. | The same limits as the keeper. |
| **Admin** | Pause new deposits, switch off a route, set the fee up to 10% of interest. Add a route, loosen the price limit or change a price feed after 48 hours in public. | Move user funds directly. Holding the oracle's admin as well, which is the launch setup, and after a public 48-hour feed change, it can make due buys fill at a bad price: up to one due installment per plan per interval. Block `exitPlan`. Upgrade anything: there is no proxy. |

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
- A buy is refused while the pool's spot price is more than 100 ticks (about
  1%) from any of that pool's own five one-minute averages over the last five
  minutes. A push that leaves the price more than about 1% from any of the
  five averages is refused, in the same transaction or block. A push that
  ends inside that band goes through; from the far edge of the band that is
  a move of up to about 2%. So does a larger one by someone who leaves the
  pool off-market for a block in each of those five minutes, or who holds
  one push for most of them: that costs them capital and pool fees, and
  nothing in the code prevents it. It pays only while the price feed reads
  above the market. Measured on a fork with nobody trading against the
  attacker and a feed 6.2% above the pool, the cheapest way past the check
  breaks even at about 7,600 USDC of buys executable at once, and loses
  money under the 5,000 USDC cap (`docs/hardening-plan.md`, R6b-2). The cap
  is what keeps it unprofitable. The numbers are constants in `AerodromeSwapAdapter.sol`,
  not settings: nobody can change them.
- The price oracle is deployed with Chainlink's sequencer uptime feed for
  Base. No price counts as fresh while the sequencer is down or for an hour
  after it restarts. If that feed cannot be read, the check is skipped.
- No buy executes from Saturday 00:00 UTC to Monday 01:00 UTC. The price
  feeds stop for the weekend and the pools do not, so the oracle is deployed
  with a weekend rule: in those hours no price counts as fresh, whatever the
  feed says. A buy that falls due then waits, a deposit made then opens a
  plan with no first buy, and exits are not affected. A buy that fell due
  during those hours is open to anyone the moment they end, because the 12
  hours a keeper has to itself count from the due time (open, R6b-1). The
  rule is a fixed calendar. It knows no exchange holidays, on which a price can still read
  fresh for up to 24 hours after the feed's last update, and nobody can
  change it if the feeds' schedule changes.

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
its own passes, and all five together, with no local cache, lost 12 of the
24 tests there were then (there are 27 now) to HTTP 429 when tried on
2026-10-04. With `BASE_RPC_URL` unset the fork suites fall back to the public
endpoint, so a plain `forge test` can show those failures.

`Fork.t.sol` reads the latest block and reads a lot of it. On an endpoint
that rate-limits, run it on one thread (`--threads 1`), or use
`bash scripts/fork-test.sh`, which runs the two latest-block suites on one
thread and then the three pinned ones.

## What has been checked

Six rounds of internal review. The first four each fixed what the last one
found and ran everything again: Slither, Aderyn, Mythril, Halmos, Echidna,
and Foundry fuzz and invariant tests. The fifth was four separate
read-throughs before the source was published. The sixth fixed four of the
fifth's contract findings and bounded two (R5-1 and R5-2). Round 6b came
from a re-review of round 6: it found that one of those two bounds was
looser than these documents said, so the check was tightened, buys were
stopped on weekends, and the documents were corrected. Both are still
bounded, not fixed. Round 6b was then reviewed twice more before it was
published: that review measured what passing the price check costs, found
one new Low that is still open (R6b-1), and corrected these documents again.
One of the 19 Halmos checks has not finished since round 4 and has no
result on this code (stopped after 6 hours). `docs/hardening-plan.md` lists every finding, including
the ones that were accepted rather than fixed.

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
passed (Round 5 in `docs/hardening-plan.md`; the deposit, the lending leg and
the first buy were run again on all four routes with round 6's code, and
again on 2026-10-05 with round 6b's, by step 9 of
`scripts/rehearse-mainnet.sh`). That is a simulation, not a mined
transaction: no buy has been executed on a real chain yet.

A fork can still run the POOL's code. `Fork.t.sol` etches a stand-in token at
a B20's address so that the real pool can make a swap, and uses that to check
that a price pushed in the same block is refused. It says nothing about the
B20 itself.

## Reporting a vulnerability

Use **Report a vulnerability** on this repository's Security tab. It is
private. There is no paid bounty yet.

## Licence

MIT.
