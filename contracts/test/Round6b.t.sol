// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle} from "../src/adapters/ChainlinkOracle.sol";
import {AerodromeSwapAdapter, ICLPool} from "../src/adapters/AerodromeSwapAdapter.sol";
import {MockERC20, MockStock, MockYieldAdapter} from "../src/mocks/Mocks.sol";
import {TwapClPool, FakeFeed} from "./utils/HostileVenues.sol";
import {RawFeed} from "./Round3.t.sol";
import {Pusher} from "./Round6.t.sol";

/// @notice The hardening plan, ROUND 6b (docs/hardening-plan.md): what the
///         review of round 6 found, and the three changes that answered it.
///
///         1. THE PUSH CHECK. Round 6 held the pool's spot to ONE 300-second
///            mean tick. A mean of ticks is moved by tick-seconds, so one
///            block far enough off-market moved it as far as five minutes
///            at the target did, and a stranger could again make a plan buy
///            at a stale print. The adapter now holds the spot to each of
///            FIVE 60-second means.
///         2. THE WEEKEND. The equity feeds stop from Friday's close to
///            Monday's open and the pools do not. The mainnet oracle is now
///            built `closedOnWeekends`: nothing is fresh from Saturday
///            00:00 UTC to Monday 01:00 UTC.
///         3. THE FEE RECIPIENT cannot be the vault's oracle either.
///
/// @dev    Real AerodromeSwapAdapter, real ChainlinkOracle, real vault, on
///         a mock pool whose price oracle behaves like a v3 pool's
///         (TwapClPool; Fork.t.sol runs the push and the one-block
///         excursion on the real pool's code). Every test here was checked
///         by mutation: it fails when the line it pins is taken out or
///         changed.
///
///         Two vaults are built. `vault` prices off an oracle WITHOUT the
///         weekend rule, as every earlier test's does, so that the push
///         tests mean the same thing whatever day their clock lands on.
///         `wvault` prices off one WITH it, as mainnet's does.
contract Round6bTest is Test {
    MockERC20 usdc;
    MockStock stock;
    FakeFeed feed;
    FakeFeed uptime;
    TwapClPool pool;

    ChainlinkOracle cl; // no weekend rule
    AerodromeSwapAdapter aero; // bound to `vault`
    DcaVault vault;
    ChainlinkOracle wcl; // closed on weekends, like mainnet's
    DcaVault wvault;
    AerodromeSwapAdapter direct; // bound to this test, to call the adapter alone

    address alice = address(0xA11CE);
    address stranger = address(0xBAD);

    /// Where the real NVDAc pool sat when round 6 was written: USDC is
    /// token0, so the tick is negative, and a HIGHER share price is a LOWER
    /// tick.
    int24 constant TICK0 = -8556;
    int24 constant BAND = 100;
    /// Where the pool trades in the stale-print tests: 600 ticks (5.8%)
    /// cheaper than the feed's last print, which was made at TICK0.
    int24 constant MARKET = TICK0 + 600;

    // The calendar, UTC. Each was checked against one (`date -u -r <n>`).
    uint256 constant FRI_23_59_59 = 1790985599; // Fri 2026-10-02 23:59:59
    uint256 constant SAT = 1790985600; // Sat 2026-10-03 00:00:00
    uint256 constant SUN_NOON = 1791115200; // Sun 2026-10-04 12:00:00
    uint256 constant MON_00_59_59 = 1791161999; // Mon 2026-10-05 00:59:59
    uint256 constant MON_01_00 = 1791162000; // Mon 2026-10-05 01:00:00
    uint256 constant WED_15_00 = 1791385200; // Wed 2026-10-07 15:00:00
    uint256 constant WINTER_SAT = 1798848000; // Sat 2027-01-02 00:00:00
    uint256 constant LEAP_SAT = 1835740800; // Sat 2028-03-04 00:00:00, after 29 Feb

    function setUp() public {
        vm.warp(1_780_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("Mock NVDAc", "NVDAc");
        // The sequencer has been up since long before any date used here.
        uptime = new FakeFeed();
        uptime.set(0, 1, false);
        direct = new AerodromeSwapAdapter(IERC20(address(usdc)), address(this));

        pool = new TwapClPool(address(usdc), address(stock), true, TICK0);
        vm.warp(block.timestamp + 1 hours); // a pool with history
        feed = new FakeFeed();
        feed.set(int256(_px()), block.timestamp, true);

        (cl, aero, vault) = _stack(false);
        (wcl,, wvault) = _stack(true);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(direct), type(uint256).max);
    }

    /// A vault of its own on the shared pool and feed, with an oracle built
    /// with or without the weekend rule.
    function _stack(bool closedOnWeekends)
        internal
        returns (ChainlinkOracle o, AerodromeSwapAdapter a, DcaVault v)
    {
        MockYieldAdapter y = new MockYieldAdapter(usdc);
        o = new ChainlinkOracle(address(uptime), closedOnWeekends);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        a = new AerodromeSwapAdapter(IERC20(address(usdc)), predicted);
        v = new DcaVault(IERC20(address(usdc)), y, a, o, 10_000_000e6);
        assertEq(address(v), predicted);
        y.bindVault(address(v));
        o.setFeed(address(stock), address(feed));
        v.initRoute(1, DcaVault.Route(address(stock), address(pool), address(feed), 0, true));
        v.finishSetup();
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
    }

    // ------------------------------------------------------------ helpers
    /// The pool's spot price, 8 decimals, as the vault's breaker reads it.
    function _px() internal view returns (uint256) {
        return direct.poolPrice(address(pool), address(stock));
    }

    /// `furthest` is the one-minute mean the spot is furthest from.
    function _pushed(int24 spot, int24 furthest) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(AerodromeSwapAdapter.PoolPushed.selector, spot, furthest);
    }

    function _plan(DcaVault v, uint256 deposit, uint256 installment, uint64 interval)
        internal
        returns (uint256 id)
    {
        vm.prank(alice);
        id = v.createPlan(1, deposit, installment, interval);
    }

    /// floor(a / b) for b > 0: the largest q with q * b <= a. Written as a
    /// search, not the way the adapter writes it.
    function _floor(int256 a, int256 b) internal pure returns (int256 q) {
        q = a / b;
        while (q * b > a) --q;
    }

    /// A buy through the adapter alone, at the pool as it stands.
    function _buyPasses() internal {
        uint256 had = stock.balanceOf(alice);
        uint256 out = direct.swapExactIn(address(pool), address(stock), 1_000e6, 0, alice);
        assertGt(out, 0);
        assertEq(stock.balanceOf(alice) - had, out);
    }

    function _buyRefused(int24 spot, int24 furthest) internal {
        vm.expectRevert(_pushed(spot, furthest));
        direct.swapExactIn(address(pool), address(stock), 1_000e6, 0, alice);
    }

    /// What the adapter reads with the pool pushed to `to` in this block.
    /// The pool is put back where it was: a push and its undoing inside one
    /// block change nothing the pool's history records.
    function _ticksAt(int24 to) internal returns (int24 low, int24 high) {
        int24 was = pool.tick();
        pool.push(to);
        int24 spot;
        (spot, low, high) = aero.ticks(address(pool));
        assertEq(spot, to);
        pool.push(was);
    }

    /// R5-2's setting (Round6.test_R5_2_AFrozenFeedAndAPushedPoolNoLongerPays).
    /// The feed's last print is 20 hours old and still reads fresh. The
    /// market has fallen 600 ticks (5.8%) since. The plan's buy is 12 hours
    /// overdue, so anyone may send it. Left alone it waits: the pool is
    /// outside the breaker.
    function _stalePrint() internal returns (uint256 id, uint256 print, uint256 honestPx) {
        id = _plan(vault, 100_000e6, 10_000e6, 30 days);
        print = _px();
        vm.warp(block.timestamp + 30 days - 8 hours);
        feed.set(int256(print), block.timestamp, false); // the last print, then nothing
        vm.warp(block.timestamp + 2 hours);
        pool.push(MARKET); // the market moves on without the feed
        vm.warp(block.timestamp + 18 hours); // 12 hours overdue
        assertTrue(cl.isFresh(address(stock)), "a 20-hour-old print reads fresh");
        honestPx = _px();
        vm.expectRevert(abi.encodeWithSelector(DcaVault.PoolDiverged.selector, print, honestPx));
        vm.prank(stranger);
        vault.executeDCA(id);
    }

    /// The attacker's part of the next five minutes. In each minute `mask`
    /// names (bit 0 is the oldest) the pool is left at `market + by` for
    /// ONE 2-second block, 10 seconds into the minute, and then put back.
    /// Ends 300 s after it starts, in the block the buy is tried in.
    ///
    /// Two seconds of a minute's sixty move its average by `by / 30`.
    function _excursions(int24 market, int24 by, uint8 mask) internal {
        uint256 t0 = block.timestamp;
        for (uint256 k; k < 5; ++k) {
            if (mask & (1 << k) == 0) continue;
            vm.warp(t0 + 60 * k + 10);
            pool.push(market + by);
            vm.warp(t0 + 60 * k + 12);
            pool.push(market);
        }
        vm.warp(t0 + 300);
    }

    // ================================================== 1. the push check
    /// THE FINDING. Same setting as R5-2, and one more step: a block
    /// earlier, the stranger leaves the pool 90,000 ticks past its market.
    /// Two seconds of that are 180,000 tick-seconds, which is 600 ticks of
    /// a 300-second average: exactly the distance to the stale print.
    ///
    /// Before (round 6): the average read the print, the spot at the print
    /// was no drift at all, and the plan bought 5.8% short. Both reviewers
    /// ran a version of it.
    function test_R6b_OneBlockAtAnExtremeTickNoLongerPasses() public {
        (uint256 id,,) = _stalePrint();
        Pusher s = new Pusher();
        uint256 before = stock.balanceOf(alice);

        // Block N: one block, far past the print.
        pool.push(MARKET - 90_000);
        // Block N+1, two seconds later: push to the print, execute, unwind.
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 1);

        // CONTROL: this sequence is the hole. The one number round 6
        // compared the spot with, redone here from the pool's own
        // cumulatives, sits exactly on the print. A spot pushed to the
        // print was zero ticks from it, and the check passed.
        {
            uint32[] memory ago = new uint32[](2);
            ago[0] = 300;
            (int56[] memory c,) = pool.observe(ago);
            int256 tickSeconds = int256(c[1]) - int256(c[0]);
            assertEq(tickSeconds, 298 * int256(MARKET) + 2 * (int256(MARKET) - 90_000));
            assertEq(
                _floor(tickSeconds, 300),
                TICK0,
                "one block did not carry the 300 s mean to the print"
            );
        }

        // Now: the same block is 3,000 ticks of the last minute's average
        // and nothing of the four before it. The spot at the print is 2,400
        // from one and 600 from the others.
        vm.expectRevert(_pushed(TICK0, TICK0 - 2_400));
        vm.prank(stranger);
        s.run(vault, pool, id, TICK0, MARKET);
        assertEq(stock.balanceOf(alice), before, "the plan bought at the stale print");
        (int24 low, int24 high) = _ticksAt(TICK0);
        assertEq(low, MARKET - 3_000, "the minute with the block in it");
        assertEq(high, MARKET, "the four minutes before it");

        // And it does not come good with time. The stranger gives up the
        // block and tries the strike in every block of the next five
        // minutes: while that one block is anywhere in the window at least
        // three of the five minutes have none of it.
        pool.push(MARKET);
        for (uint256 t = 2; t < 300; t += 2) {
            vm.warp(block.timestamp + 2);
            vm.expectPartialRevert(AerodromeSwapAdapter.PoolPushed.selector);
            vm.prank(stranger);
            s.run(vault, pool, id, TICK0, MARKET);
        }
        // Once it has left the window this is R5-2 again, as refused as it
        // was in round 6.
        vm.warp(block.timestamp + 2);
        vm.expectRevert(_pushed(TICK0, MARKET));
        vm.prank(stranger);
        s.run(vault, pool, id, TICK0, MARKET);

        assertEq(stock.balanceOf(alice), before, "the plan bought at the stale print");
        (,,, uint256 rem,,,, uint32 done,) = vault.plans(id);
        assertEq(rem, 90_000e6);
        assertEq(done, 1);
    }

    /// Reaching four of the five minutes is not enough, whichever one is
    /// missed. Each excursion is sized to bring its minute exactly to the
    /// edge of the band: 15,000 ticks for one block is 500 ticks of that
    /// minute's average, from 600 off the print to 100.
    function test_R6b_AnExcursionInFourOfTheFiveMinutesIsRefused() public {
        (uint256 id,,) = _stalePrint();
        Pusher s = new Pusher();
        uint256 before = stock.balanceOf(alice);
        uint256 start = vm.snapshotState();

        for (uint256 missed; missed < 5; ++missed) {
            vm.revertToState(start);
            _excursions(MARKET, -15_000, uint8(0x1f ^ (1 << missed)));

            (int24 low, int24 high) = _ticksAt(TICK0);
            assertEq(low, TICK0 + BAND, "the four minutes the attacker reached");
            assertEq(high, MARKET, "the one it did not");
            vm.expectRevert(_pushed(TICK0, MARKET));
            vm.prank(stranger);
            s.run(vault, pool, id, TICK0, MARKET);
            assertEq(stock.balanceOf(alice), before, "the plan bought at the stale print");
        }
    }

    /// THIS TEST DOCUMENTS A LIMIT. It passes because the attack works.
    ///
    /// The check is against five AVERAGES, and an average of ticks is moved
    /// by tick-seconds. An attacker who leaves the pool off-market for one
    /// block inside EACH of the five minutes moves all five, and the same
    /// stale print is bought at after all: the plan gets 5.8% less stock
    /// than the pool's own price would have given it. Nothing in the
    /// adapter stops this, and nothing in this test should be read as
    /// saying otherwise.
    ///
    /// What round 6b changed is what it takes. Not one block but five, the
    /// first of them more than four minutes before the buy, and each one
    /// leaves the attacker's capital in the pool across a block boundary
    /// where anyone may trade against it. A push left standing across the
    /// boundary between two minutes counts in both, so THREE pushes are
    /// enough; the pool is still off-market for five blocks. The mock's
    /// pushes are free, which is the attacker's best case, not a
    /// measurement. What bounds the loss when it happens is `minOut`,
    /// taken from the feed, and the breaker (docs/threat-model.md,
    /// Residual risks).
    function test_R6b_AnExcursionInEveryMinuteStillPasses() public {
        (uint256 id, uint256 print, uint256 honestPx) = _stalePrint();
        Pusher s = new Pusher();
        uint256 before = stock.balanceOf(alice);
        uint256 honest = uint256(10_000e6) * 1e10 / honestPx;
        uint256 start = vm.snapshotState();

        // FIVE PUSHES, one block inside each minute, each just large enough.
        _excursions(MARKET, -15_000, 0x1f);
        (int24 low, int24 high) = _ticksAt(TICK0);
        assertEq(low, TICK0 + BAND);
        assertEq(high, TICK0 + BAND, "every minute is at the edge of the band");
        vm.prank(stranger);
        s.run(vault, pool, id, TICK0, MARKET);
        _assertBoughtAtThePrint(before, print, honest);

        // "Just large enough" is exact: one tick of average less in every
        // minute (14,970 ticks for the block) and the buy is refused.
        vm.revertToState(start);
        _excursions(MARKET, -14_970, 0x1f);
        vm.expectRevert(_pushed(TICK0, TICK0 + BAND + 1));
        vm.prank(stranger);
        s.run(vault, pool, id, TICK0, MARKET);
        assertEq(stock.balanceOf(alice), before);

        // THREE PUSHES. Two are left standing for two blocks, across the
        // boundary between minutes 0 and 1 and the one between 2 and 3, so
        // each counts two seconds in both. The third is the block before
        // the buy, and the attacker strikes straight from it.
        vm.revertToState(start);
        uint256 t0 = block.timestamp;
        int24 off = MARKET - 15_000;
        vm.warp(t0 + 58);
        pool.push(off);
        vm.warp(t0 + 62);
        pool.push(MARKET);
        vm.warp(t0 + 178);
        pool.push(off);
        vm.warp(t0 + 182);
        pool.push(MARKET);
        vm.warp(t0 + 298);
        pool.push(off);
        vm.warp(t0 + 300);
        // Three pushes, and still ten seconds off-market: five blocks.
        (low, high) = _ticksAt(TICK0);
        assertEq(low, TICK0 + BAND);
        assertEq(high, TICK0 + BAND);
        vm.prank(stranger);
        s.run(vault, pool, id, TICK0, MARKET);
        _assertBoughtAtThePrint(before, print, honest);
    }

    /// The plan paid the stale print's price: 1.0001^600 is 1.0618, so it
    /// got 5.8% less stock than the pool's honest price would have bought.
    function _assertBoughtAtThePrint(uint256 before, uint256 print, uint256 honest) internal view {
        uint256 got = stock.balanceOf(alice) - before;
        assertApproxEqRel(got, uint256(10_000e6) * 1e10 / print, 1e12, "not filled at the print");
        assertLt(got * 10_000, honest * 9_450, "the shortfall");
        assertEq((honest - got) * 10_000 / honest, 582, "the shortfall, in bps of an honest fill");
    }

    /// History in which minute `k`'s average (0 is the oldest) is `off`
    /// ticks from the other four, which are TICK0: one 2-second block at
    /// 30 times `off`. Ends in the block a buy is tried in.
    function _oneMinuteOff(uint256 k, int24 off) internal {
        pool.push(TICK0);
        vm.warp(block.timestamp + 1 hours);
        _excursions(TICK0, 30 * off, uint8(1 << k));
    }

    /// The band's exact edges, both directions, with the furthest average
    /// in each of the five minutes in turn: 100 ticks from it passes and
    /// 101 does not, whichever minute it is. On a tie the error names the
    /// LOWER of the two averages.
    function test_R6b_TheBandHoldsAgainstEveryMinute() public {
        for (uint256 k; k < 5; ++k) {
            // Minute k is the LOWEST average, 50 under the other four.
            _oneMinuteOff(k, -50);
            pool.push(TICK0 + 50); // 100 over it
            _buyPasses();
            pool.push(TICK0 + 51); // 101 over it, and 51 from the rest
            _buyRefused(TICK0 + 51, TICK0 - 50);

            // Minute k is the HIGHEST, 50 over the other four.
            _oneMinuteOff(k, 50);
            pool.push(TICK0 - 50);
            _buyPasses();
            pool.push(TICK0 - 51);
            _buyRefused(TICK0 - 51, TICK0 + 50);

            // Both edges at once. Minute k is 200 under the rest, and one
            // spot is within 100 of all five. A tick either side of it is
            // refused, for a different average each way.
            _oneMinuteOff(k, -200);
            pool.push(TICK0 - 100);
            _buyPasses();
            pool.push(TICK0 - 99);
            _buyRefused(TICK0 - 99, TICK0 - 200); // 101 over the lowest
            pool.push(TICK0 - 101);
            _buyRefused(TICK0 - 101, TICK0); // 101 under the highest

            // The tie: the averages 202 apart and the spot midway, 101 from
            // each. The lower one is named, whichever minute it is in.
            _oneMinuteOff(k, -202);
            pool.push(TICK0 - 101);
            _buyRefused(TICK0 - 101, TICK0 - 202);
            _oneMinuteOff(k, 202);
            pool.push(TICK0 + 101);
            _buyRefused(TICK0 + 101, TICK0);
            // One tick off the tie, either way, names the further one.
            pool.push(TICK0 + 102);
            _buyRefused(TICK0 + 102, TICK0);
            pool.push(TICK0 + 100);
            _buyRefused(TICK0 + 100, TICK0 + 202);
        }
        assertEq(usdc.balanceOf(address(direct)), 0, "USDC stranded in the adapter");
    }

    /// The read itself: six instants a minute apart, the oldest first.
    /// scripts/verify-base-addresses.mjs and scripts/rehearse-mainnet.sh
    /// repeat these numbers.
    function test_R6b_TheReadIsSixInstantsAMinuteApart() public {
        assertEq(direct.TWAP_WINDOW(), 300);
        assertEq(direct.TWAP_STEP(), 60);
        assertEq(direct.MAX_TWAP_DRIFT(), BAND);
        uint32[] memory ago = new uint32[](6);
        (ago[0], ago[1], ago[2], ago[3], ago[4], ago[5]) = (300, 240, 180, 120, 60, 0);
        vm.expectCall(address(pool), abi.encodeCall(ICLPool.observe, (ago)));
        direct.ticks(address(pool));
        vm.expectCall(address(pool), abi.encodeCall(ICLPool.observe, (ago)));
        direct.swapExactIn(address(pool), address(stock), 1_000e6, 0, alice);
    }

    // ------------------------------------------- the rule, against a model
    /// The tick the pool held for the second starting at `s`, from its raw
    /// observations: between two of them the tick is their difference in
    /// tick-seconds over their difference in seconds, and after the last
    /// one it is the tick the pool is at.
    function _tickDuring(uint256[] memory ts, int256[] memory cum, int256 tickNow, uint256 s)
        internal
        pure
        returns (int256)
    {
        uint256 n = ts.length;
        if (s >= ts[n - 1]) return tickNow;
        for (uint256 i = n - 1; i > 0; --i) {
            if (ts[i - 1] <= s) return (cum[i] - cum[i - 1]) / int256(ts[i] - ts[i - 1]);
        }
        revert("model: before the pool's first observation");
    }

    /// THE REFERENCE MODEL. The five one-minute mean ticks, oldest first,
    /// worked out from the pool's raw observations one second at a time: no
    /// `observe`, no interpolation, no difference of cumulatives. Each
    /// mean is floored, toward negative infinity.
    function _model(TwapClPool p) internal view returns (int256[5] memory mean) {
        uint256 n = p.observationCount();
        uint256[] memory ts = new uint256[](n);
        int256[] memory cum = new int256[](n);
        for (uint256 i; i < n; ++i) {
            (uint32 t, int56 c) = p.observation(i);
            (ts[i], cum[i]) = (t, c);
        }
        int256 tickNow = p.tick();
        uint256 from = block.timestamp - 300;
        for (uint256 m; m < 5; ++m) {
            int256 sum;
            for (uint256 s = from + 60 * m; s < from + 60 * (m + 1); ++s) {
                sum += _tickDuring(ts, cum, tickNow, s);
            }
            mean[m] = _floor(sum, 60);
        }
    }

    function _nextTick(int24 base, uint256 r, bool quiet) internal pure returns (int24) {
        // Quiet: within 90 ticks of where the pool started, so the five
        // means are never more than 180 apart and some spot always passes.
        if (quiet) return base + int24(int256(r % 181)) - 90;
        uint256 kind = (r >> 8) % 4;
        if (kind == 0) return base;
        if (kind == 1) return base + int24(int256(r % 401)) - 200;
        if (kind == 2) return base + int24(int256(r % 6_001)) - 3_000;
        return base + int24(int256(r % 180_001)) - 90_000; // one block of this moves a minute 3,000
    }

    function _nextGap(uint256 r) internal pure returns (uint256) {
        uint256 kind = r % 8;
        if (kind == 0) return 0; // the same block
        if (kind <= 3) return 2; // the next one
        if (kind == 4) return 58;
        if (kind == 5) return 60;
        if (kind == 6) return 1 + (r >> 8) % 120;
        return 1 + (r >> 8) % 400;
    }

    /// The adapter against the model, over a random history: up to twelve
    /// pushes with anything from no time to several minutes between them,
    /// then a spot that is either where the history left the pool or a
    /// strike in the last block aimed at an edge of the band.
    ///
    /// `ticks()` must answer the model's lowest and highest mean. The swap
    /// must go through exactly when the spot is within the band of EVERY
    /// one of the model's five means, and when it does not, the error must
    /// name the spot and the mean furthest from it (the lower, on a tie).
    function testFuzz_R6b_TheCheckIsTheFiveMeansRule(uint256 seed, int24 base, bool usdcIsToken0)
        public
    {
        // Negative three times in four: where the real pools sit, and where
        // flooring and truncating part company.
        base = int24(bound(base, -60_000, 20_000));
        TwapClPool p = new TwapClPool(address(usdc), address(stock), usdcIsToken0, base);
        vm.warp(block.timestamp + 300 + seed % 400); // always enough history to answer
        bool quiet = (seed >> 16) % 2 == 0;
        uint256 moves = (seed >> 24) % 13;
        for (uint256 i; i < moves; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            p.push(_nextTick(base, r, quiet));
            vm.warp(block.timestamp + _nextGap(r >> 128));
        }

        int256[5] memory mean = _model(p);
        {
            // The spot: where the walk left it, or a strike in this block.
            int256 lo = mean[0];
            int256 hi = mean[0];
            for (uint256 i = 1; i < 5; ++i) {
                if (mean[i] < lo) lo = mean[i];
                if (mean[i] > hi) hi = mean[i];
            }
            uint256 aim = (seed >> 40) % 8;
            if (aim == 0) p.push(int24(lo + BAND));
            if (aim == 1) p.push(int24(lo + BAND + 1));
            if (aim == 2) p.push(int24(hi - BAND));
            if (aim == 3) p.push(int24(hi - BAND - 1));
            if (aim == 4) p.push(int24((lo + hi) / 2));
            if (aim == 5) p.push(int24(lo + int256((seed >> 48) % 301) - 150));
            // A push in this block is in none of the five means.
            int256[5] memory again = _model(p);
            for (uint256 i; i < 5; ++i) {
                assertEq(again[i], mean[i], "the model moved with a push in this block");
            }
            (int24 s, int24 low, int24 high) = direct.ticks(address(p));
            assertEq(s, p.tick());
            assertEq(int256(low), lo, "ticks() low is not the lowest of the five means");
            assertEq(int256(high), hi, "ticks() high is not the highest of the five means");
        }

        int256 spot = p.tick();
        bool refused;
        int256 far = -1;
        int256 furthest;
        for (uint256 i; i < 5; ++i) {
            int256 d = spot > mean[i] ? spot - mean[i] : mean[i] - spot;
            if (d > BAND) refused = true;
            if (d > far || (d == far && mean[i] < furthest)) (far, furthest) = (d, mean[i]);
        }
        if (refused) {
            vm.expectRevert(_pushed(int24(spot), int24(furthest)));
            direct.swapExactIn(address(p), address(stock), 1_000e6, 0, alice);
        } else {
            uint256 had = stock.balanceOf(alice);
            uint256 out = direct.swapExactIn(address(p), address(stock), 1_000e6, 0, alice);
            assertEq(stock.balanceOf(alice) - had, out);
        }
        assertEq(usdc.balanceOf(address(direct)), 0, "USDC stranded in the adapter");
    }

    /// What the check costs an honest market. The price steps 200 ticks
    /// (2%), once, and stays. A buy is refused straight away, and for as
    /// long as the OLDEST of the five minutes is still more than the band
    /// from the new price: it clears 270 seconds after the step, to the
    /// second, and never later than the 300-second window.
    ///
    /// (One 300 s average cleared the same step after 150 s. The 120 s are
    /// what five averages cost.)
    function test_R6b_AnHonestStepClearsWithinTheWindow() public {
        for (uint256 dir; dir < 2; ++dir) {
            int24 to = dir == 0 ? TICK0 + 200 : TICK0 - 200;
            pool.push(TICK0);
            vm.warp(block.timestamp + 1 hours);
            uint256 t0 = block.timestamp;
            pool.push(to);

            // Right after: in the same block, and in the next.
            _buyRefused(to, TICK0);
            vm.warp(t0 + 2);
            _buyRefused(to, TICK0);
            // Where one average let it through.
            vm.warp(t0 + 150);
            _buyRefused(to, TICK0);
            // Four minutes on, the oldest minute is still all old price.
            vm.warp(t0 + 240);
            _buyRefused(to, TICK0);
            // 269 s on it holds 29 s of the new price: 96.67 ticks of
            // average. Floored, that is 96 on the way up and 97 on the way
            // down, 104 and 103 from the spot.
            vm.warp(t0 + 269);
            _buyRefused(to, dir == 0 ? TICK0 + 96 : TICK0 - 97);
            // 270 s on: 30 s of it, 100 ticks, the edge of the band. The
            // first second at which a buy goes through.
            vm.warp(t0 + 270);
            _buyPasses();
            vm.warp(t0 + 271);
            _buyPasses();
            // And at the end of the window every average is the new price.
            vm.warp(t0 + 300);
            (int24 spot, int24 low, int24 high) = direct.ticks(address(pool));
            assertEq(spot, to);
            assertEq(low, to);
            assertEq(high, to);
            _buyPasses();
        }

        // Through the vault. The feed prints the new price at once, so the
        // pool's own history is all a due buy is waiting for.
        feed.set(int256(_px()), block.timestamp, true);
        uint256 id = _plan(vault, 10_000e6, 1_000e6, 1 days);
        vm.warp(block.timestamp + 1 days);
        uint256 step = block.timestamp;
        pool.push(TICK0);
        feed.set(int256(_px()), block.timestamp, true);
        uint256 held = stock.balanceOf(alice);
        vm.warp(step + 269);
        vm.expectRevert(_pushed(TICK0, TICK0 - 104));
        vm.prank(alice);
        vault.executeDCA(id);
        vm.warp(step + 270);
        vm.prank(alice);
        vault.executeDCA(id);
        assertApproxEqRel(
            stock.balanceOf(alice) - held, uint256(1_000e6) * 1e10 / _px(), 1e12, "the buy"
        );
    }

    // ===================================================== 2. the weekend
    /// Go to `ts` with a feed print one minute old there: nothing but the
    /// calendar can make it stale.
    function _at(uint256 ts) internal {
        vm.warp(ts);
        feed.set(int256(_px()), ts - 60, false);
    }

    function _expectWeekend(uint256 ts, bool closed) internal {
        _at(ts);
        assertEq(wcl.weekendClosed(), closed, "weekendClosed");
        assertEq(wcl.isFresh(address(stock)), !closed, "isFresh");
        // The price itself is not withheld: only its freshness.
        (uint256 px, uint256 updatedAt) = wcl.latestPrice(address(stock));
        assertEq(px, _px());
        assertEq(updatedAt, ts - 60);
        // And it is the rule that decides: the same print, at the same
        // second, on the oracle built without it.
        assertTrue(cl.isFresh(address(stock)), "control: the print itself is fresh");
    }

    /// Closed from Saturday 00:00:00 UTC up to, and not including, Monday
    /// 01:00:00 UTC. A print one minute old is fresh one second before and
    /// from the first second after, and not in between.
    function test_R6b_WeekendBoundaries() public {
        assertTrue(wcl.closedOnWeekends());
        assertEq(wcl.WEEKEND_LENGTH(), 49 hours);
        assertEq(MON_01_00 - SAT, 49 hours);

        _expectWeekend(FRI_23_59_59, false);
        _expectWeekend(SAT, true);
        _expectWeekend(SUN_NOON, true);
        _expectWeekend(MON_00_59_59, true);
        _expectWeekend(MON_01_00, false);
        _expectWeekend(WED_15_00, false);

        // The same four edges on a winter weekend (New York an hour further
        // from UTC: the rule does not move with it), and on one after a
        // leap day.
        uint256[2] memory saturdays = [WINTER_SAT, LEAP_SAT];
        for (uint256 i; i < 2; ++i) {
            _expectWeekend(saturdays[i] - 1, false);
            _expectWeekend(saturdays[i], true);
            _expectWeekend(saturdays[i] + 49 hours - 1, true);
            _expectWeekend(saturdays[i] + 49 hours, false);
        }
    }

    /// Through the vault. A buy that falls due on a Saturday waits, however
    /// fresh the print and however honest the pool, and is bought on
    /// Monday from 01:00 UTC.
    ///
    /// Before: the heartbeat alone kept Friday's last print fresh until
    /// Saturday evening, and a print that somehow landed on a Saturday was
    /// bought against like any other.
    function test_R6b_NoBuyOnASaturdayEvenWithAFreshPrint() public {
        // Wednesday 15:00 UTC: a deposit and its first buy, every 3 days.
        // The twin is the same plan on the vault with no weekend rule.
        _at(WED_15_00);
        uint256 id = _plan(wvault, 10_000e6, 1_000e6, 3 days);
        uint256 twin = _plan(vault, 10_000e6, 1_000e6, 3 days);
        uint256 fair = uint256(1_000e6) * 1e10 / _px();
        assertApproxEqRel(stock.balanceOf(alice), 2 * fair, 1e12, "the two first buys");

        // Saturday 15:00 UTC: due. The print is a minute old and the pool
        // is where it has been all week.
        _at(WED_15_00 + 3 days);
        assertTrue(wcl.weekendClosed());
        (int24 spot, int24 low, int24 high) = direct.ticks(address(pool));
        assertTrue(spot == TICK0 && low == TICK0 && high == TICK0, "the pool is not honest");
        uint256 held = stock.balanceOf(alice);
        vm.expectRevert(DcaVault.StaleOracle.selector);
        vm.prank(alice);
        wvault.executeDCA(id);
        assertEq(stock.balanceOf(alice), held, "a buy on a Saturday");

        // CONTROL: nothing else was in the way. The twin buys in this very
        // block.
        vm.prank(alice);
        vault.executeDCA(twin);
        assertApproxEqRel(stock.balanceOf(alice) - held, fair, 1e12, "the twin's Saturday buy");
        held = stock.balanceOf(alice);

        // Sunday, and the last second of the closure.
        _at(WED_15_00 + 4 days);
        vm.expectRevert(DcaVault.StaleOracle.selector);
        vm.prank(alice);
        wvault.executeDCA(id);
        _at(MON_01_00 + 7 days - 1);
        vm.expectRevert(DcaVault.StaleOracle.selector);
        vm.prank(alice);
        wvault.executeDCA(id);
        assertEq(stock.balanceOf(alice), held, "a buy on the weekend");

        // Monday 01:00:00 UTC: the same plan buys.
        _at(MON_01_00 + 7 days);
        vm.prank(alice);
        wvault.executeDCA(id);
        assertApproxEqRel(stock.balanceOf(alice) - held, fair, 1e12, "the Monday buy");
        (,,, uint256 rem,, uint64 next,, uint32 done, bool active) = wvault.plans(id);
        assertEq(rem, 8_000e6);
        assertEq(done, 2);
        assertTrue(active);
        // The schedule keeps its own days: the next is three days after the
        // Saturday it was due on, not after the Monday it was bought on.
        assertEq(next, WED_15_00 + 6 days);
    }

    /// A deposit on a weekend is not turned away. It opens the plan, lends
    /// all of it, buys nothing, and leaves the first buy due: whoever sends
    /// it from Monday 01:00 UTC gets it done.
    function test_R6b_ADepositOnAWeekendOpensAPlanWithNoFirstBuy() public {
        _at(SUN_NOON);
        uint256 cash = usdc.balanceOf(alice);
        uint256 id = _plan(wvault, 10_000e6, 1_000e6, 30 days);
        assertEq(usdc.balanceOf(alice), cash - 10_000e6, "the deposit was not taken");
        assertEq(stock.balanceOf(alice), 0, "a deposit bought on a Sunday");
        (,,, uint256 rem, uint256 shares, uint64 next,, uint32 done, bool active) = wvault.plans(id);
        assertEq(rem, 10_000e6, "something was spent");
        assertEq(done, 0);
        assertTrue(active);
        assertEq(next, SUN_NOON, "the first buy is not due");
        assertEq(wvault.totalPrincipal(), 10_000e6);
        assertEq(wvault.adapter().assetsOf(shares), 10_000e6, "not all of it is lent");
        assertEq(usdc.balanceOf(address(wvault)), 0);

        // CONTROL: the same deposit in the same block where the rule is
        // off buys at once.
        _plan(vault, 10_000e6, 1_000e6, 30 days);
        uint256 fair = uint256(1_000e6) * 1e10 / _px();
        assertApproxEqRel(stock.balanceOf(alice), fair, 1e12, "control: the first buy");
        uint256 held = stock.balanceOf(alice);

        // The last second of the closure: not yet, for the owner either.
        _at(MON_00_59_59);
        vm.expectRevert(DcaVault.StaleOracle.selector);
        vm.prank(alice);
        wvault.executeDCA(id);

        // Monday 01:00:00 UTC. The buy is 13 hours overdue by now, so it
        // does not even need the owner or a keeper.
        _at(MON_01_00);
        vm.prank(stranger);
        wvault.executeDCA(id);
        assertApproxEqRel(stock.balanceOf(alice) - held, fair, 1e12, "the first buy");
        (,,, rem,, next,, done,) = wvault.plans(id);
        assertEq(rem, 9_000e6);
        assertEq(done, 1);
        assertEq(next, SUN_NOON + 30 days);
    }

    /// The Saturday 00:00:00 UTC at or before `ts`, found by walking whole
    /// weeks from a Saturday that was checked against a calendar
    /// (2026-10-03). No remainder, and nothing about 1970: the contract
    /// gets there from "1 January 1970 was a Thursday".
    function _saturdayAtOrBefore(uint256 ts) internal pure returns (uint256 sat) {
        sat = SAT;
        while (sat > ts) sat -= 7 days;
        while (ts - sat >= 7 days) sat += 7 days;
    }

    /// Any second from 2020 to 2128: `weekendClosed()` is what the calendar
    /// says, and nothing is fresh while it is true.
    function testFuzz_R6b_WeekendRuleMatchesTheCalendar(uint256 ts, uint8 snap) public {
        ts = bound(ts, 1_577_836_800, 4_999_999_999);
        // Three runs in four land on an edge of that week's closure, or one
        // second either side of it.
        if (snap % 4 != 0) {
            uint256 edge = _saturdayAtOrBefore(ts) + ((snap >> 2) % 2 == 0 ? 0 : 49 hours);
            ts = edge + (snap >> 3) % 3 - 1;
        }
        // Closed for the 49 hours from Saturday 00:00:00: to Monday 00:59:59.
        bool closed = ts - _saturdayAtOrBefore(ts) < 49 hours;

        _at(ts);
        assertEq(wcl.weekendClosed(), closed, "weekendClosed is not the calendar");
        // The print is a minute old and the sequencer is up, so the rule is
        // all that can decide.
        assertEq(wcl.isFresh(address(stock)), !closed, "isFresh does not follow the weekend");
        assertFalse(cl.weekendClosed());
        assertTrue(cl.isFresh(address(stock)));
    }

    /// With the rule off, as on local and test chains, the oracle is the
    /// oracle it was: `weekendClosed()` is never true, a Saturday print is
    /// fresh, and the heartbeat is the only clock.
    function test_R6b_WeekendRuleOffLeavesFreshnessAlone() public {
        assertFalse(cl.closedOnWeekends());
        uint256[8] memory when = [
            FRI_23_59_59,
            SAT,
            SUN_NOON,
            MON_00_59_59,
            MON_01_00,
            WED_15_00,
            WINTER_SAT,
            LEAP_SAT + 1 days
        ];
        for (uint256 i; i < when.length; ++i) {
            _at(when[i]);
            assertFalse(cl.weekendClosed(), "the rule is off");
            assertTrue(cl.isFresh(address(stock)), "a one-minute-old print is not fresh");
        }
        // Every half hour of a whole week.
        for (uint256 t = SAT; t < SAT + 7 days; t += 30 minutes) {
            vm.warp(t);
            assertFalse(cl.weekendClosed(), "the rule is off");
        }

        // What that leaves, and why mainnet has the rule: Friday's last
        // print reads fresh for its whole heartbeat, to the last second of
        // Saturday's 24th hour.
        vm.warp(SAT + 24 hours - 1);
        feed.set(int256(_px()), FRI_23_59_59, false);
        assertTrue(cl.isFresh(address(stock)), "the heartbeat is not what decides");
        assertFalse(wcl.isFresh(address(stock)));
        vm.warp(SAT + 24 hours);
        assertFalse(cl.isFresh(address(stock)), "fresh past the heartbeat");
    }

    // ================================================ 3. the fee recipient
    /// Before: the oracle was accepted, and fees claimed to it could never
    /// leave (the review claimed 90 USDC into it to show so).
    function test_R6b_TheFeeRecipientCannotBeTheOracle() public {
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.setFeeRecipient(address(cl));
        vm.expectRevert(DcaVault.BadParams.selector);
        wvault.setFeeRecipient(address(wcl));
        assertEq(vault.feeRecipient(), address(this));
        assertEq(wvault.feeRecipient(), address(this));

        // It is the vault's OWN oracle that is refused. The list is not
        // complete and cannot be (DcaVault.setFeeRecipient): some other
        // contract that cannot send USDC on is still accepted.
        vault.setFeeRecipient(address(wcl));
        assertEq(vault.feeRecipient(), address(wcl));
        vault.setFeeRecipient(alice);
        assertEq(vault.feeRecipient(), alice);
    }

    // ==================================================== the sequencer view
    function _expectSequencer(ChainlinkOracle o, bool up) internal view {
        assertEq(o.sequencerUp(), up, "sequencerUp");
        assertEq(o.isFresh(address(stock)), up, "isFresh does not follow sequencerUp");
    }

    function _withUptime(address up) internal returns (ChainlinkOracle o) {
        o = new ChainlinkOracle(up, false);
        o.setFeed(address(stock), address(feed));
    }

    /// `sequencerUp()` used to be internal. It is public now so that a
    /// monitor can see what `isFresh` takes the sequencer's state to be,
    /// and above all the case where it has FAILED OPEN: the uptime feed
    /// cannot be read, and this still says true. With a fresh price and no
    /// weekend rule, `isFresh` is this view, case by case.
    function test_R6b_SequencerUpIsWhatIsFreshUses() public {
        // Up, and long enough.
        _expectSequencer(cl, true);
        // Down. Any answer but 0 is down.
        uptime.set(1, block.timestamp - 10 minutes, false);
        _expectSequencer(cl, false);
        uptime.set(-1, 1, false);
        _expectSequencer(cl, false);
        // Just restarted: false to the last second of the grace.
        uint256 restart = block.timestamp;
        uptime.set(0, restart, false);
        _expectSequencer(cl, false);
        vm.warp(restart + cl.SEQUENCER_GRACE() - 1);
        _expectSequencer(cl, false);
        vm.warp(restart + cl.SEQUENCER_GRACE());
        _expectSequencer(cl, true);
        // A restart time in the future is "just restarted".
        uptime.set(0, block.timestamp + 1, false);
        _expectSequencer(cl, false);

        // An uptime feed that cannot be read: TRUE, on purpose.
        _expectSequencer(_withUptime(address(0)), true); // no check at all
        _expectSequencer(_withUptime(address(0xDEAD)), true); // no code there
        RawFeed raw = new RawFeed();
        ChainlinkOracle o = _withUptime(address(raw));
        raw.set(abi.encode(uint80(1), int256(1), block.timestamp, block.timestamp, uint80(1)), 0);
        _expectSequencer(o, false); // control: readable, and it says down
        raw.set("", 1); // reverts
        _expectSequencer(o, true);
        raw.set(new bytes(159), 0); // one byte short of five words
        _expectSequencer(o, true);

        // The weekend rule is a separate question: on a Saturday the
        // sequencer is still up, and still nothing is fresh.
        uptime.set(0, 1, false);
        _at(SAT);
        assertTrue(wcl.sequencerUp());
        assertFalse(wcl.isFresh(address(stock)));
    }
}
