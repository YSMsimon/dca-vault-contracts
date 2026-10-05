// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle} from "../src/adapters/ChainlinkOracle.sol";
import {AerodromeSwapAdapter} from "../src/adapters/AerodromeSwapAdapter.sol";
import {MockERC20, MockStock, MockYieldAdapter} from "../src/mocks/Mocks.sol";
import {TwapClPool, RawObservePool, FakeFeed} from "./utils/HostileVenues.sol";
import {RawFeed, QuotePool} from "./Round3.t.sol";

/// Push, execute, unwind: one transaction, callable by anyone once a buy is
/// 12 hours overdue. The push is free here, which is the attacker's best case.
contract Pusher {
    function run(DcaVault v, TwapClPool p, uint256 id, int24 to, int24 back) external {
        p.push(to);
        v.executeDCA(id);
        p.push(back);
    }
}

/// The same, by a caller who also controls the feed the vault prices off:
/// it sets the feed to the pushed pool's price before executing.
contract FeedPusher {
    function run(
        DcaVault v,
        AerodromeSwapAdapter a,
        TwapClPool p,
        FakeFeed f,
        address token,
        uint256 id,
        int24 to,
        int24 back
    ) external {
        p.push(to);
        f.set(int256(a.poolPrice(address(p), token)), block.timestamp, true);
        v.executeDCA(id);
        p.push(back);
    }
}

/// @notice The hardening plan, ROUND 6 (docs/hardening-plan.md): the round-5
///         findings that were changes to the contracts, fixed.
/// @dev    R5-2 and R5-1 run against the REAL AerodromeSwapAdapter, the real
///         ChainlinkOracle and the real vault, on a mock pool whose price
///         oracle behaves like a v3 pool's (TwapClPool). Each test asserts
///         the SAFE behaviour and fails on the code as round 5 left it; where
///         a round-5 reproduction existed, the "Before" note says what it
///         showed.
///
///         ROUND 6b reworked the push check these tests pin. It compared the
///         spot with ONE 300-second mean tick; it now compares it with each
///         of FIVE 60-second means, and `ticks()` answers the spot with the
///         lowest and the highest of the five. Every R5-2 test below states
///         the five-means rule. What one mean let through, and what five
///         still do, is in Round6b.t.sol.
contract Round6Test is Test {
    MockERC20 usdc;
    MockStock stock;
    MockYieldAdapter y;
    ChainlinkOracle cl;
    FakeFeed feed;
    FakeFeed uptime;
    AerodromeSwapAdapter aero; // bound to the vault
    AerodromeSwapAdapter direct; // bound to this test, to call the adapter alone
    TwapClPool pool;
    DcaVault vault;

    address alice = address(0xA11CE);
    address stranger = address(0xBAD);

    /// Where the real NVDAc pool sat when this was written: USDC is token0,
    /// so the tick is negative, and a HIGHER share price is a LOWER tick.
    int24 constant TICK0 = -8556;
    int24 constant BAND = 100;

    function setUp() public {
        vm.warp(1_780_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("Mock NVDAc", "NVDAc");
        y = new MockYieldAdapter(usdc);
        // The sequencer has been up for a month.
        uptime = new FakeFeed();
        uptime.set(0, block.timestamp - 30 days, false);
        cl = new ChainlinkOracle(address(uptime), false);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        aero = new AerodromeSwapAdapter(IERC20(address(usdc)), predicted);
        vault = new DcaVault(IERC20(address(usdc)), y, aero, cl, 10_000_000e6);
        assertEq(address(vault), predicted);
        y.bindVault(address(vault));
        direct = new AerodromeSwapAdapter(IERC20(address(usdc)), address(this));

        pool = new TwapClPool(address(usdc), address(stock), true, TICK0);
        vm.warp(block.timestamp + 1 hours); // a pool with history
        feed = new FakeFeed();
        feed.set(int256(_px()), block.timestamp, true);
        cl.setFeed(address(stock), address(feed));
        vault.initRoute(1, DcaVault.Route(address(stock), address(pool), address(feed), 0, true));
        vault.finishSetup();

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(direct), type(uint256).max);
    }

    // ------------------------------------------------------------ helpers
    /// The pool's spot price, 8 decimals, as the vault's breaker reads it.
    function _px() internal view returns (uint256) {
        return aero.poolPrice(address(pool), address(stock));
    }

    /// `furthest` is the one-minute mean the spot is furthest from.
    function _pushed(int24 spot, int24 furthest) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(AerodromeSwapAdapter.PoolPushed.selector, spot, furthest);
    }

    function _plan(uint256 deposit, uint256 installment) internal returns (uint256 id) {
        vm.prank(alice);
        id = vault.createPlan(1, deposit, installment, 30 days);
    }

    // ===================================================== R5-2: the push
    /// (a) Nothing changes for a pool nobody is pushing: the deposit's first
    /// buy and a later one both fill at the pool's price.
    function test_R5_2_AnHonestPoolPasses() public {
        (int24 spot, int24 low, int24 high) = aero.ticks(address(pool));
        assertEq(spot, TICK0);
        assertEq(low, TICK0);
        assertEq(high, TICK0);

        uint256 id = _plan(10_000e6, 1_000e6);
        uint256 fair = uint256(1_000e6) * 1e10 / _px();
        assertApproxEqRel(stock.balanceOf(alice), fair, 1e12, "the first buy");

        // The market moves 3% and stays: by the next buy every one of the
        // five averages has caught up, and the feed has printed the new price.
        pool.push(TICK0 - 300);
        vm.warp(block.timestamp + 30 days);
        feed.set(int256(_px()), block.timestamp, true);
        (spot, low, high) = aero.ticks(address(pool));
        assertEq(spot, TICK0 - 300);
        assertEq(low, TICK0 - 300);
        assertEq(high, TICK0 - 300);
        uint256 before = stock.balanceOf(alice);
        vm.prank(alice);
        vault.executeDCA(id);
        fair = uint256(1_000e6) * 1e10 / _px();
        assertApproxEqRel(stock.balanceOf(alice) - before, fair, 1e12, "the second buy");

        // And a move inside the band a few seconds ago does not stop a buy.
        vm.warp(block.timestamp + 30 days - 10);
        pool.push(TICK0 - 360);
        vm.warp(block.timestamp + 10);
        (spot, low, high) = aero.ticks(address(pool));
        assertEq(spot, TICK0 - 360);
        assertEq(low, TICK0 - 310, "the last minute: 50 s at -300 and 10 s at -360");
        assertEq(high, TICK0 - 300, "the four minutes before the move");
        vm.prank(alice);
        vault.executeDCA(id);
    }

    /// (b) The sandwich the fill bound alone let through. The pool trades 90
    /// bps under the feed; the caller pushes it 150 ticks up, so the victim
    /// fills about 60 bps over the feed, inside the 1% bound and inside the
    /// breaker, but 1.5% over what the pool was charging. Before: it filled.
    function test_R5_2_APoolPushedInTheSameTransactionReverts() public {
        feed.set(int256(_px() * 10_090 / 10_000), block.timestamp, true);
        uint256 id = _plan(100_000e6, 10_000e6);
        vm.warp(block.timestamp + 30 days + 12 hours); // due + grace: anyone

        Pusher s = new Pusher();
        uint256 before = stock.balanceOf(alice);
        vm.expectRevert(_pushed(TICK0 - 150, TICK0));
        vm.prank(stranger);
        s.run(vault, pool, id, TICK0 - 150, TICK0);
        assertEq(stock.balanceOf(alice), before, "something was bought");

        // The numbers in the error are what ticks() answers, mid-push.
        pool.push(TICK0 - 150);
        (int24 spot, int24 low, int24 high) = aero.ticks(address(pool));
        assertEq(spot, TICK0 - 150);
        assertEq(low, TICK0, "a push in this block moved an average");
        assertEq(high, TICK0, "a push in this block moved an average");
        // Somebody else's transaction later in the same block is refused too.
        vm.expectRevert(_pushed(TICK0 - 150, TICK0));
        vm.prank(stranger);
        vault.executeDCA(id);
        // And in the next block: two seconds of the pushed price is five
        // ticks of the last minute's average and nothing of the other four,
        // so the furthest average is still where the pool was.
        vm.warp(block.timestamp + 2);
        (, low, high) = aero.ticks(address(pool));
        assertEq(low, TICK0 - 5, "the last minute: 58 s at 0 and 2 s at -150");
        assertEq(high, TICK0, "the four minutes before the push");
        vm.expectRevert(_pushed(TICK0 - 150, TICK0));
        vm.prank(stranger);
        vault.executeDCA(id);

        // Unpushed, the same buy fills at the pool's own price.
        pool.push(TICK0);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(stranger);
        vault.executeDCA(id);
        uint256 fair = uint256(10_000e6) * 1e10 / _px();
        assertApproxEqRel(stock.balanceOf(alice) - before, fair, 1e12);
    }

    /// (c) R5-2 itself. The feed's last print is 20 hours old and still reads
    /// fresh; the market has fallen 5.8% since. Before: a stranger pushed the
    /// pool back up to the print, executed the overdue buy at that price and
    /// unwound, and the plan paid Friday's price for Monday's stock.
    function test_R5_2_AFrozenFeedAndAPushedPoolNoLongerPays() public {
        uint256 id = _plan(100_000e6, 10_000e6);
        uint256 print = _px();
        vm.warp(block.timestamp + 30 days - 8 hours);
        feed.set(int256(print), block.timestamp, false); // the last print, then nothing
        vm.warp(block.timestamp + 2 hours);
        pool.push(TICK0 + 600); // the market moves on without the feed
        vm.warp(block.timestamp + 18 hours); // 12 hours overdue: anyone may execute
        assertTrue(cl.isFresh(address(stock)), "a 20-hour-old print reads fresh");

        // Left alone, the buy waits: the pool is outside the breaker.
        uint256 honestPx = _px();
        vm.expectRevert(abi.encodeWithSelector(DcaVault.PoolDiverged.selector, print, honestPx));
        vm.prank(stranger);
        vault.executeDCA(id);

        // The attack: push the pool back to the print, execute, unwind.
        Pusher s = new Pusher();
        uint256 before = stock.balanceOf(alice);
        vm.expectRevert(_pushed(TICK0, TICK0 + 600));
        vm.prank(stranger);
        s.run(vault, pool, id, TICK0, TICK0 + 600);
        assertEq(stock.balanceOf(alice), before, "the plan bought at the stale print");

        // What is left: a push no larger than the band. It brings the pool
        // inside the breaker, and costs the plan at most the band (about 1%)
        // against the pool's own average, not the 5.8% the print is off by.
        vm.prank(stranger);
        s.run(vault, pool, id, TICK0 + 600 - BAND, TICK0 + 600);
        uint256 got = stock.balanceOf(alice) - before;
        uint256 honest = uint256(10_000e6) * 1e10 / honestPx;
        assertLt(got, honest, "the push cost nothing: the test is not testing a push");
        assertGe(got * 10_000, honest * 9_900, "a push inside the band cost more than the band");
    }

    /// (c) R5-1. One key holds the vault's admin and the oracle's. Before: it
    /// rotated in a feed of its own behind the 48 public hours, made itself a
    /// keeper, then in one transaction set the feed to 100x, pushed the pool
    /// to match, executed and unwound: a 10,000 USDC installment bought 1% of
    /// what it should have. The breaker saw no deviation.
    function test_R5_1_ARotatedFeedAndAPushedPoolNoLongerPays() public {
        uint256 id = _plan(100_000e6, 10_000e6);
        FakeFeed evil = new FakeFeed();
        evil.set(int256(_px()), block.timestamp, true); // mirrors the real price while it is public
        cl.queueFeed(address(stock), address(evil));
        vm.warp(block.timestamp + 48 hours);
        cl.activateFeed(address(stock));
        FeedPusher s = new FeedPusher();
        vault.setKeeper(address(s), true);
        vm.warp(block.timestamp + 28 days);

        uint256 fair = uint256(10_000e6) * 1e10 / _px();
        uint256 before = stock.balanceOf(alice);
        // 1.0001^46054 is 100: the share price, and the feed, times a hundred.
        vm.expectRevert(_pushed(TICK0 - 46_054, TICK0));
        s.run(vault, aero, pool, evil, address(stock), id, TICK0 - 46_054, TICK0);
        assertEq(stock.balanceOf(alice), before, "the plan bought at the attacker's price");

        // What that key can still take in one transaction is the band: its
        // feed can say anything, but the pool will not follow it further.
        vm.expectRevert(_pushed(TICK0 - BAND - 1, TICK0));
        s.run(vault, aero, pool, evil, address(stock), id, TICK0 - BAND - 1, TICK0);
        s.run(vault, aero, pool, evil, address(stock), id, TICK0 - BAND, TICK0);
        uint256 got = stock.balanceOf(alice) - before;
        assertLt(got, fair);
        assertGe(got * 10_000, fair * 9_900, "a push inside the band cost more than the band");
    }

    /// Documented, not solved: each of the five numbers is an AVERAGE, so a
    /// pool left off-market for long enough moves all of them. HELD at the
    /// target, a 150-tick push passes once the OLDEST of the five minutes is
    /// within the band of it: after 260 of the 300 seconds.
    ///
    /// This test used to say 100 seconds, and that holding was what a push
    /// cost. Both were the one-average rule, and the second was wrong even
    /// then: an average of ticks is moved by tick-seconds, so one block far
    /// past the target did what 100 seconds at it did. Holding is the SLOW
    /// way through this check, not the only one. Round6b.t.sol has the fast
    /// one, an off-market block inside each of the five minutes, which
    /// still passes (docs/threat-model.md, Residual risks).
    function test_R5_2_APushHeldAcrossBlocksEventuallyPasses() public {
        feed.set(int256(_px() * 10_090 / 10_000), block.timestamp, true);
        uint256 id = _plan(100_000e6, 10_000e6);
        vm.warp(block.timestamp + 30 days + 12 hours);

        pool.push(TICK0 - 150);
        // 100 s on, where one 300 s average let it through (it read -50).
        // The last minute is all push, the one before it two thirds, and
        // the three oldest have none of it.
        vm.warp(block.timestamp + 100);
        (, int24 low, int24 high) = aero.ticks(address(pool));
        assertEq(low, TICK0 - 150);
        assertEq(high, TICK0);
        vm.expectRevert(_pushed(TICK0 - 150, TICK0));
        vm.prank(stranger);
        vault.executeDCA(id);

        // 259 s on. The oldest minute holds 19 s of the push: 47.5 ticks of
        // average, 48 once floored, and 102 from the spot.
        vm.warp(block.timestamp + 159);
        vm.expectRevert(_pushed(TICK0 - 150, TICK0 - 48));
        vm.prank(stranger);
        vault.executeDCA(id);

        vm.warp(block.timestamp + 1); // 260 of the 300 seconds
        (, low, high) = aero.ticks(address(pool));
        assertEq(low, TICK0 - 150);
        assertEq(high, TICK0 - 50, "the oldest minute: 40 s at 0 and 20 s at -150");
        vm.prank(stranger);
        vault.executeDCA(id);
    }

    /// (d) A pool whose oldest observation is younger than the window cannot
    /// be bought from; nor can anything that has no history to give.
    function test_R5_2_APoolWithNoPriceHistoryIsRefused() public {
        TwapClPool young = new TwapClPool(address(usdc), address(stock), true, TICK0);
        vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
        direct.ticks(address(young));
        vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
        direct.swapExactIn(address(young), address(stock), 1_000e6, 0, alice);

        vm.warp(block.timestamp + direct.TWAP_WINDOW() - 1);
        vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
        direct.swapExactIn(address(young), address(stock), 1_000e6, 0, alice);

        vm.warp(block.timestamp + 1); // its first observation is exactly the window old
        (int24 spot, int24 low, int24 high) = direct.ticks(address(young));
        assertEq(spot, TICK0);
        assertEq(low, TICK0);
        assertEq(high, TICK0);
        uint256 out = direct.swapExactIn(address(young), address(stock), 1_000e6, 0, alice);
        assertEq(out, stock.balanceOf(alice));
        assertGt(out, 0);

        // A pool with no `observe` at all.
        QuotePool mute = new QuotePool(address(usdc), address(stock), uint160(1 << 96));
        vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
        direct.ticks(address(mute));
        vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
        direct.swapExactIn(address(mute), address(stock), 1_000e6, 0, alice);

        // One whose `observe` reverts.
        RawObservePool raw = new RawObservePool(address(usdc), address(stock));
        raw.set(0, new int56[](6), true);
        vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
        direct.ticks(address(raw));

        // One that answers the wrong number of cumulatives: the adapter asks
        // for six, and one short, one long, or the two it used to ask for
        // are all refused. It never reads past what it was given, and never
        // makes do with fewer minutes.
        uint256[6] memory wrong = [uint256(0), 1, 2, 5, 7, 12];
        for (uint256 i; i < wrong.length; ++i) {
            raw.set(0, new int56[](wrong[i]), false);
            vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
            direct.ticks(address(raw));
            vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
            direct.swapExactIn(address(raw), address(stock), 1_000e6, 0, alice);
        }
        // Control: with six, the same pool answers.
        raw.set(0, new int56[](6), false);
        (spot, low, high) = direct.ticks(address(raw));
        assertEq(spot, 0);
        assertEq(low, 0);
        assertEq(high, 0);
        assertEq(usdc.balanceOf(address(direct)), 0, "USDC stranded in the adapter");
    }

    /// (d) Through the vault: a deposit on a route whose pool has no history
    /// yet fails closed. Nothing is taken, and it works once the pool has it.
    function test_R5_2_ADepositOnAYoungPoolFailsClosed() public {
        MockYieldAdapter y2 = new MockYieldAdapter(usdc);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        AerodromeSwapAdapter a2 = new AerodromeSwapAdapter(IERC20(address(usdc)), predicted);
        DcaVault v2 = new DcaVault(IERC20(address(usdc)), y2, a2, cl, 10_000_000e6);
        y2.bindVault(address(v2));
        TwapClPool young = new TwapClPool(address(usdc), address(stock), true, TICK0);
        v2.initRoute(1, DcaVault.Route(address(stock), address(young), address(feed), 0, true));
        v2.finishSetup();
        vm.startPrank(alice);
        usdc.approve(address(v2), type(uint256).max);
        uint256 held = usdc.balanceOf(alice);
        vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
        v2.createPlan(1, 10_000e6, 1_000e6, 30 days);
        assertEq(usdc.balanceOf(alice), held);

        vm.warp(block.timestamp + a2.TWAP_WINDOW());
        v2.createPlan(1, 10_000e6, 1_000e6, 30 days);
        vm.stopPrank();
        assertGt(stock.balanceOf(alice), 0);
    }

    /// Six cumulatives, as `observe([300, 240, 180, 120, 60, 0])` answers
    /// them, oldest first. Minute `at` (0 is the oldest) counted `step`
    /// tick-seconds, and each of the other four counted `others`.
    function _cums(int56 base, int56 others, int56 step, uint256 at)
        internal
        pure
        returns (int56[] memory cum)
    {
        cum = new int56[](6);
        cum[0] = base;
        for (uint256 i; i < 5; ++i) {
            cum[i + 1] = cum[i] + (i == at ? step : others);
        }
    }

    /// A minute that counted `step` tick-seconds reads as the mean `want`,
    /// whichever of the five minutes it is, and whether it is the lowest of
    /// the five or the highest.
    function _expectMean(RawObservePool raw, int56 base, int56 step, int24 want) internal {
        for (uint256 at; at < 5; ++at) {
            // The other four are 7 ticks above it: it is the lowest.
            raw.set(want, _cums(base, (int56(want) + 7) * 60, step, at), false);
            (int24 spot, int24 low, int24 high) = direct.ticks(address(raw));
            assertEq(spot, want);
            assertEq(low, want, "the lowest mean");
            assertEq(high, want + 7);
            // And 7 below: it is the highest.
            raw.set(want, _cums(base, (int56(want) - 7) * 60, step, at), false);
            (, low, high) = direct.ticks(address(raw));
            assertEq(low, want - 7);
            assertEq(high, want, "the highest mean");
        }
    }

    /// (e) Each mean rounds toward negative infinity, as
    /// OracleLibrary.consult does. Truncation, which is what `/` does, is
    /// one tick too high for every negative mean that is not whole, and the
    /// real pools sit at negative ticks.
    function test_R5_2_TheMeanTickRoundsTowardNegativeInfinity() public {
        RawObservePool raw = new RawObservePool(address(usdc), address(stock));
        // 58 s at -8556 and 2 s at -8559: -513,366 tick-seconds. Over 60 s
        // that is -8556.1. Truncated: -8556. Floored: -8557.
        _expectMean(raw, 0, -513_366, -8557);
        _expectMean(raw, 0, -513_360, -8556); // a whole mean is left alone
        _expectMean(raw, 0, 513_366, 8556); // positive: truncation is the floor
        _expectMean(raw, 0, -1, -1);
        _expectMean(raw, 0, -59, -1);
        _expectMean(raw, 0, -60, -1);
        _expectMean(raw, 0, -61, -2);
        _expectMean(raw, 0, 1, 0);
        _expectMean(raw, 0, 59, 0);
        _expectMean(raw, 0, 60, 1);
        // Only the differences count. The base is the cumulative the live
        // NVDAc pool answered for five minutes ago on a quiet Sunday.
        _expectMean(raw, -205_164_318_280, -513_366, -8557);
        _expectMean(raw, -205_164_318_280, -513_360, -8556);

        // The same case through a pool's own history.
        vm.warp(block.timestamp + 10 minutes);
        pool.push(TICK0 - 3);
        vm.warp(block.timestamp + 2);
        (int24 spot, int24 low, int24 high) = aero.ticks(address(pool));
        assertEq(spot, -8559);
        assertEq(low, -8557, "the last minute: 58 s at -8556 and 2 s at -8559 is -8556.1");
        assertEq(high, -8556);
    }

    /// (e) No answer a pool can give makes the arithmetic overflow: an
    /// average that is not a tick is refused by name, never a Panic, and in
    /// whichever of the five minutes it turns up.
    function test_R5_2_NoCumulativeOverflowsTheMean() public {
        RawObservePool raw = new RawObservePool(address(usdc), address(stock));
        for (uint256 at; at < 5; ++at) {
            // The largest step two cumulatives can make, up and then down.
            int56[] memory cum = new int56[](6);
            for (uint256 i; i < 6; ++i) {
                cum[i] = i <= at ? type(int56).min : type(int56).max;
            }
            raw.set(0, cum, false);
            vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
            direct.ticks(address(raw));
            for (uint256 i; i < 6; ++i) {
                cum[i] = i <= at ? type(int56).max : type(int56).min;
            }
            raw.set(0, cum, false);
            vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
            direct.ticks(address(raw));

            // One tick-second past the range, either way, is not a tick...
            raw.set(0, _cums(0, 0, (int56(type(int24).max) + 1) * 60, at), false);
            vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
            direct.ticks(address(raw));
            raw.set(0, _cums(0, 0, int56(type(int24).min) * 60 - 1, at), false);
            vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
            direct.ticks(address(raw));
            vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
            direct.swapExactIn(address(raw), address(stock), 1e6, 0, alice);
            // ...and the last tick-second inside it is.
            raw.set(0, _cums(0, 0, int56(type(int24).max) * 60 + 59, at), false);
            (, int24 lo, int24 hi) = direct.ticks(address(raw));
            assertEq(lo, 0);
            assertEq(hi, type(int24).max);
            raw.set(0, _cums(0, 0, int56(type(int24).min) * 60, at), false);
            (, lo, hi) = direct.ticks(address(raw));
            assertEq(lo, type(int24).min);
            assertEq(hi, 0);
        }

        // The widest drift there is, the spot and all five averages at
        // opposite ends of int24, is a push like any other.
        int56 top = int56(type(int24).max) * 60;
        raw.set(type(int24).min, _cums(0, top, top, 0), false);
        (int24 spot, int24 low, int24 high) = direct.ticks(address(raw));
        assertEq(spot, type(int24).min);
        assertEq(low, type(int24).max);
        assertEq(high, type(int24).max);
        vm.expectRevert(_pushed(type(int24).min, type(int24).max));
        direct.swapExactIn(address(raw), address(stock), 1e6, 0, alice);
        int56 bottom = int56(type(int24).min) * 60;
        raw.set(type(int24).max, _cums(0, bottom, bottom, 0), false);
        vm.expectRevert(_pushed(type(int24).max, type(int24).min));
        direct.swapExactIn(address(raw), address(stock), 1e6, 0, alice);
        assertEq(usdc.balanceOf(address(direct)), 0, "USDC stranded in the adapter");
    }

    /// (e) Whatever six cumulatives a pool answers: each of the five means
    /// is the floor, `ticks()` answers the lowest and the highest of them,
    /// and the swap is refused exactly when the spot is more than the band
    /// from either, naming the one it is further from.
    function testFuzz_R5_2_TheMeanTickIsTheFloor(
        int56 base,
        int56[5] memory steps,
        int24 spot,
        bool near
    ) public {
        RawObservePool raw = new RawObservePool(address(usdc), address(stock));
        int56[] memory cum = new int56[](6);
        cum[0] = int56(bound(base, -1e15, 1e15));
        int256 lo = type(int256).max;
        int256 hi = type(int256).min;
        for (uint256 i; i < 5; ++i) {
            // Near the spot, where the band decides; or anywhere a tick can
            // be, and a little past (int24's end is 503,316,420 tick-seconds).
            int256 s = near
                ? int256(spot) * 60 + bound(steps[i], -15_000, 15_000)
                : bound(steps[i], -520_000_000, 520_000_000);
            cum[i + 1] = cum[i] + int56(s);
            // The floor, written the other way round from the adapter.
            int256 floor = s >= 0 ? s / 60 : -((-s + 59) / 60);
            if (floor < lo) lo = floor;
            if (floor > hi) hi = floor;
        }
        raw.set(spot, cum, false);
        if (lo < type(int24).min || hi > type(int24).max) {
            vm.expectRevert(AerodromeSwapAdapter.NoPriceHistory.selector);
            direct.ticks(address(raw));
            return;
        }
        (int24 s0, int24 low, int24 high) = direct.ticks(address(raw));
        assertEq(s0, spot);
        assertEq(int256(low), lo);
        assertEq(int256(high), hi);
        int256 above = int256(spot) - lo;
        int256 below = hi - int256(spot);
        if (above > BAND || below > BAND) {
            vm.expectRevert(_pushed(spot, int24(above >= below ? lo : hi)));
            direct.swapExactIn(address(raw), address(stock), 1e6, 0, alice);
        } else {
            // Inside the band the check lets the buy through to the pool,
            // and this pool has no `swap`: it dies there, not on the check.
            try direct.swapExactIn(address(raw), address(stock), 1e6, 0, alice) {
                fail("a pool with no swap filled");
            } catch (bytes memory err) {
                assertTrue(
                    err.length < 4 || bytes4(err) != AerodromeSwapAdapter.PoolPushed.selector,
                    "refused inside the band"
                );
            }
        }
    }

    /// (f) The band's exact edges, both directions: 100 ticks passes, 101
    /// does not.
    function test_R5_2_TheBandsExactEdges() public {
        assertEq(direct.MAX_TWAP_DRIFT(), BAND);
        assertEq(direct.TWAP_WINDOW(), 300);
        assertEq(direct.TWAP_STEP(), 60);

        pool.push(TICK0 + BAND);
        direct.swapExactIn(address(pool), address(stock), 1_000e6, 0, alice);
        pool.push(TICK0 + BAND + 1);
        vm.expectRevert(_pushed(TICK0 + BAND + 1, TICK0));
        direct.swapExactIn(address(pool), address(stock), 1_000e6, 0, alice);

        pool.push(TICK0 - BAND);
        direct.swapExactIn(address(pool), address(stock), 1_000e6, 0, alice);
        pool.push(TICK0 - BAND - 1);
        vm.expectRevert(_pushed(TICK0 - BAND - 1, TICK0));
        direct.swapExactIn(address(pool), address(stock), 1_000e6, 0, alice);
        assertEq(usdc.balanceOf(address(direct)), 0, "USDC stranded in the adapter");
    }

    /// (f) And everywhere else, on either token order.
    function testFuzz_R5_2_APushIsRefusedExactlyPastTheBand(int24 t0, int24 by, bool usdcIsToken0)
        public
    {
        t0 = int24(bound(t0, -60_000, 60_000));
        by = int24(bound(by, -2_000, 2_000));
        TwapClPool p = new TwapClPool(address(usdc), address(stock), usdcIsToken0, t0);
        vm.warp(block.timestamp + 1 hours);
        p.push(t0 + by);
        (int24 spot, int24 low, int24 high) = direct.ticks(address(p));
        assertEq(spot, t0 + by);
        assertEq(low, t0);
        assertEq(high, t0);
        if (by > BAND || by < -BAND) vm.expectRevert(_pushed(t0 + by, t0));
        direct.swapExactIn(address(p), address(stock), 1_000e6, 0, alice);
    }

    // ============================================= R5-5: no dust last period
    /// Before: a deposit that did not divide left a last period as small as
    /// 2 wei, a plan the cap barely counts and a buy of nothing. 300 of them
    /// fitted under a $5,000 cap.
    function test_R5_5_ADustFinalPeriodIsRefused() public {
        vm.startPrank(alice);
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.createPlan(1, 10e6 + 2, 10e6, 30 days); // a 2-wei tail
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.createPlan(1, 3e6 - 1, 2e6, 30 days); // one wei under the minimum
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.createPlan(1, 2_500_000, 1e6, 30 days); // half a dollar

        // A tail of exactly the minimum is a period like any other...
        uint256 id = vault.createPlan(1, 3e6, 2e6, 30 days);
        vm.warp(block.timestamp + 30 days);
        feed.set(int256(_px()), block.timestamp, true);
        uint256 before = stock.balanceOf(alice);
        vault.executeDCA(id);
        vm.stopPrank();
        assertApproxEqRel(
            stock.balanceOf(alice) - before, uint256(1e6) * 1e10 / _px(), 1e12, "the last buy"
        );
        (,,, uint256 rem,,,, uint32 done, bool active) = vault.plans(id);
        assertEq(rem, 0);
        assertEq(done, 2);
        assertFalse(active);
        // ...and a deposit that divides has no tail to judge.
        vm.prank(alice);
        vault.createPlan(1, 4e6, 2e6, 30 days);
    }

    function testFuzz_R5_5_TheLastPeriodIsNeverDust(uint256 dep, uint256 inst) public {
        dep = bound(dep, 1e6, 1_000_000e6);
        inst = bound(inst, 1e6, dep);
        uint256 tail = dep % inst;
        bool dust = tail != 0 && tail < 1e6;
        bool tooMany = (dep + inst - 1) / inst > 120;
        vm.prank(alice);
        if (dust || tooMany) vm.expectRevert(DcaVault.BadParams.selector);
        vault.createPlan(1, dep, inst, 30 days);
    }

    // ================================================= R5-8: zero shares
    /// Before: a supply that minted no shares was accepted, and the plan held
    /// a claim on nothing for the USDC it had just paid in.
    function test_R5_8_ASupplyThatMintsNoSharesReverts() public {
        y.setSharePrice(1e40); // every deposit rounds down to zero shares
        uint256 held = usdc.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(DcaVault.ZeroShares.selector);
        vault.createPlan(1, 10_000e6, 1_000e6, 30 days);
        assertEq(usdc.balanceOf(alice), held, "the deposit was taken");
        assertEq(vault.totalPrincipal(), 0);
        assertEq(vault.nextPlanId(), 1);

        y.setSharePrice(1e18);
        _plan(10_000e6, 1_000e6);
    }

    // ============================================== R5-9: the fee recipient
    /// Before: the vault's own address was accepted, and fees claimed to it
    /// could never leave. The same goes for either adapter.
    function test_R5_9_TheFeeRecipientCannotBeTheVaultOrItsAdapters() public {
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.setFeeRecipient(address(vault));
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.setFeeRecipient(address(y));
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.setFeeRecipient(address(aero));
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.setFeeRecipient(address(0));
        assertEq(vault.feeRecipient(), address(this));
        vault.setFeeRecipient(alice);
        assertEq(vault.feeRecipient(), alice);
    }

    // ================================================ R5-6: the sequencer
    /// Before: there was no check. After an outage the last print read fresh
    /// until the next one landed, and a buy could execute against it.
    function test_R5_6_NothingIsFreshWhileTheSequencerIsDownOrJustBack() public {
        assertEq(cl.sequencerUptimeFeed(), address(uptime));
        assertEq(cl.SEQUENCER_GRACE(), 1 hours);
        assertTrue(cl.isFresh(address(stock)), "up for a month");

        // Down.
        uptime.set(1, block.timestamp - 10 minutes, false);
        assertFalse(cl.isFresh(address(stock)), "fresh while the sequencer is down");
        // Any answer but 0 is down.
        uptime.set(2, block.timestamp - 30 days, false);
        assertFalse(cl.isFresh(address(stock)));
        uptime.set(-1, block.timestamp - 30 days, false);
        assertFalse(cl.isFresh(address(stock)));

        // Back up, and inside the grace.
        uint256 restart = block.timestamp;
        uptime.set(0, restart, false);
        assertFalse(cl.isFresh(address(stock)), "fresh in the block the sequencer came back");
        vm.warp(restart + 1 hours - 1);
        assertFalse(cl.isFresh(address(stock)), "fresh one second inside the grace");
        // Up long enough.
        vm.warp(restart + 1 hours);
        assertTrue(cl.isFresh(address(stock)), "still not fresh after the grace");

        // A restart time in the future is "just restarted", not an underflow.
        uptime.set(0, block.timestamp + 1, false);
        assertFalse(cl.isFresh(address(stock)));
        uptime.set(0, type(uint256).max, false);
        assertFalse(cl.isFresh(address(stock)));

        // The price itself is not withheld: only its freshness.
        (uint256 px,) = cl.latestPrice(address(stock));
        assertEq(px, _px());
    }

    /// Through the vault: during an outage's aftermath a deposit opens the
    /// plan with no first buy, an execution waits, and both resume after the
    /// grace. Exits never ask.
    function test_R5_6_NoBuyInTheGraceAfterARestart() public {
        uint256 id = _plan(10_000e6, 1_000e6);
        vm.warp(block.timestamp + 30 days);
        uptime.set(0, block.timestamp - 5 minutes, false); // back five minutes ago

        vm.prank(alice);
        vm.expectRevert(DcaVault.StaleOracle.selector);
        vault.executeDCA(id);
        uint256 held = stock.balanceOf(alice);
        uint256 id2 = _plan(5_000e6, 1_000e6);
        assertEq(stock.balanceOf(alice), held, "a deposit bought in the grace");
        (,,, uint256 rem,,,, uint32 done,) = vault.plans(id2);
        assertEq(rem, 5_000e6);
        assertEq(done, 0);
        vm.prank(alice);
        vault.exitPlan(id2);

        vm.warp(block.timestamp + 55 minutes);
        vm.prank(alice);
        vault.executeDCA(id);
        assertGt(stock.balanceOf(alice), held);
    }

    function _withUptime(address up) internal returns (ChainlinkOracle o) {
        o = new ChainlinkOracle(up, false);
        o.setFeed(address(stock), address(feed));
    }

    /// FAILS OPEN, on purpose: an uptime feed that cannot be read is ignored,
    /// so a feed Chainlink deprecates cannot halt every buy for good.
    function test_R5_6_AnUnreadableUptimeFeedIsIgnored() public {
        // No check at all (local and test chains).
        assertTrue(_withUptime(address(0)).isFresh(address(stock)));
        // No code at the address.
        assertTrue(_withUptime(address(0xDEAD)).isFresh(address(stock)));

        RawFeed raw = new RawFeed();
        ChainlinkOracle o = _withUptime(address(raw));
        bytes memory up =
            abi.encode(uint80(1), int256(0), block.timestamp - 30 days, block.timestamp, uint80(1));
        raw.set(up, 0);
        assertTrue(o.isFresh(address(stock)), "control: a readable feed that says up");

        raw.set(up, 1); // reverts
        assertTrue(o.isFresh(address(stock)));
        raw.set("", 0); // answers nothing
        assertTrue(o.isFresh(address(stock)));
        bytes memory short = new bytes(159); // one byte short of five words
        raw.set(short, 0);
        assertTrue(o.isFresh(address(stock)));
        raw.set("", 3); // reverts with as much data as its gas allows
        assertTrue(o.isFresh(address(stock)));
        raw.set("", 4); // burns all the gas it is given
        uint256 g = gasleft();
        assertTrue(o.isFresh(address(stock)));
        assertLt(g - gasleft(), 250_000, "the uptime read is not bounded");
    }

    /// Readable garbage is not "unreadable": an answer that is not 0 is down.
    function test_R5_6_GarbageFromTheUptimeFeedReadsAsDown() public {
        RawFeed raw = new RawFeed();
        ChainlinkOracle o = _withUptime(address(raw));
        bytes memory ones = new bytes(160);
        for (uint256 i; i < 160; ++i) {
            ones[i] = 0xff;
        }
        raw.set(ones, 0);
        assertFalse(o.isFresh(address(stock)));
        // A megabyte with a price feed's prefix (answer 1e8): down, and cheap.
        raw.set("", 2);
        uint256 g = gasleft();
        assertFalse(o.isFresh(address(stock)));
        assertLt(g - gasleft(), 250_000, "the uptime read copied the bomb");
        // All zeroes: answer 0 and a restart at time 0, which is long ago.
        raw.set(new bytes(160), 0);
        assertTrue(o.isFresh(address(stock)));
        // More than five words: only the first five are read.
        raw.set(
            abi.encode(
                uint80(1), int256(0), block.timestamp - 2 hours, block.timestamp, uint80(1), 7, 7
            ),
            0
        );
        assertTrue(o.isFresh(address(stock)));
    }

    /// The rule, written out: an uptime feed that cannot be read (it reverts,
    /// or answers fewer than five words) passes; one that can must say "up,
    /// and for at least the grace".
    function _ruleSays(bytes calldata upRaw, uint8 upMode) internal view returns (bool) {
        if (upMode == 2) return false; // the bomb's prefix answers 1e8
        if (upMode != 0 || upRaw.length < 160) return true;
        (, int256 answer, uint256 startedAt,,) =
            abi.decode(upRaw[:160], (uint256, int256, uint256, uint256, uint256));
        return answer == 0 && startedAt <= block.timestamp && block.timestamp - startedAt >= 1 hours;
    }

    /// `isFresh` never reverts, whatever either feed answers, and what it
    /// answers is exactly the rule.
    function testFuzz_R5_6_IsFreshNeverRevertsAndFollowsTheRule(
        bytes calldata upRaw,
        uint8 upMode,
        bytes calldata priceRaw,
        uint8 priceMode,
        bool priceGood
    ) public {
        upMode = upMode % 5;
        RawFeed up = new RawFeed();
        up.set(upRaw, upMode);
        RawFeed price = new RawFeed();
        price.set(priceRaw, priceMode % 5);
        if (priceGood) {
            price.set(
                abi.encode(uint80(1), int256(100e8), block.timestamp, block.timestamp, uint80(1)), 0
            );
        }
        ChainlinkOracle o = new ChainlinkOracle(address(up), false);
        o.setFeed(address(stock), address(price));

        uint256 g = gasleft();
        (bool ok, bytes memory ret) =
            address(o).staticcall(abi.encodeCall(ChainlinkOracle.isFresh, (address(stock))));
        assertLt(g - gasleft(), 450_000, "isFresh is not bounded");
        assertTrue(ok, "isFresh reverted");
        // With a bad price feed the answer is round 3's business (F3).
        if (priceGood) assertEq(abi.decode(ret, (bool)), _ruleSays(upRaw, upMode));
    }
}
