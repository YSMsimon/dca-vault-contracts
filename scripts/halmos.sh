#!/usr/bin/env bash
# Symbolic checks (Halmos) for the vault's share ledger and cap, and (with
# HALMOS_CONTRACT=HalmosReaudit) the round-2 timelock checks.
#
#   bash scripts/halmos.sh                 # all check_* in HalmosLedger
#   bash scripts/halmos.sh --function check_capHolds
#   HALMOS_CONTRACT=HalmosReaudit bash scripts/halmos.sh   # the round-2 checks
#   HALMOS_CONTRACT=HalmosRound3 bash scripts/halmos.sh    # the round-3 checks
#
# Separate out/cache dirs and dynamic test linking OFF: Foundry 1.8 rewrites
# `new X()` in test files into vm.deployCode, which Halmos 0.3.3 does not
# implement, and sharing contracts/out would thrash the normal build.
# Install: uv tool install halmos
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
export FOUNDRY_DYNAMIC_TEST_LINKING=false
export FOUNDRY_OUT=contracts/out-halmos
export FOUNDRY_CACHE_PATH=contracts/cache-halmos
exec halmos --contract "${HALMOS_CONTRACT:-HalmosLedger}" --forge-build-out contracts/out-halmos \
  --solver-timeout-assertion 60000 "$@"
