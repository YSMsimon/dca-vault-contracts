#!/usr/bin/env bash
# Just the fork suites (contracts/test/Fork*.t.sol), which read real Base
# mainnet state, when you want only those.
#
#   BASE_RPC_URL=<a Base RPC> bash scripts/fork-test.sh
#
# Plain `forge test` runs them too: each suite creates its own fork from
# BASE_RPC_URL, or from the public endpoint when it is unset. BASE_RPC_URL=off
# skips them, which is how an offline run stays offline. This script is the
# narrow runner, not the only way in.
#
# BASE_RPC_URL comes from the environment, or from a .env file at the repo root
# if it is not already set. Foundry loads .env from the project root by itself;
# sourcing it here keeps the :? check below able to give a useful error instead
# of a forge one.
#
# Three of the suites (ForkAdapters, ForkAdv, ForkHard) pin an old block, so
# they need an RPC that serves archive state.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."

if [ -z "${BASE_RPC_URL:-}" ] && [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${BASE_RPC_URL:?set BASE_RPC_URL in the environment, or in a .env file at the repo root}"

# mainnet.base.org rate-limits hard. Fork.t.sol takes a fresh latest block every
# run so it always re-fetches; ForkAdapters.t.sol is pinned and caches.
case "$BASE_RPC_URL" in
  *base.org*) echo "note: public endpoint, rate-limits hard. Alchemy/QuickNode is steadier." ;;
esac

# No --fork-url. Every suite calls createSelectFork itself, and a --fork-url
# default fork alongside a pinned one panics foundry 1.8.3 inside op-revm.
#
# Run from the REPO ROOT, which is the one foundry project root.
#
# Two forge runs, and both always happen.
#
# 1. Fork.t.sol and ForkDeploy.t.sol fork the LATEST block, so nothing they
#    read is cached: every storage slot is a request. Fork.t.sol's tests are
#    heavy readers (two swaps across 90,000 ticks of the real pool, and six
#    binary searches of each launch pool's observations where round 6 made
#    two), and forge runs a file's tests side by side. Together they ask for
#    more than a rate-limited endpoint gives: it answers HTTP 429 "over rate
#    limit", forge gives up after its retries, and three tests fail on the
#    transport, one of them as a bare `EvmError: Revert` in the middle of a
#    swap. ONE THREAD fixes it: measured in round 6b on a key that was being
#    throttled, 4 passed and 3 failed side by side, and 7 passed on one
#    thread a minute later, in 55 s.
# 2. The other three pin an old block. forge caches what they read, so they
#    can have every core.
rc=0
forge test --match-path 'contracts/test/{Fork,ForkDeploy}.t.sol' --threads 1 -vv || rc=1
forge test --match-path 'contracts/test/{ForkAdapters,ForkAdv,ForkHard}.t.sol' -vv || rc=1
exit "$rc"
