// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracle} from "../src/adapters/ChainlinkOracle.sol";
import {MorphoAdapter, IERC4626} from "../src/adapters/MorphoAdapter.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {AerodromeSwapAdapter, ICLPool} from "../src/adapters/AerodromeSwapAdapter.sol";
import {MockStock} from "../src/mocks/Mocks.sol";
import {FakeFeed} from "./utils/HostileVenues.sol";

/// Somebody else's swaps on a real pool, either way. It pays whatever the
/// pool asks for in the callback.
contract PoolPusher {
    address immutable usdc;
    address immutable stock;

    constructor(address u, address s) {
        usdc = u;
        stock = s;
    }

    /// `amount` of USDC in. USDC is token0, so the tick goes DOWN.
    function buy(address pool, uint256 amount) external {
        ICLPool(pool).swap(address(this), true, int256(amount), 4295128740 + 1, "");
    }

    /// USDC in until the pool's price is down at `sqrtLimit`.
    function buyTo(address pool, uint160 sqrtLimit) external {
        uint256 all = IERC20(usdc).balanceOf(address(this));
        ICLPool(pool).swap(address(this), true, int256(all), sqrtLimit, "");
    }

    /// The stock back in until the pool's price is back up at `sqrtLimit`.
    function sellTo(address pool, uint160 sqrtLimit) external {
        uint256 all = IERC20(stock).balanceOf(address(this));
        ICLPool(pool).swap(address(this), false, int256(all), sqrtLimit, "");
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        if (amount0 > 0) IERC20(usdc).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) IERC20(stock).transfer(msg.sender, uint256(amount1));
    }
}

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
    address constant GOOGLC_POOL = 0xB1987CAD1682841b4b641d50E520777eC5Ab5542;
    address constant AAPLC_POOL = 0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0;
    address constant METAC_POOL = 0xEAF57753BC382E0324a1D43F72E7027705a2273E;
    // Chainlink's L2 Sequencer Uptime Status Feed for Base.
    address constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

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
        ChainlinkOracle o = new ChainlinkOracle(address(0), false);
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

        ChainlinkOracle o = new ChainlinkOracle(address(0), false);
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
    ///         starts empty: it is a stand-in, not the token. (A stand-in is
    ///         enough to run the real POOL's code, whose price, liquidity and
    ///         observations are ordinary storage. That is all
    ///         test_Fork_APushOnTheRealPoolIsCaught uses it for.)
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

    // ------------------------------------------------- the push check's reference
    /// What the pool itself answers for the adapter's six instants, moved
    /// `lead` seconds nearer: observe([300 - lead, ..., 60 - lead, 0]).
    /// With `lead` 0 it is the adapter's own read. With `lead` 2 the first
    /// five are the instants a block two seconds from now will ask about.
    function _cumulatives(address pool, uint32 lead) internal view returns (int56[] memory cum) {
        uint32[] memory ago = new uint32[](6);
        for (uint32 i; i < 5; ++i) {
            ago[i] = 300 - 60 * i - lead;
        }
        (cum,) = ICLPool(pool).observe(ago);
        assertEq(cum.length, 6, "the pool did not answer six cumulatives");
    }

    /// The tick-seconds the pool counted over the last `over` seconds.
    function _tickSeconds(address pool, uint32 over) internal view returns (int256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = over;
        (int56[] memory c,) = ICLPool(pool).observe(ago);
        return int256(c[1]) - int256(c[0]);
    }

    /// floor(a / b) for b > 0: the largest q with q * b <= a. Written as a
    /// search, not the way the adapter writes it.
    function _floor(int256 a, int256 b) internal pure returns (int256 q) {
        q = a / b;
        while (q * b > a) --q;
    }

    /// The lowest and highest of five one-minute mean ticks, from six
    /// cumulatives, with `extra` more tick-seconds in the last minute.
    function _lowHigh(int56[] memory cum, int256 extra)
        internal
        pure
        returns (int256 lo, int256 hi)
    {
        lo = type(int256).max;
        hi = type(int256).min;
        for (uint256 i; i < 5; ++i) {
            int256 m =
                _floor(int256(cum[i + 1]) - int256(cum[i]) + (i == 4 ? extra : int256(0)), 60);
            if (m < lo) lo = m;
            if (m > hi) hi = m;
        }
    }

    /// A sqrtPriceX96 `ticks` ticks BELOW `from`: from / 1.0001^(ticks / 2),
    /// in 1e18 fixed point. Good to a tick or two, which is all a price
    /// limit here needs; the tests read the tick the pool actually ended on.
    function _sqrtBelow(uint160 from, uint256 ticks) internal pure returns (uint160) {
        uint256 r = 1e18;
        uint256 b = 1_000_049_998_750_062_496; // sqrt(1.0001)
        for (uint256 n = ticks; n != 0; n >>= 1) {
            if (n & 1 == 1) r = r * b / 1e18;
            b = b * b / 1e18;
        }
        return uint160(uint256(from) * 1e18 / r);
    }

    function _pushed(int24 spot, int256 furthest) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(AerodromeSwapAdapter.PoolPushed.selector, spot, int24(furthest));
    }

    /// @notice Round 6 (R5-2), as reworked in round 6b: the adapter's push
    ///         check can read all four launch pools, what it reads is the
    ///         pool's own five one-minute averages, and each pool is inside
    ///         the band at the fork block.
    /// @dev    `ticks` is the read `swapExactIn` makes before it swaps, so a
    ///         pool that reverts here (no `observe`, or no observation five
    ///         minutes old) is a route that cannot buy. Its answer is held
    ///         to the same six cumulatives asked of the pool directly and
    ///         floored here. A failure of the band assertions alone means
    ///         that pool really did move more than 1% inside the five
    ///         minutes before this block: run it again.
    function test_Fork_TheFourPoolsAnswerTheirAverageAndSitInsideTheBand() public {
        AerodromeSwapAdapter s = new AerodromeSwapAdapter(IERC20(USDC), me);
        address[4] memory pools = [POOL, GOOGLC_POOL, AAPLC_POOL, METAC_POOL];
        string[4] memory names = ["NVDAc", "GOOGLc", "AAPLc", "METAc"];
        for (uint256 i; i < 4; ++i) {
            uint256 g = gasleft();
            (int24 spot, int24 low, int24 high) = s.ticks(pools[i]);
            emit log_named_uint(string.concat(names[i], " ticks() gas"), g - gasleft());
            emit log_named_int(string.concat(names[i], " spot tick"), spot);
            emit log_named_int(string.concat(names[i], " lowest 60 s mean tick"), low);
            emit log_named_int(string.concat(names[i], " highest 60 s mean tick"), high);
            (, int24 poolSpot,,,,) = ICLPool(pools[i]).slot0();
            assertEq(spot, poolSpot, "ticks() does not answer the pool's spot");
            (int256 lo, int256 hi) = _lowHigh(_cumulatives(pools[i], 0), 0);
            assertEq(int256(low), lo, "ticks() low is not the lowest of the pool's five means");
            assertEq(int256(high), hi, "ticks() high is not the highest of the pool's five means");
            assertLe(
                int256(spot) - low, s.MAX_TWAP_DRIFT(), "spot is over the band at the fork block"
            );
            assertLe(
                int256(high) - spot, s.MAX_TWAP_DRIFT(), "spot is under the band at the fork block"
            );
            // The window has to stay covered however often the pool trades:
            // one observation per 2 s block needs at least 150 of them.
            (,,, uint16 cardinality,,) = ICLPool(pools[i]).slot0();
            assertGe(cardinality, 150, "too few observations to always cover the window");
        }
    }

    /// @notice Round 6 (R5-2) and round 6b, on the real pool's own code and
    ///         state. First: a swap in this block moves none of the pool's
    ///         averages, so the adapter sees a push as drift and refuses to
    ///         buy. Then the sequence that beat round 6's single average:
    ///         one block at an extreme tick, and a strike in the next.
    /// @dev    The whole check rests on how the pool's oracle behaves, and a
    ///         mock can only assume it. Here the real NVDAc pool runs. The
    ///         B20 cannot (test_Fork_B20IsNativePrecompile), so a stand-in
    ///         ERC-20 is etched at its address and given a balance for the
    ///         pool to pay out of: the pool's price, liquidity and
    ///         observations are untouched real state. This proves the pool
    ///         half of a buy, not the token half.
    ///
    ///         Both halves start from the fork block's state. A failure in
    ///         the first lines of either (the unpushed buy, or the control)
    ///         means the real pool moved more than 1% in the five minutes
    ///         before this block: run it again.
    ///
    ///         It is the heaviest reader in this file: two swaps across
    ///         90,000 ticks of the real pool, every slot fetched from the
    ///         RPC. A bare `EvmError: Revert` here, next to `over rate
    ///         limit` failures in the tests beside it, is the RPC refusing
    ///         a storage read in the middle of a swap, not the pool: run
    ///         this file on one thread (`--threads 1`, which is what
    ///         scripts/fork-test.sh does).
    function test_Fork_APushOnTheRealPoolIsCaught() public {
        vm.etch(NVDAC, address(new MockStock("stand-in", "NVDAc")).code);
        MockStock(NVDAC).mint(POOL, 1e16);
        AerodromeSwapAdapter s = new AerodromeSwapAdapter(IERC20(USDC), me);
        deal(USDC, me, 1_000e6);
        IERC20(USDC).approve(address(s), type(uint256).max);
        PoolPusher pusher = new PoolPusher(USDC, NVDAC);
        deal(USDC, address(pusher), 50_000_000e6);

        uint256 forkState = vm.snapshotState();
        _aPushInThisBlockIsCaught(s, pusher);
        vm.revertToState(forkState);
        _oneBlockAtAnExtremeTickIsCaught(s, pusher);
    }

    function _aPushInThisBlockIsCaught(AerodromeSwapAdapter s, PoolPusher pusher) internal {
        int24 band = s.MAX_TWAP_DRIFT();
        uint256 t0 = block.timestamp;
        address to = address(0xA11CE);

        // Unpushed, a buy goes through the real pool and the check.
        (, int24 low0, int24 high0) = s.ticks(POOL);
        {
            uint256 out = s.swapExactIn(POOL, NVDAC, 100e6, 0, to);
            assertGt(out, 0);
            assertEq(MockStock(NVDAC).balanceOf(to), out);
        }
        // The pool's own last minute before anything here touched it.
        int256 lastMinute;
        {
            int56[] memory atFork = _cumulatives(POOL, 0);
            lastMinute = _floor(int256(atFork[5]) - int256(atFork[4]), 60);
        }

        // The push: buy until the price is two bands (about 2%) above every
        // one of the five averages. USDC is token0, so a higher price is a
        // LOWER tick.
        int24 spot;
        {
            uint256 had = IERC20(USDC).balanceOf(address(pusher));
            for (uint256 i; i < 100; ++i) {
                pusher.buy(POOL, 250_000e6);
                (, spot,,,,) = ICLPool(POOL).slot0();
                if (spot < low0 - 2 * band) break;
            }
            assertLt(spot, low0 - 2 * band, "25M USDC did not move the pool 2%");
            emit log_named_int("pushed, ticks under the lowest average", int256(low0) - spot);
            emit log_named_decimal_uint(
                "with, USDC", had - IERC20(USDC).balanceOf(address(pusher)), 6
            );
        }

        // Same block: not one of the five averages has moved, and the buy
        // is refused. The furthest average is the highest.
        (int24 spot1, int24 low, int24 high) = s.ticks(POOL);
        assertEq(spot1, spot);
        assertEq(low, low0, "a swap in this block moved an average");
        assertEq(high, high0, "a swap in this block moved an average");
        vm.expectRevert(_pushed(spot, high0));
        s.swapExactIn(POOL, NVDAC, 100e6, 0, to);

        // Next block. Its five minutes start two seconds later, so ask the
        // pool now for what it has counted at those instants: the next
        // block adds two seconds at the pushed tick to the LAST minute and
        // nothing to the other four.
        {
            int56[] memory ahead = _cumulatives(POOL, 2);
            vm.warp(t0 + 2);
            vm.roll(block.number + 1);
            (int256 lo, int256 hi) = _lowHigh(ahead, 2 * int256(spot));
            (, low, high) = s.ticks(POOL);
            assertEq(int256(low), lo, "two seconds of the push are not 2/60 of the last minute");
            assertEq(int256(high), hi, "the push reached a minute it was not in");
        }
        assertGt(int256(high) - spot, band);
        vm.expectRevert(_pushed(spot, high));
        s.swapExactIn(POOL, NVDAC, 100e6, 0, to);

        // Four minutes on, with nobody arbitraging it back (a fork has no
        // arbitrageurs): four of the minutes are all push, and the oldest
        // is still the pool's own last minute before it. One average over
        // the 300 seconds would be four fifths of the way to the push by
        // now. The buy is still refused.
        vm.warp(t0 + 240);
        (, low, high) = s.ticks(POOL);
        assertEq(low, spot);
        assertEq(int256(high), lastMinute, "the oldest minute is not the pool's own");
        vm.expectRevert(_pushed(spot, high));
        s.swapExactIn(POOL, NVDAC, 100e6, 0, to);

        // Held there for the whole window, every average catches up and it
        // passes. That is a residual the threat model states.
        vm.warp(t0 + s.TWAP_WINDOW());
        (, low, high) = s.ticks(POOL);
        assertEq(low, spot);
        assertEq(high, spot);
        s.swapExactIn(POOL, NVDAC, 100e6, 0, to);
    }

    /// The round-6b attack (Round6b.test_R6b_OneBlockAtAnExtremeTickNoLongerPasses
    /// has it on a mock). The attacker wants the pool at a strike 600 ticks
    /// (about 6%) dearer than its market, where a stale print would be, and
    /// wants the pool's history to agree. One block far past the strike
    /// moved a single 300 s average all the way there. It moves one of the
    /// five one-minute averages five times as far, and four not at all.
    function _oneBlockAtAnExtremeTickIsCaught(AerodromeSwapAdapter s, PoolPusher pusher) internal {
        (uint160 sqrtP0, int24 spot0,,,,) = ICLPool(POOL).slot0();
        int256 target = int256(spot0) - 600;

        // Block N: buy until the pool is far enough past the strike for the
        // 300 s average to land on it in the next block. With A the
        // tick-seconds the pool counted over the 298 s before this block:
        //     (A + 2 * extreme) / 300 = target
        int24 reached;
        {
            int256 extreme = (300 * target - _tickSeconds(POOL, 298)) / 2;
            assertLt(extreme, target - 50_000, "the sizing is off: is the pool near its average?");
            uint256 had = IERC20(USDC).balanceOf(address(pusher));
            pusher.buyTo(POOL, _sqrtBelow(sqrtP0, uint256(int256(spot0) - extreme)));
            (, reached,,,,) = ICLPool(POOL).slot0();
            assertApproxEqAbs(int256(reached), extreme, 5, "the pool did not reach the extreme");
            emit log_named_int("one block at, ticks under the market", int256(spot0) - reached);
            emit log_named_decimal_uint(
                "it took, USDC", had - IERC20(USDC).balanceOf(address(pusher)), 6
            );
        }
        // What the next block's five minutes have counted so far.
        int56[] memory ahead = _cumulatives(POOL, 2);

        // Block N+1: sell back until the pool is at the strike.
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);
        pusher.sellTo(POOL, _sqrtBelow(sqrtP0, 600));
        (int24 spot, int24 low, int24 high) = s.ticks(POOL);
        assertApproxEqAbs(int256(spot), target, 5, "the pool is not at the strike");

        // CONTROL: what round 6 compared the spot with. One average over
        // the 300 seconds sits on the strike, well inside the band, so
        // round 6's check let this buy through.
        {
            int256 mean300 = _floor(_tickSeconds(POOL, 300), 300);
            emit log_named_int("spot at the strike", spot);
            emit log_named_int("the single 300 s mean", mean300);
            assertApproxEqAbs(mean300, int256(spot), 5, "the 300 s average is not on the strike");
            assertLt(5, s.MAX_TWAP_DRIFT(), "the old check would not have passed");
        }

        // Now: the block shows up whole in the last minute's average, 30
        // times its two seconds' worth, and not at all in the four before.
        emit log_named_int("lowest 60 s mean", low);
        emit log_named_int("highest 60 s mean", high);
        {
            (int256 lo, int256 hi) = _lowHigh(ahead, 2 * int256(reached));
            assertEq(int256(low), lo, "the block is not 2/60 of the last minute");
            assertEq(int256(high), hi, "the block reached a minute it was not in");
        }
        assertGt(int256(high) - spot, 400, "the strike is not 600 off the four minutes before");
        assertGt(int256(spot) - low, 2_000, "the block is not in the last minute");
        // The last minute is the further of the two.
        vm.expectRevert(_pushed(spot, low));
        s.swapExactIn(POOL, NVDAC, 100e6, 0, address(0xA11CE));
        assertEq(MockStock(NVDAC).balanceOf(address(0xA11CE)), 0, "the buy went through");
    }

    /// @notice Round 6 (R5-6): the sequencer uptime feed the deploy pins is
    ///         the real one, the oracle's bounded read can read it, and it
    ///         gates `isFresh`.
    /// @dev    The oracle IGNORES an uptime feed it cannot read. So if the
    ///         real feed ever needed more than the gas the oracle gives it,
    ///         or answered fewer than five words, the check would be off and
    ///         nothing would say so. This is the test that would.
    function test_Fork_SequencerUptimeFeedIsReadAndGatesFreshness() public {
        (bool ok, bytes memory ret) = SEQUENCER_UPTIME_FEED.staticcall{gas: 100_000}(
            abi.encodeWithSignature("latestRoundData()")
        );
        assertTrue(ok, "the uptime feed does not answer inside the oracle's gas");
        assertGe(ret.length, 160, "the uptime feed answers fewer than five words");
        (, int256 answer, uint256 startedAt,,) =
            abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        emit log_named_int("sequencer answer (0 = up)", answer);
        emit log_named_uint("up for (hours)", (block.timestamp - startedAt) / 3600);
        bool up = answer == 0 && block.timestamp - startedAt >= 1 hours;

        // A price that is fresh whatever day the fork lands on, and an
        // oracle WITHOUT the weekend rule (round 6b), so that the sequencer
        // is the only thing left to decide: with the rule on, as mainnet's
        // oracle has it, this would read false all weekend whatever the
        // sequencer said. ForkDeploy.t.sol asserts the weekend on the
        // oracle the deploy script builds.
        FakeFeed px = new FakeFeed();
        ChainlinkOracle o = new ChainlinkOracle(SEQUENCER_UPTIME_FEED, false);
        assertFalse(o.weekendClosed());
        assertEq(o.sequencerUp(), up, "sequencerUp() does not follow the real uptime feed");
        o.setFeed(NVDAC, address(px));
        uint256 g = gasleft();
        assertEq(o.isFresh(NVDAC), up, "isFresh does not follow the real uptime feed");
        emit log_named_uint("isFresh gas, uptime feed included", g - gasleft());

        // And it is that feed's answer that decides.
        bytes memory sel = abi.encodeWithSignature("latestRoundData()");
        vm.mockCall(
            SEQUENCER_UPTIME_FEED,
            sel,
            abi.encode(uint80(1), int256(1), block.timestamp - 60, block.timestamp, uint80(1))
        );
        assertFalse(o.isFresh(NVDAC), "fresh while the sequencer is down");
        vm.mockCall(
            SEQUENCER_UPTIME_FEED,
            sel,
            abi.encode(uint80(1), int256(0), block.timestamp - 600, block.timestamp, uint80(1))
        );
        assertFalse(o.isFresh(NVDAC), "fresh ten minutes after a restart");
        vm.mockCall(
            SEQUENCER_UPTIME_FEED,
            sel,
            abi.encode(uint80(1), int256(0), block.timestamp - 3600, block.timestamp, uint80(1))
        );
        assertTrue(o.isFresh(NVDAC), "not fresh an hour after a restart");
    }
}
