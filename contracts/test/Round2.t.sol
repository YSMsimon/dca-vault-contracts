// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle, IAggregatorV3} from "../src/adapters/ChainlinkOracle.sol";
import {AerodromeSwapAdapter} from "../src/adapters/AerodromeSwapAdapter.sol";
import {
    MockERC20,
    MockStock,
    MockYieldAdapter,
    MockPriceOracle,
    MockSwapAdapter,
    VaultBound
} from "../src/mocks/Mocks.sol";
import {MockRebasingPool, MockRebasingAdapter} from "../src/mocks/RebasingMocks.sol";
import {
    DemoUSDC,
    DemoStock,
    DemoYieldAdapter,
    DemoPriceOracle,
    DemoSwapAdapter
} from "../src/mocks/DemoMocks.sol";
import {CpammSwap, Sandwicher, FakeClPool, FakeFeed} from "./utils/HostileVenues.sol";

/// One contract per Sybil address: drip, then hand the dollars to `to`.
contract DripChild {
    constructor(DemoUSDC u, address to) {
        u.drip();
        u.transfer(to, u.DRIP());
    }
}

/// The round-2 Sybil: a factory that drips once per child, in ONE transaction.
contract DripFactory {
    function run(DemoUSDC u, uint256 n) external {
        for (uint256 i; i < n; ++i) new DripChild(u, msg.sender);
    }
}

/// Atomic sandwich with an attacker-controlled feed set to the pushed price.
contract FeedSandwicher {
    function run(
        DcaVault v,
        CpammSwap p,
        MockERC20 u,
        MockStock s,
        FakeFeed f,
        uint256 id,
        uint256 push
    ) external {
        u.approve(address(p), type(uint256).max);
        s.approve(address(p), type(uint256).max);
        uint256 got = p.buy(push);
        f.set(int256(p.poolPrice(address(0), address(0))), block.timestamp, true);
        v.executeDCA(id);
        p.sell(got);
    }
}

/// @notice The hardening plan, ROUND 2 (docs/hardening-plan.md, D1..D7).
/// @dev    Each test began as a reproduction from the re-test of an earlier
///         revision that PASSED against the unfixed code by demonstrating the
///         finding. Each is rewritten here to assert the SAFE behaviour, so it
///         fails if the finding comes back. The name carries the plan item.
///         A "Before (...)" note names the original reproduction
///         (Adv2.test_N_*, Adv3.*, AuditPoC2.*). Those originals are not
///         published: each was rewritten into the test under its note.
contract Round2Test is Test {
    MockERC20 usdc;
    MockStock stock;
    MockYieldAdapter y;
    MockPriceOracle oracle;
    MockSwapAdapter swapper;
    DcaVault vault;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address thief = address(0x7E1F);
    uint256 constant PX = 227_56000000;

    function setUp() public {
        vm.warp(1_780_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("Mock NVDAc", "NVDAc");
        y = new MockYieldAdapter(usdc);
        oracle = new MockPriceOracle();
        swapper = new MockSwapAdapter(usdc, stock, oracle);
        oracle.setPrice(address(stock), PX);
        vault = new DcaVault(IERC20(address(usdc)), y, swapper, oracle, 10_000_000e6);
        y.bindVault(address(vault));
        vault.initRoute(1, _route(address(stock), address(swapper), address(oracle)));
        vault.finishSetup();
        _fund(alice, address(vault));
        _fund(bob, address(vault));
    }

    // ------------------------------------------------------------ helpers
    function _route(address t, address p, address f) internal pure returns (DcaVault.Route memory) {
        return DcaVault.Route({token: t, pool: p, feed: f, dexKind: 0, enabled: true});
    }

    function _fund(address who, address spender) internal {
        usdc.mint(who, 1_000_000e6);
        vm.prank(who);
        usdc.approve(spender, type(uint256).max);
    }

    function _p(DcaVault v, uint256 id)
        internal
        view
        returns (uint256 rem, uint256 sh, uint64 ne, uint32 done, bool active)
    {
        (,,, rem, sh, ne,, done, active) = v.plans(id);
    }

    /// The Base Sepolia demo, wired exactly as Deploy.sepolia wires it: the
    /// yield adapter bound at construction to the predicted vault.
    function _demo(uint256 cap)
        internal
        returns (DemoUSDC du, DemoYieldAdapter ya, DcaVault v, DemoStock ds)
    {
        address owner = address(0x0A);
        du = new DemoUSDC(address(this));
        DemoPriceOracle o = new DemoPriceOracle(address(this));
        ds = new DemoStock("D", "D", address(this));
        o.setPrice(address(ds), PX);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        ya = new DemoYieldAdapter(du, address(this), predicted);
        DemoSwapAdapter sa = new DemoSwapAdapter(du, ds, o, address(this));
        v = new DcaVault(IERC20(address(du)), ya, sa, o, cap);
        assertEq(address(v), predicted, "prediction");
        v.initRoute(1, _route(address(ds), address(sa), address(o)));
        v.finishSetup();
        du.setMinter(address(ya));
        du.mint(address(ya), 10_000e6); // the deploy script's seed
        du.setOwner(owner);
        ya.setOwner(owner);
    }

    // ================================================================= D1
    /// Before (Adv2.test_N_DemoYieldAdapterAnyoneCanDrain, AuditPoC2.B4, the
    /// Sepolia-fork lifecycle step 10): DemoYieldAdapter inherited the mock's
    /// open `withdraw`/`redeem`, a stranger took every visitor's pooled USDC,
    /// and every exit then panicked 0x11. Now the adapter answers only to the
    /// vault, and the visitor's exit pays in full.
    function test_D1_AStrangerCannotDrainTheDemoAdapter() public {
        (DemoUSDC du, DemoYieldAdapter ya, DcaVault v,) = _demo(100_000_000e6);
        address visitor = address(0x71517);
        vm.warp(block.timestamp + 1);
        vm.startPrank(visitor);
        du.drip();
        du.approve(address(v), type(uint256).max);
        uint256 id = v.createPlan(1, 1000e6, 100e6, 30 days);
        vm.stopPrank();

        uint256 shares = ya.totalShares();
        uint256 pooled = ya.assetsOf(shares);
        assertGt(pooled, 800e6);

        vm.startPrank(thief);
        vm.expectRevert(VaultBound.OnlyVault.selector);
        ya.withdraw(pooled);
        vm.expectRevert(VaultBound.OnlyVault.selector);
        ya.redeem(shares);
        vm.expectRevert(VaultBound.OnlyVault.selector);
        ya.supply(0);
        vm.stopPrank();
        assertEq(du.balanceOf(thief), 0, "the thief got demo USDC");

        uint256 before = du.balanceOf(visitor);
        vm.prank(visitor);
        v.exitPlan(id);
        assertEq(du.balanceOf(visitor) - before, pooled, "the exit did not pay the pooled value");
        assertEq(ya.totalShares(), 0);
    }

    /// The binding is fixed at construction and can never move: not by the
    /// owner, not by the deployer, not to zero.
    function test_D1_TheDemoAdapterBindingIsFixed() public {
        (, DemoYieldAdapter ya, DcaVault v,) = _demo(100_000_000e6);
        assertEq(ya.vault(), address(v));
        vm.expectRevert(DemoYieldAdapter.AlreadyBound.selector);
        ya.bindVault(thief);
        vm.prank(address(0x0A)); // the demo owner
        vm.expectRevert(DemoYieldAdapter.AlreadyBound.selector);
        ya.bindVault(thief);
        vm.expectRevert(VaultBound.OnlyVault.selector);
        new DemoYieldAdapter(usdc, address(this), address(0));
    }

    /// The mocks the tests use carry the same gate. Unbound, it is SHUT; only
    /// the deployer binds it; a bound adapter refuses everyone but its vault.
    function test_D1_TheTestMocksAreGatedToo() public {
        MockYieldAdapter y2 = new MockYieldAdapter(usdc);
        usdc.mint(address(this), 10e6);
        usdc.approve(address(y2), type(uint256).max);
        vm.expectRevert(VaultBound.OnlyVault.selector);
        y2.supply(1e6); // unbound: nobody, not even the deployer
        vm.prank(thief);
        vm.expectRevert(VaultBound.NotBinder.selector);
        y2.bindVault(thief);

        MockRebasingAdapter ra = new MockRebasingAdapter(usdc, new MockRebasingPool(usdc));
        vm.expectRevert(VaultBound.OnlyVault.selector);
        ra.supply(1e6);
        vm.prank(thief);
        vm.expectRevert(VaultBound.NotBinder.selector);
        ra.bindVault(thief);

        // The suite's own adapter, bound in setUp: a live plan, then a stranger.
        vm.prank(alice);
        vault.createPlan(1, 10_000e6, 1_000e6, 30 days);
        uint256 shares = y.totalShares();
        vm.startPrank(thief);
        vm.expectRevert(VaultBound.OnlyVault.selector);
        y.redeem(shares);
        vm.expectRevert(VaultBound.OnlyVault.selector);
        y.withdraw(1);
        vm.stopPrank();
    }

    // ================================================================= D2
    /// Before (Adv2.test_N_QueuedRouteNeverExpires, AuditPoC2.B2): a re-enable
    /// queued once could be activated 400 days later — or in the same block as
    /// an incident's `disableRoute` — with no fresh notice. Now `disableRoute`
    /// drops the pending entry, and an entry left past its window expires.
    function test_D2_DisableRouteDropsAPendingReEnable() public {
        vm.prank(alice);
        uint256 id = vault.createPlan(1, 3_000e6, 1_000e6, 30 days);
        vault.queueRoute(1, _route(address(stock), address(swapper), address(oracle)));
        vm.warp(block.timestamp + 30 days);

        vm.expectEmit(true, false, false, false, address(vault));
        emit DcaVault.RouteCancelled(1);
        vault.disableRoute(1); // incident response
        (,,,,, uint64 eta) = vault.pendingRoutes(1);
        assertEq(eta, 0, "the pre-armed re-enable survived the disable");

        vm.expectRevert(DcaVault.NothingQueued.selector);
        vault.activateRoute(1);
        (,,,, bool en) = vault.routes(1);
        assertFalse(en, "re-enabled with no fresh delay");
        vm.prank(alice);
        vm.expectRevert(DcaVault.RouteDisabled.selector);
        vault.executeDCA(id);

        // The honest way back: a fresh queue, a fresh 48h.
        vault.queueRoute(1, _route(address(stock), address(swapper), address(oracle)));
        vm.expectRevert();
        vault.activateRoute(1);
        vm.warp(block.timestamp + 48 hours);
        vault.activateRoute(1);
        (,,,, en) = vault.routes(1);
        assertTrue(en);
    }

    function test_D2_AQueuedRouteExpires() public {
        vm.prank(alice);
        vault.createPlan(1, 10_000e6, 1_000e6, 30 days);
        MockStock t2 = new MockStock("T2", "T2");
        vault.queueRoute(7, _route(address(t2), address(swapper), address(oracle)));
        (,,,,, uint64 eta) = vault.pendingRoutes(7);
        uint64 deadline = eta + vault.ACTIVATION_WINDOW();
        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(abi.encodeWithSelector(DcaVault.QueueExpired.selector, deadline));
        vault.activateRoute(7);
        (,,,, bool en) = vault.routes(7);
        assertFalse(en);

        // Re-queueing starts a new window; its last second still works.
        vault.queueRoute(7, _route(address(t2), address(swapper), address(oracle)));
        (,,,,, eta) = vault.pendingRoutes(7);
        vm.warp(uint256(eta) + vault.ACTIVATION_WINDOW());
        vault.activateRoute(7);
        (,,,, en) = vault.routes(7);
        assertTrue(en);
    }

    /// Activation succeeds exactly inside [eta, eta + 7 days], for routes,
    /// feeds and loosened bounds alike.
    function testFuzz_D2_ActivationOnlyInsideTheWindow(uint256 dt) public {
        dt = bound(dt, 0, 20 days);
        vm.prank(alice);
        vault.createPlan(1, 10_000e6, 1_000e6, 30 days);
        MockStock t2 = new MockStock("T2", "T2");
        ChainlinkOracle cl = new ChainlinkOracle(address(0), false);
        FakeFeed f1 = new FakeFeed();
        FakeFeed f2 = new FakeFeed();
        cl.setFeed(address(t2), address(f1));

        uint256 t0 = block.timestamp;
        vault.queueRoute(7, _route(address(t2), address(swapper), address(oracle)));
        cl.queueFeed(address(t2), address(f2));
        vault.setBounds(150, 800); // a loosening: queued
        assertEq(vault.maxSlippageBps(), 100);

        vm.warp(t0 + dt);
        bool inside = dt >= 48 hours && dt <= 48 hours + 7 days;
        (bool okR,) = address(vault).call(abi.encodeCall(DcaVault.activateRoute, (7)));
        (bool okF,) = address(cl).call(abi.encodeCall(ChainlinkOracle.activateFeed, (address(t2))));
        (bool okB,) = address(vault).call(abi.encodeCall(DcaVault.activateBounds, ()));
        assertEq(okR, inside, "route");
        assertEq(okF, inside, "feed");
        assertEq(okB, inside, "bounds");
        assertEq(vault.maxSlippageBps(), inside ? 150 : 100);
        assertEq(cl.feedOf(address(t2)), inside ? address(f2) : address(f1));
    }

    /// Before (Adv2.test_N_DormantQueuedFeedActivatedLaterBreaksTheBound,
    /// AuditPoC2.B7): a feed queued at launch and left dormant was activated
    /// a year later in the same block as an instant `setBounds(200, 2000)` and
    /// a sandwich — the victim filled 3,090 bps under the real price. Now the
    /// dormant feed has expired, the loosening is queued rather than applied,
    /// and the same sandwich either reverts or costs at most maxSlippageBps.
    function test_D2_ADormantFeedQueueCannotBeSprungWithASandwich() public {
        ChainlinkOracle cl = new ChainlinkOracle(address(0), false);
        CpammSwap pool = new CpammSwap(usdc, stock, 5_000_000e6, 5_000_000e6 * 1e10 / PX);
        uint256 real = pool.poolPrice(address(0), address(0));
        FakeFeed good = new FakeFeed();
        good.set(int256(real), block.timestamp, true);
        cl.setFeed(address(stock), address(good));
        MockYieldAdapter y2 = new MockYieldAdapter(usdc);
        DcaVault v = new DcaVault(IERC20(address(usdc)), y2, pool, cl, 10_000_000e6);
        y2.bindVault(address(v));
        v.initRoute(1, _route(address(stock), address(pool), address(good)));
        v.finishSetup();
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        uint256 id = v.createPlan(1, 100_000e6, 10_000e6, 30 days);

        FakeFeed evil = new FakeFeed();
        evil.set(int256(real), block.timestamp, true);
        cl.queueFeed(address(stock), address(evil)); // public, then left dormant
        vm.warp(block.timestamp + 365 days);

        vm.expectRevert(); // QueueExpired
        cl.activateFeed(address(stock));
        assertEq(cl.feedOf(address(stock)), address(good), "the dormant feed went live");

        v.setBounds(200, 2000);
        assertEq(v.maxSlippageBps(), 100, "a loosening took effect instantly");
        assertEq(v.maxDeviationBps(), 500, "a loosening took effect instantly");

        FeedSandwicher s = new FeedSandwicher();
        v.setKeeper(address(s), true);
        uint256 push = 1_000_000e6;
        usdc.mint(address(s), push);
        uint256 before = stock.balanceOf(alice);
        // The attacker's feed is not the one the vault prices off, so the
        // pushed pool trips the breaker against the real feed.
        vm.expectRevert();
        s.run(v, pool, usdc, stock, evil, id, push);
        assertEq(stock.balanceOf(alice), before);

        // Unpushed, the plan fills inside the bound against the REAL feed.
        vm.prank(alice);
        v.executeDCA(id);
        uint256 got = stock.balanceOf(alice) - before;
        uint256 fair = 10_000e6 * 1e10 / real;
        assertGe(got * 10_000, fair * (10_000 - v.maxSlippageBps()), "fill beyond bound");
    }

    /// Before: `queueFeed` accepted a token with no feed at all — a dormant
    /// entry that meant nothing until a later `setFeed`. Now it is refused.
    function test_D2_QueueFeedNeedsAListedToken() public {
        ChainlinkOracle cl = new ChainlinkOracle(address(0), false);
        FakeFeed f = new FakeFeed();
        vm.expectRevert(ChainlinkOracle.NoFeed.selector);
        cl.queueFeed(address(stock), address(f));
        cl.setFeed(address(stock), address(f));
        cl.queueFeed(address(stock), address(new FakeFeed()));
    }

    /// Before (AuditPoC2.B7's second half): `setBounds(200, 2000)` took effect
    /// in the same block, so the slippage bound users rely on could double
    /// without notice. Tightening stays instant; loosening waits 48h.
    function test_D2_LooseningTheBoundsIsQueuedTighteningIsNot() public {
        // Before finishSetup there is nothing to protect: instant.
        MockYieldAdapter y2 = new MockYieldAdapter(usdc);
        DcaVault fresh = new DcaVault(IERC20(address(usdc)), y2, swapper, oracle, 10_000_000e6);
        fresh.setBounds(120, 600);
        assertEq(fresh.maxSlippageBps(), 120);
        fresh.finishSetup();
        fresh.setBounds(200, 2000);
        assertEq(fresh.maxSlippageBps(), 120, "a loosening after finishSetup was instant");

        vm.prank(alice);
        vault.createPlan(1, 10_000e6, 1_000e6, 30 days);

        // Tighten: instant.
        vault.setBounds(50, 300);
        assertEq(vault.maxSlippageBps(), 50);
        assertEq(vault.maxDeviationBps(), 300);

        // Loosen either bound: queued, nothing moves.
        vm.expectEmit(false, false, false, true, address(vault));
        emit DcaVault.BoundsQueued(50, 2000, uint64(block.timestamp + 48 hours));
        vault.setBounds(50, 2000);
        assertEq(vault.maxDeviationBps(), 300);
        (uint16 qs, uint16 qd, uint64 eta) = vault.pendingBounds();
        assertEq(qs, 50);
        assertEq(qd, 2000);

        vm.expectRevert(abi.encodeWithSelector(DcaVault.TimelockActive.selector, eta));
        vault.activateBounds();
        vm.prank(thief);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.activateBounds();

        vm.warp(eta);
        vault.activateBounds();
        assertEq(vault.maxDeviationBps(), 2000);
        vm.expectRevert(DcaVault.NothingQueued.selector);
        vault.activateBounds();

        // Cancel, and expiry.
        vault.setBounds(200, 2000);
        vault.cancelBounds();
        vm.expectRevert(DcaVault.NothingQueued.selector);
        vault.activateBounds();
        vault.setBounds(200, 2000);
        (,, eta) = vault.pendingBounds();
        vm.warp(uint256(eta) + 7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(DcaVault.QueueExpired.selector, eta + 7 days));
        vault.activateBounds();
        assertEq(vault.maxSlippageBps(), 50);

        // The ceilings still hold on the queued path.
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.setBounds(201, 300);
    }

    // ================================================================= D3
    /// Before (AuditPoC2.B5): a pool that called the Aerodrome callback twice
    /// collected 2x amountIn, sweeping any stray USDC in the adapter. Now the
    /// callback disarms itself before paying, and the second call reverts.
    function test_D3_TheSwapCallbackIsOneShot() public {
        AerodromeSwapAdapter aero = new AerodromeSwapAdapter(IERC20(address(usdc)), address(this));
        MockStock junk = new MockStock("junk", "JUNK");
        FakeClPool dip = new FakeClPool(address(usdc), address(junk), 4, 1);
        usdc.mint(address(aero), 500e6); // stray donation / mistaken transfer
        usdc.mint(address(this), 500e6);
        usdc.approve(address(aero), type(uint256).max);
        vm.expectRevert(AerodromeSwapAdapter.BadCallback.selector);
        aero.swapExactIn(address(dip), address(junk), 500e6, 1, alice);
        assertEq(usdc.balanceOf(address(dip)), 0, "the pool collected anything");
        assertEq(usdc.balanceOf(address(aero)), 500e6, "the stray USDC left");

        // A pool that never calls back is not a swap either, whatever it reports.
        FakeClPool mute = new FakeClPool(address(usdc), address(junk), 3, 1e8);
        vm.expectRevert(AerodromeSwapAdapter.BadCallback.selector);
        aero.swapExactIn(address(mute), address(junk), 500e6, 1, alice);

        // And outside a swap the callback is closed to everyone.
        vm.prank(address(dip));
        vm.expectRevert(AerodromeSwapAdapter.BadCallback.selector);
        aero.uniswapV3SwapCallback(int256(1), 0, "");

        // An honest pool still swaps.
        FakeClPool honest = new FakeClPool(address(usdc), address(junk), 2, 7e8);
        uint256 out = aero.swapExactIn(address(honest), address(junk), 500e6, 1, alice);
        assertEq(out, 7e8);
        assertEq(usdc.balanceOf(address(honest)), 500e6);
    }

    // ================================================================= D4
    /// Before (Adv3.test_N_RevertingFeedBlocksDeposits): `isFresh` bubbled a
    /// reverting feed, and `createPlan` asks it before the first buy, so a
    /// deprecated feed blocked deposits too. Now it reads as not fresh: the
    /// deposit goes through with no first buy, and executions wait.
    function test_D4_ARevertingFeedDoesNotBlockDeposits() public {
        ChainlinkOracle cl = new ChainlinkOracle(address(0), false);
        FakeFeed f = new FakeFeed();
        f.set(int256(PX), block.timestamp, true);
        cl.setFeed(address(stock), address(f));
        MockYieldAdapter y2 = new MockYieldAdapter(usdc);
        DcaVault v = new DcaVault(IERC20(address(usdc)), y2, swapper, cl, 1e12);
        y2.bindVault(address(v));
        v.initRoute(1, _route(address(stock), address(swapper), address(f)));
        v.finishSetup();
        usdc.mint(address(this), 1e9);
        usdc.approve(address(v), 1e9);

        vm.mockCallRevert(
            address(f), abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), "DEPRECATED"
        );
        assertFalse(cl.isFresh(address(stock)));
        uint256 id = v.createPlan(1, 1e9, 1e8, 1 days);
        (uint256 rem,, uint64 ne, uint32 done, bool act) = _p(v, id);
        assertEq(rem, 1e9, "a first buy happened against a dead feed");
        assertEq(done, 0);
        assertEq(ne, block.timestamp, "the plan should open already due");
        assertTrue(act);
        vm.expectRevert(DcaVault.StaleOracle.selector);
        v.executeDCA(id);

        // Garbage return data is caught too, which a try/catch would not do.
        vm.mockCall(
            address(f), abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), hex"01"
        );
        assertFalse(cl.isFresh(address(stock)));
        // An out-of-range round id does not revert the decode. It reads as
        // NOT fresh (round 3, F3): it used to read fresh here and then revert
        // in latestPrice, inside the first buy, which blocked the deposit.
        vm.mockCall(
            address(f),
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(type(uint256).max, int256(PX), block.timestamp, block.timestamp, type(uint256).max)
        );
        assertFalse(cl.isFresh(address(stock)));

        // The feed recovers: the plan buys.
        vm.clearMockedCalls();
        v.executeDCA(id);
        (, , , done,) = _p(v, id);
        assertEq(done, 1);
    }

    // ================================================================= D5
    /// Before (Adv2.test_N_DemoCapStillFillsViaSybilDrip): a factory deploying
    /// 253 one-drip children filled the $250k demo cap in ONE transaction, and
    /// the next visitor's plan reverted CapExceeded. Now the faucet has a
    /// global daily budget and the Sepolia cap sits a thousand days above it.
    function test_D5_ASybilCannotFillTheDemoCap() public {
        (DemoUSDC du,, DcaVault v,) = _demo(100_000_000e6);
        vm.warp(block.timestamp + 1);
        uint256 perDay = du.DAILY_BUDGET() / du.DRIP();

        DripFactory fac = new DripFactory();
        vm.prank(address(0xE));
        vm.expectRevert(); // FaucetDry, bubbled out of the child's constructor
        fac.run(du, 253);
        assertEq(du.balanceOf(address(0xE)), 0);

        vm.prank(address(0xE));
        fac.run(du, perDay); // the whole day's budget, one Sybil
        assertEq(du.balanceOf(address(0xE)), du.DAILY_BUDGET());
        assertEq(du.faucetRemainingToday(), 0);

        // The next visitor: told when, not given a cryptic failure.
        address g = address(0x6);
        uint256 refill = (block.timestamp / 1 days + 1) * 1 days;
        assertEq(du.dripReadyAt(g), refill);
        vm.prank(g);
        vm.expectRevert(abi.encodeWithSelector(DemoUSDC.FaucetDry.selector, refill));
        du.drip();

        // ...and the cap is nowhere near reach.
        vm.startPrank(address(0xE));
        du.approve(address(v), type(uint256).max);
        v.createPlan(1, du.DAILY_BUDGET(), du.DAILY_BUDGET() / 100, 366 days);
        vm.stopPrank();
        assertLt(v.totalPrincipal() * 900, v.tvlCap(), "one day of faucet is not a thousandth of the cap");

        // The budget refills at the next UTC day.
        vm.warp(refill);
        assertEq(du.dripReadyAt(g), 0);
        vm.startPrank(g);
        du.drip();
        du.approve(address(v), type(uint256).max);
        v.createPlan(1, 1000e6, 100e6, 30 days);
        vm.stopPrank();
    }

    /// The per-address cooldown still applies inside the budget, and
    /// `dripReadyAt` reports the later of the two limits.
    function test_D5_CooldownAndBudgetCompose() public {
        (DemoUSDC du,,,) = _demo(100_000_000e6);
        vm.warp(10 days + 23 hours); // one hour before a UTC day boundary
        vm.prank(alice);
        du.drip();
        uint256 cooldownReady = block.timestamp + du.COOLDOWN();
        assertEq(du.dripReadyAt(alice), cooldownReady);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DemoUSDC.DripTooSoon.selector, cooldownReady));
        du.drip();
        assertEq(du.faucetRemainingToday(), du.DAILY_BUDGET() - du.DRIP());
        vm.warp(block.timestamp + 1 hours); // new day: budget resets, cooldown does not
        assertEq(du.faucetRemainingToday(), du.DAILY_BUDGET());
        assertEq(du.dripReadyAt(alice), cooldownReady);
    }

    // ================================================================= D6
    /// Before: a stock that is not 8 decimals was admitted, and then failed
    /// every execution as `PoolDiverged` — the minOut math and the pool-price
    /// bridge are both 8dp. Now it is refused at admission, by name.
    function test_D6_ANonEightDecimalStockIsRefusedByName() public {
        MockERC20 wide = new MockERC20("Wide", "W18", 18);
        MockERC20 narrow = new MockERC20("Narrow", "W6", 6);
        // During setup (initRoute) ...
        MockYieldAdapter y2 = new MockYieldAdapter(usdc);
        DcaVault fresh = new DcaVault(IERC20(address(usdc)), y2, swapper, oracle, 10_000_000e6);
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 18));
        fresh.initRoute(2, _route(address(wide), address(swapper), address(oracle)));
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 0));
        fresh.initRoute(2, _route(address(0x5170C), address(swapper), address(oracle))); // no code
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 6));
        fresh.initRoute(2, _route(address(narrow), address(swapper), address(oracle)));

        vm.prank(alice);
        vault.createPlan(1, 10_000e6, 1_000e6, 30 days);
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 18));
        vault.queueRoute(2, _route(address(wide), address(swapper), address(oracle)));
        vault.queueRoute(2, _route(address(new MockStock("Ok", "OK")), address(swapper), address(oracle)));
    }

    /// `Route.feed` is the feed AT ADMISSION. After the oracle rotates a
    /// token's feed behind its own delay, the route record still names the
    /// old one — and the vault, which never reads it, prices off the new.
    function test_D6_RouteFeedIsTheFeedAtAdmission() public {
        ChainlinkOracle cl = new ChainlinkOracle(address(0), false);
        FakeFeed f1 = new FakeFeed();
        FakeFeed f2 = new FakeFeed();
        f1.set(int256(PX), block.timestamp, true);
        f2.set(int256(PX * 101 / 100), block.timestamp, true);
        cl.setFeed(address(stock), address(f1));
        MockYieldAdapter y2 = new MockYieldAdapter(usdc);
        DcaVault v = new DcaVault(IERC20(address(usdc)), y2, swapper, cl, 1e12);
        y2.bindVault(address(v));
        v.initRoute(1, _route(address(stock), address(swapper), address(f1)));
        v.finishSetup();
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        oracle.setPrice(address(stock), PX * 101 / 100); // the venue follows f2
        vm.prank(alice);
        uint256 id = v.createPlan(1, 10_000e6, 1_000e6, 1 days);

        cl.queueFeed(address(stock), address(f2));
        vm.warp(block.timestamp + 48 hours);
        cl.activateFeed(address(stock));

        (,, address recorded,,) = v.routes(1);
        assertEq(recorded, address(f1), "the record is the feed at admission");
        assertEq(cl.feedOf(address(stock)), address(f2), "readers ask the oracle");

        uint256 before = stock.balanceOf(alice);
        vm.prank(alice);
        v.executeDCA(id);
        uint256 minOut =
            uint256(1_000e6) * 1e10 * (10_000 - uint256(v.maxSlippageBps())) / (PX * 101 / 100 * 10_000);
        assertGe(stock.balanceOf(alice) - before, minOut);
    }

    // ================================================================= D7
    /// Round 2 documented this and left it (Adv2.test_N_EarlyShortfallEndFromRounding):
    /// a plan whose remaining principal was a few wei above one installment,
    /// at a non-par share price, redeemed everything one period early and
    /// reported the wei as a shortfall. Round 6 (R5-5) refuses that plan at
    /// the door: the last period is at least MIN_INSTALLMENT too. So an early
    /// end now takes a real loss of at least that much, never rounding, and
    /// the same shape with the shortest tail the vault admits runs every period.
    function test_D7_RoundingCanNoLongerEndAPlanOnePeriodEarly() public {
        y.accrueTo(1.07e18);
        vm.prank(alice);
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.createPlan(1, 2000e6 + 1, 1000e6, 30 days);

        vm.prank(alice);
        uint256 id = vault.createPlan(1, 2001e6, 1000e6, 30 days);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        vault.executeDCA(id);
        (uint256 rem,,, uint32 done, bool act) = _p(vault, id);
        assertTrue(act, "closed one period early");
        assertEq(done, 2);
        assertEq(rem, 1e6, "the last period is not the tail");

        vm.warp(block.timestamp + 30 days);
        vm.recordLogs();
        vm.prank(alice);
        vault.executeDCA(id);
        uint256 sh;
        (rem, sh,, done, act) = _p(vault, id);
        assertFalse(act);
        assertEq(rem, 0);
        assertEq(sh, 0);
        assertEq(done, 3, "three periods by count, and three were bought");
        // What rounding costs is still reported, and is still wei.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 shortfall;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == DcaVault.PlanShortfall.selector) {
                shortfall = abi.decode(logs[i].data, (uint256));
            }
        }
        assertGt(shortfall, 0, "the shortfall must be reported");
        assertLe(shortfall, 3, "more than rounding");
    }

    /// Documented: a pool premium above `maxSlippageBps` fails CLOSED. The
    /// plan waits; it never fills worse than the bound.
    function test_D7_APremiumAboveTheBoundFailsClosed() public {
        vm.prank(alice);
        uint256 id = vault.createPlan(1, 10_000e6, 1_000e6, 30 days);
        vm.warp(block.timestamp + 30 days);
        swapper.setHaircutBps(150); // 1.5% premium: inside the 5% breaker, over the 1% bound
        vm.prank(alice);
        vm.expectRevert(bytes("SLIPPAGE"));
        vault.executeDCA(id);
        (,,, uint32 done, bool act) = _p(vault, id);
        assertEq(done, 1);
        assertTrue(act, "the plan must wait, not close");
        swapper.setHaircutBps(50);
        vm.prank(alice);
        vault.executeDCA(id);
    }
}
