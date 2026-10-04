// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice Per-run coverage lines from the invariant suites, for re-tests.
/// @dev    Forge prints an invariant suite's logs for ONE run, so "how many
///         executes actually succeeded" across 2,000 runs cannot be read off
///         its output. With DCA_INVARIANT_STATS=1 each suite appends one line
///         per run to contracts/deployments/invariant-stats/<suite>.txt
///         (gitignored); without it this does nothing. Sum with e.g.
///         awk '{s+=$1} END {print s}'.
library InvStats {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    string private constant DIR = "./contracts/deployments/invariant-stats";

    function record(string memory suite, string memory line) internal {
        if (!vm.envOr("DCA_INVARIANT_STATS", false)) return;
        vm.createDir(DIR, true);
        vm.writeLine(string.concat(DIR, "/", suite, ".txt"), line);
    }
}
