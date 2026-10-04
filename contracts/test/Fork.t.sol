// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracle} from "../src/adapters/ChainlinkOracle.sol";
import {MorphoAdapter, IERC4626} from "../src/adapters/MorphoAdapter.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {AerodromeSwapAdapter} from "../src/adapters/AerodromeSwapAdapter.sol";

/// @notice Against REAL Base mainnet state.
/// @dev    Base Sepolia carries none of this protocol's dependencies — no
///         NVDAc, so no pool, no feed and no swap leg — so a "testnet
///         integration" there can only re-run the mocks the unit tests
///         already pass against. The failures that can actually kill this
///         design exist only on mainnet.
///         Run: BASE_RPC_URL=<a Base RPC> forge test --match-path 'contracts/test/Fork.t.sol'
contract ForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant VAULT = 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61; // Gauntlet USDC Prime
    address constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address constant POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9; // Aerodrome Slipstream
    address constant FEED = 0x04689a41629776563E6822F76f2e57D148d28513; // Coinbase NVDA

    address me = address(this);

    /// @dev Forks at LATEST, on purpose: this file's job is asserting the
    ///      external world still looks the way the design assumed, so it must
    ///      not be pinned. ForkAdapters.t.sol pins its own instead.
    ///
    ///      It used to take the default fork from --fork-url, which is what
    ///      forced two forge invocations: a --fork-url default fork alongside a
    ///      pinned createSelectFork panics foundry 1.8.3 inside op-revm. Two
    ///      createSelectFork calls do not, so this creates its own and plain
    ///      `forge test` runs every fork suite in one command. BASE_RPC_URL=off
    ///      skips them, which keeps an offline run offline; with it unset they
    ///      use the public endpoint (see below).
    function setUp() public {
        // Default to the public endpoint so a fresh clone with a network
        // connection runs these, instead of silently skipping and reporting a
        // green suite that never touched Base. Opting out is EXPLICIT:
        // BASE_RPC_URL=off. Absence is not intent.
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.skip(keccak256(bytes(rpc)) == keccak256("off") || bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
    }

    function test_Fork_ChainlinkFeedIsReadable() public {
        ChainlinkOracle o = new ChainlinkOracle();
        o.setFeed(NVDAC, FEED);
        (uint256 px, uint256 ts) = o.latestPrice(NVDAC);
        assertGt(px, 50e8, "NVDA under $50 - wrong feed or wrong decimals");
        assertLt(px, 2000e8, "NVDA over $2000 - wrong decimals");
        assertGt(ts, 0);
        emit log_named_decimal_uint("NVDA price", px, 8);
        emit log_named_uint("feed age (hours)", (block.timestamp - ts) / 3600);
    }

    function test_Fork_MorphoVaultIsUsable() public {
        IERC4626 v = IERC4626(VAULT);
        assertGt(v.totalAssets(), 1_000_000e6, "vault TVL under $1M - wrong address?");
        MorphoAdapter a = new MorphoAdapter(IERC20(USDC), v, me);

        deal(USDC, me, 10_000e6);
        IERC20(USDC).approve(address(a), type(uint256).max);

        uint256 shares = a.supply(10_000e6);
        assertGt(shares, 0, "no shares minted");

        uint256 valued = a.assetsOf(shares);
        // ERC-4626 rounds down; a round-trip may sit one wei below par. That is
        // exactly why `accrued` saturates instead of reverting.
        assertApproxEqAbs(valued, 10_000e6, 10, "round-trip value drifted");
        assertGt(a.availableLiquidity(), 0, "maxWithdraw reports no liquidity");

        (, uint256 burned) = a.withdraw(1_000e6);
        assertGt(burned, 0);
        assertApproxEqAbs(IERC20(USDC).balanceOf(me), 1_000e6, 2, "withdrew wrong amount");
    }

    function test_Fork_PoolIsSlipstreamAndPriced() public {
        AerodromeSwapAdapter s = new AerodromeSwapAdapter(IERC20(USDC), me);
        uint256 px = s.poolPrice(POOL, NVDAC);
        emit log_named_decimal_uint("pool price", px, 8);

        ChainlinkOracle o = new ChainlinkOracle();
        o.setFeed(NVDAC, FEED);
        (uint256 ref,) = o.latestPrice(NVDAC);

        uint256 diff = px > ref ? px - ref : ref - px;
        emit log_named_uint("divergence bps", diff * 10_000 / ref);
        assertLt(diff * 10_000 / ref, 2_000, "pool and feed disagree by >20% - decoding is wrong");
    }

    /// @notice B20 tokens are NATIVE PRECOMPILES, not EVM contracts.
    /// @dev    Discovered the hard way on 2026-09-21: every B20 address holds
    ///         exactly one byte of code, `0xef` — the EIP-3541 reserved prefix,
    ///         which is NOT valid EVM bytecode. Base implements these tokens in
    ///         the node and uses the stub so `extcodesize != 0` sanity checks
    ///         pass. `eth_call` to `decimals()` answers 8 on the real chain; a
    ///         forked EVM copies `0xef`, cannot execute it, and reverts.
    ///
    ///         CONSEQUENCE FOR THE TEST STRATEGY: the swap leg cannot be
    ///         fork-tested. `vm.etch` does not rescue it either — the balances
    ///         live in native node state, not EVM storage, so an etched ERC-20
    ///         would start empty and the pool would report zero reserves.
    ///
    ///         What fork tests DO cover, fully and for real: the yield leg
    ///         (Morpho ERC-4626) and the price leg (Chainlink feed + pool
    ///         slot0 decoding). The swap leg needs a small real transaction
    ///         on Base. So far it has only been run read-only against live
    ///         Base state (docs/hardening-plan.md, Round 5), not mined.
    ///
    ///         This test asserts the stub so a future Base upgrade that turns
    ///         B20 into ordinary contracts is noticed immediately — at which
    ///         point the swap leg becomes fork-testable and this test should be
    ///         replaced with a real swap.
    function test_Fork_B20IsNativePrecompile() public view {
        assertEq(
            NVDAC.code,
            hex"ef",
            "B20 is no longer a precompile stub - revisit the swap-leg test plan"
        );
        assertEq(IERC20(USDC).decimals(), 6, "USDC is not 6 decimals");
        assertGt(USDC.code.length, 100, "control: USDC should be a real contract");
    }
}
