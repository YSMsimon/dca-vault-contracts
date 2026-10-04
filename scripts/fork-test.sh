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
forge test --match-path 'contracts/test/Fork*.t.sol' -vv
