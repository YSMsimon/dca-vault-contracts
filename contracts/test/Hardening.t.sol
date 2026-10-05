// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle} from "../src/adapters/ChainlinkOracle.sol";
import {AerodromeSwapAdapter} from "../src/adapters/AerodromeSwapAdapter.sol";
import {SafeTransfer} from "../src/libs/SafeTransfer.sol";
import {
    MockERC20,
    MockStock,
    MockYieldAdapter,
    MockPriceOracle,
    MockSwapAdapter
} from "../src/mocks/Mocks.sol";
import {
    CpammSwap,
    Sandwicher,
    FakeClPool,
    FakeFeed,
    BlockableUSDC,
    SafeTransferHarness,
    RegistryOracle
} from "./utils/HostileVenues.sol";

/// @notice The hardening plan (docs, 2026-09-28), one finding at a time.
/// @dev    Every test here started life as a reproduction in the hard test of
///         an earlier revision that PASSED against the unfixed vault by
///         demonstrating the bug. Each is rewritten to assert the SAFE
///         behaviour, so it fails if the bug comes back. The test name carries
///         the plan item (C1..C10); C11 is the invariant suites
///         (Invariants.t.sol, HardInvariants.t.sol). A "Before (...)" note
///         names the original reproduction (Repros.*, AuditPoC.*); those are
///         not published.
contract HardeningTest is Test {
    MockERC20 usdc;
    MockStock stock;
    MockYieldAdapter y;
    MockPriceOracle oracle;
    MockSwapAdapter swapper;
    DcaVault vault;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xC0FFEE);
    address stranger = address(0xBAD);
    uint256 constant PX = 227_56000000;

    function setUp() public {
        vm.warp(1_780_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("Mock NVDAc", "NVDAc");
        y = new MockYieldAdapter(usdc);
        oracle = new MockPriceOracle();
        swapper = new MockSwapAdapter(usdc, stock, oracle);
        oracle.setPrice(address(stock), PX);
        vault = _vault(10_000_000e6);
        vault.setKeeper(keeper, true);
        _fund(alice, address(vault));
        _fund(bob, address(vault));
    }

    // ------------------------------------------------------------ helpers
    function _route(address token, address pool) internal view returns (DcaVault.Route memory) {
        return DcaVault.Route({
            token: token, pool: pool, feed: address(oracle), dexKind: 0, enabled: true
        });
    }

    function _vault(uint256 cap) internal returns (DcaVault v) {
        v = new DcaVault(IERC20(address(usdc)), y, swapper, oracle, cap);
        y.bindVault(address(v));
        v.initRoute(1, _route(address(stock), address(swapper)));
        v.finishSetup();
    }

    function _fund(address who, address spender) internal {
        usdc.mint(who, 1_000_000e6);
        vm.prank(who);
        usdc.approve(spender, type(uint256).max);
    }

    function _plan(address who, uint256 dep, uint256 inst) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.createPlan(1, dep, inst, 30 days);
    }

    function _active(DcaVault v, uint256 id) internal view returns (bool a) {
        (,,,,,,,, a) = v.plans(id);
    }

    function _rem(DcaVault v, uint256 id) internal view returns (uint256 r) {
        (,,, r,,,,,) = v.plans(id);
    }

    function _shares(DcaVault v, uint256 id) internal view returns (uint256 s) {
        (,,,, s,,,,) = v.plans(id);
    }

    /// A REAL loss on the lending leg: the share price falls and the assets
    /// actually leave, so the mock is exactly solvent at the new price.
    function _loss(uint256 wad) internal {
        y.setSharePrice(y.sharePriceWad() * wad / 1e18);
        uint256 owed = y.assetsOf(y.totalShares());
        uint256 have = usdc.balanceOf(address(y));
        if (have > owed) {
            vm.prank(address(y));
            usdc.transfer(address(0xdead), have - owed);
        }
    }

    // ================================================================ C1
    /// Before: `admin` was set once and there was no function to change it,
    /// so Deploy.s.sol's "transfer to multisig manually" could never happen.
    function test_C1_AdminHandoverIsTwoStep() public {
        address ms = address(0x4D5);
        vm.expectEmit(true, true, false, false, address(vault));
        emit DcaVault.AdminTransferStarted(address(this), ms);
        vault.transferAdmin(ms);
        assertEq(vault.admin(), address(this), "handover took effect before acceptance");

        vm.prank(stranger);
        vm.expectRevert(DcaVault.NotPendingAdmin.selector);
        vault.acceptAdmin();

        vm.expectEmit(true, true, false, false, address(vault));
        emit DcaVault.AdminTransferred(address(this), ms);
        vm.prank(ms);
        vault.acceptAdmin();
        assertEq(vault.admin(), ms);
        assertEq(vault.pendingAdmin(), address(0));

        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.setKeeper(address(1), true);
        vm.prank(ms);
        vault.setKeeper(address(1), true);
    }

    /// Before (Repros.test_AdminCanRedirectLiveRouteToAFakePool): the admin
    /// re-pointed a live route at an attacker pool and the REAL Aerodrome
    /// adapter handed the next installment to it. Now a route's token and pool
    /// are fixed for life and the setup window is shut by the first plan.
    function test_C1_LiveRouteCannotBeRepointedAtAFakePool() public {
        ChainlinkOracle cl = new ChainlinkOracle(address(0), false);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        AerodromeSwapAdapter aero = new AerodromeSwapAdapter(IERC20(address(usdc)), predicted);
        DcaVault v3 = new DcaVault(IERC20(address(usdc)), y, aero, cl, 10_000_000e6);
        assertEq(address(v3), predicted);
        y.bindVault(address(v3));

        MockStock good = new MockStock("good", "GOOD");
        FakeFeed feed = new FakeFeed(); // $1.00, always fresh
        FakeClPool goodPool = new FakeClPool(address(usdc), address(good), 2, 1_000e8);
        cl.setFeed(address(good), address(feed));
        v3.initRoute(1, DcaVault.Route(address(good), address(goodPool), address(feed), 0, true));
        v3.finishSetup();

        vm.prank(alice);
        usdc.approve(address(v3), type(uint256).max);
        vm.prank(alice);
        uint256 id = v3.createPlan(1, 10_000e6, 1_000e6, 30 days);

        // The attack, every way it can be phrased.
        MockStock junk = new MockStock("junk", "JUNK");
        FakeClPool evil = new FakeClPool(address(usdc), address(junk), 0, 0);
        cl.setFeed(address(junk), address(feed)); // a NEW token may be listed instantly
        vm.expectRevert(DcaVault.SetupClosed.selector);
        v3.initRoute(1, DcaVault.Route(address(junk), address(evil), address(feed), 0, true));
        vm.expectRevert(DcaVault.RouteImmutable.selector);
        v3.queueRoute(1, DcaVault.Route(address(junk), address(evil), address(feed), 0, true));
        vm.expectRevert(DcaVault.RouteImmutable.selector);
        v3.queueRoute(1, DcaVault.Route(address(good), address(evil), address(feed), 0, true));

        // ...and the plan's next installment still goes where it always did.
        vm.warp(block.timestamp + 30 days + 12 hours);
        uint256 before = good.balanceOf(alice);
        vm.prank(stranger);
        v3.executeDCA(id);
        assertEq(usdc.balanceOf(address(evil)), 0, "an installment reached the attacker pool");
        assertEq(good.balanceOf(alice) - before, 1_000e8, "the plan did not buy its own asset");
        assertEq(junk.balanceOf(alice), 0);
    }

    /// Before (AuditPoC.test_AdminRetargetsExistingPlan): setRoute swapped the
    /// token under a live plan and the plan bought a different asset.
    function test_C1_ExistingPlanCannotBeRetargetedAtAnotherToken() public {
        uint256 id = _plan(alice, 2_000e6, 1_000e6);
        MockStock other = new MockStock("Other", "OTH");
        oracle.setPrice(address(other), 1e8);
        vm.expectRevert(DcaVault.RouteImmutable.selector);
        vault.queueRoute(1, _route(address(other), address(swapper)));

        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        vault.executeDCA(id);
        assertEq(other.balanceOf(alice), 0, "plan bought a different asset");
    }

    function test_C1_NewRouteWaitsOutTheDelay() public {
        _plan(alice, 2_000e6, 1_000e6); // setUp's finishSetup closed the window
        MockStock s2 = new MockStock("Second", "TWO");
        oracle.setPrice(address(s2), 100e8);

        vm.expectRevert(DcaVault.SetupClosed.selector);
        vault.initRoute(2, _route(address(s2), address(swapper)));

        uint64 eta = uint64(block.timestamp) + vault.ADMIN_DELAY();
        vm.expectEmit(true, false, false, true, address(vault));
        emit DcaVault.RouteQueued(2, address(s2), address(swapper), address(oracle), true, eta);
        vault.queueRoute(2, _route(address(s2), address(swapper)));

        vm.prank(bob);
        vm.expectRevert(DcaVault.RouteDisabled.selector);
        vault.createPlan(2, 1_000e6, 100e6, 30 days);

        vm.expectRevert(abi.encodeWithSelector(DcaVault.TimelockActive.selector, eta));
        vault.activateRoute(2);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(DcaVault.TimelockActive.selector, eta));
        vault.activateRoute(2);

        vm.warp(eta);
        oracle.setPrice(address(s2), 100e8); // keep the mock feed's timestamp current
        oracle.setPrice(address(stock), PX);
        vm.expectEmit(true, false, false, true, address(vault));
        emit DcaVault.RouteSet(2, address(s2), address(swapper), true);
        vault.activateRoute(2);

        vm.prank(bob);
        vault.createPlan(2, 1_000e6, 100e6, 30 days);
        assertGt(s2.balanceOf(bob), 0);
    }

    /// Disabling is the one instant route power: it can stop the protocol,
    /// never redirect it. Turning a route back ON is a change like any other.
    function test_C1_DisableIsInstantButReEnableIsQueued() public {
        uint256 id = _plan(alice, 3_000e6, 1_000e6);

        vm.expectEmit(true, false, false, true, address(vault));
        emit DcaVault.RouteSet(1, address(stock), address(swapper), false);
        vault.disableRoute(1);

        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        vm.expectRevert(DcaVault.RouteDisabled.selector);
        vault.executeDCA(id);

        vault.queueRoute(1, _route(address(stock), address(swapper)));
        vm.expectRevert();
        vault.activateRoute(1);
        vm.warp(block.timestamp + 48 hours);
        oracle.setPrice(address(stock), PX);
        vault.activateRoute(1);

        vm.prank(alice);
        vault.executeDCA(id);
        (,,,,,,, uint32 done,) = vault.plans(id);
        assertEq(done, 2);
    }

    function test_C1_QueuedRouteCanBeCancelled() public {
        MockStock s2 = new MockStock("Second", "TWO");
        vault.queueRoute(2, _route(address(s2), address(swapper)));
        vm.expectEmit(true, false, false, false, address(vault));
        emit DcaVault.RouteCancelled(2);
        vault.cancelRoute(2);

        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(DcaVault.NothingQueued.selector);
        vault.activateRoute(2);
        vm.expectRevert(DcaVault.NothingQueued.selector);
        vault.cancelRoute(2);
    }

    function test_C1_EveryAdminPowerIsAdminOnly() public {
        DcaVault.Route memory r = _route(address(stock), address(swapper));
        vm.startPrank(stranger);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.initRoute(9, r);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.queueRoute(9, r);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.activateRoute(9);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.cancelRoute(9);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.disableRoute(1);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.transferAdmin(stranger);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.setFee(1);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.setFeeRecipient(stranger);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.setBounds(100, 500);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.setTvlCap(1);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.setDepositsPaused(true);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.setKeeper(stranger, true);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.finishSetup();
        vm.stopPrank();
    }

    function test_C1_EverySetterEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit DcaVault.FeeSet(250);
        vault.setFee(250);

        vm.expectEmit(true, false, false, false, address(vault));
        emit DcaVault.FeeRecipientSet(address(0xFEE));
        vault.setFeeRecipient(address(0xFEE));

        vm.expectEmit(false, false, false, true, address(vault));
        emit DcaVault.BoundsSet(80, 400);
        vault.setBounds(80, 400);

        vm.expectEmit(false, false, false, true, address(vault));
        emit DcaVault.TvlCapSet(123e6);
        vault.setTvlCap(123e6);

        vm.expectEmit(false, false, false, true, address(vault));
        emit DcaVault.DepositsPausedSet(true);
        vault.setDepositsPaused(true);

        vm.expectEmit(true, false, false, true, address(vault));
        emit DcaVault.KeeperSet(address(7), true);
        vault.setKeeper(address(7), true);
    }

    /// The oracle had the same hole: a feed could be swapped under a live
    /// route instantly, by an admin that could never be handed over.
    function test_C1_OracleFeedChangesAreQueuedAndAdminIsTwoStep() public {
        ChainlinkOracle cl = new ChainlinkOracle(address(0), false);
        FakeFeed f1 = new FakeFeed();
        FakeFeed f2 = new FakeFeed();
        address tok = address(0x70C);

        vm.expectEmit(true, true, false, false, address(cl));
        emit ChainlinkOracle.FeedSet(tok, address(f1));
        cl.setFeed(tok, address(f1)); // first listing: instant

        vm.expectRevert(ChainlinkOracle.FeedAlreadySet.selector);
        cl.setFeed(tok, address(f2));

        uint64 eta = uint64(block.timestamp) + cl.ADMIN_DELAY();
        vm.expectEmit(true, true, false, true, address(cl));
        emit ChainlinkOracle.FeedQueued(tok, address(f2), eta);
        cl.queueFeed(tok, address(f2));
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.TimelockActive.selector, eta));
        cl.activateFeed(tok);
        assertEq(cl.feedOf(tok), address(f1));

        vm.warp(eta);
        cl.activateFeed(tok);
        assertEq(cl.feedOf(tok), address(f2));

        cl.queueFeed(tok, address(f1));
        cl.cancelFeed(tok);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(ChainlinkOracle.NothingQueued.selector);
        cl.activateFeed(tok);

        vm.startPrank(stranger);
        vm.expectRevert(ChainlinkOracle.NotAdmin.selector);
        cl.setFeed(address(0x1), address(f1));
        vm.expectRevert(ChainlinkOracle.NotAdmin.selector);
        cl.queueFeed(tok, address(f1));
        vm.expectRevert(ChainlinkOracle.NotAdmin.selector);
        cl.activateFeed(tok);
        vm.expectRevert(ChainlinkOracle.NotAdmin.selector);
        cl.cancelFeed(tok);
        vm.expectRevert(ChainlinkOracle.NotAdmin.selector);
        cl.transferAdmin(stranger);
        vm.expectRevert(ChainlinkOracle.NotPendingAdmin.selector);
        cl.acceptAdmin();
        vm.stopPrank();

        address ms = address(0x4D5);
        cl.transferAdmin(ms);
        assertEq(cl.admin(), address(this));
        vm.prank(ms);
        cl.acceptAdmin();
        assertEq(cl.admin(), ms);
    }

    /// The indexer and the web app decode these. Changing a signature breaks
    /// both silently, so pin every one.
    function test_C1_IndexedEventSignaturesAreUnchanged() public pure {
        assertEq(
            DcaVault.PlanCreated.selector, keccak256("PlanCreated(uint256,address,uint32,uint256)")
        );
        assertEq(
            DcaVault.DCAExecuted.selector,
            keccak256("DCAExecuted(uint256,uint256,uint256,uint256,uint256)")
        );
        assertEq(DcaVault.PlanExited.selector, keccak256("PlanExited(uint256,uint256,uint256)"));
        assertEq(DcaVault.PlanCompleted.selector, keccak256("PlanCompleted(uint256,uint32)"));
        assertEq(DcaVault.RouteSet.selector, keccak256("RouteSet(uint32,address,address,bool)"));
        assertEq(DcaVault.KeeperSet.selector, keccak256("KeeperSet(address,bool)"));
    }

    // ================================================================ C2
    /// Before (Repros.test_SandwichWithinDivergenceBand): anyone allowed to
    /// call executeDCA pushed a real constant-product pool ~4.9%, executed and
    /// unwound in one transaction; the victim lost >400bp against the feed and
    /// the attacker kept the difference. minOut came from the pool's own spot.
    function test_C2_SandwichPastTheBoundReverts() public {
        (DcaVault v2, CpammSwap pool, uint256 id) = _cpammPlan();
        vm.warp(block.timestamp + 30 days + 12 hours); // due + grace: anyone
        Sandwicher s = new Sandwicher();
        uint256 push = 100_000e6; // ~2.4% of reserve => ~4.9% price move
        usdc.mint(address(s), push); // stands in for a flash loan

        vm.expectRevert(bytes("SLIPPAGE"));
        s.run(v2, pool, usdc, stock, id, push);
    }

    /// A push small enough to pass is, by construction, one that costs the
    /// victim no more than maxSlippageBps against the feed.
    function test_C2_SandwichInsideTheBoundCostsAtMostTheBound() public {
        (DcaVault v2, CpammSwap pool, uint256 id) = _cpammPlan();
        vm.warp(block.timestamp + 30 days + 12 hours);
        Sandwicher s = new Sandwicher();
        uint256 push = 10_000e6;
        usdc.mint(address(s), push);

        (uint256 ref,) = oracle.latestPrice(address(stock));
        uint256 before = stock.balanceOf(alice);
        s.run(v2, pool, usdc, stock, id, push);
        uint256 got = stock.balanceOf(alice) - before;
        uint256 fair = 10_000e6 * 1e10 / ref;
        assertGe(
            got * 10_000,
            fair * (10_000 - v2.maxSlippageBps()),
            "victim filled worse than the stated bound"
        );
    }

    function _cpammPlan() internal returns (DcaVault v2, CpammSwap pool, uint256 id) {
        pool = new CpammSwap(usdc, stock, 5_000_000e6, 5_000_000e6 * 1e10 / PX);
        oracle.setPrice(address(stock), pool.poolPrice(address(0), address(0)));
        v2 = new DcaVault(IERC20(address(usdc)), y, pool, oracle, 10_000_000e6);
        y.bindVault(address(v2));
        v2.initRoute(1, _route(address(stock), address(pool)));
        v2.finishSetup();
        vm.startPrank(alice);
        usdc.approve(address(v2), type(uint256).max);
        id = v2.createPlan(1, 100_000e6, 10_000e6, 30 days);
        vm.stopPrank();
        // The feed keeps printing the pre-attack price, fresh: the attacker
        // moves the pool, not Chainlink.
    }

    /// Before (AuditPoC.test_ManipulatedPoolFillsAt5pctPremium): a pool held
    /// 4.99% above the feed filled a stranger-triggered execution >4.7% worse
    /// than fair. The fill is now bounded against the feed.
    function test_C2_PoolPremiumPastTheBoundCannotFill() public {
        uint256 id = _plan(alice, 2_000e6, 1_000e6);
        vm.warp(block.timestamp + 30 days + 12 hours);
        oracle.setPrice(address(stock), PX);
        swapper.setHaircutBps(499);
        vm.prank(stranger);
        vm.expectRevert(bytes("SLIPPAGE"));
        vault.executeDCA(id);
    }

    /// The flip side, so the bound is not simply "revert everything": a real
    /// premium inside it (GOOGLc sat 38bp over its feed) still fills.
    function test_C2_PremiumInsideTheBoundStillFills() public {
        uint256 id = _plan(alice, 2_000e6, 1_000e6);
        vm.warp(block.timestamp + 30 days);
        oracle.setPrice(address(stock), PX);
        swapper.setHaircutBps(38);
        uint256 before = stock.balanceOf(alice);
        vm.prank(keeper);
        vault.executeDCA(id);
        uint256 got = stock.balanceOf(alice) - before;
        uint256 fair = 1_000e6 * 1e10 / PX;
        assertGe(got * 10_000, fair * (10_000 - vault.maxSlippageBps()));
        assertLt(got, fair, "the premium should cost something");
    }

    function test_C2_TheBoundHasAHardCeiling() public {
        assertEq(vault.maxSlippageBps(), 100);
        assertEq(vault.maxDeviationBps(), 500);
        uint16 maxSlip = vault.MAX_SLIPPAGE_BPS();
        uint16 maxDev = vault.MAX_DEVIATION_BPS();
        assertEq(maxSlip, 200);
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.setBounds(maxSlip + 1, 500);
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.setBounds(100, maxDev + 1);
        vault.setBounds(maxSlip, maxDev);
    }

    // ================================================================ C3
    /// Before (Repros.test_LossMakesFinalInstallmentPanicForever): after a 1%
    /// lending loss, month 2 bought a full installment and month 3 reverted
    /// Panic(0x11) on every retry, forever.
    function test_C3_LossNeverMakesTheFinalInstallmentPanic() public {
        uint256 id = _plan(alice, 3_000e6, 1_000e6);
        uint256 other = _plan(bob, 50_000e6, 1_000e6);
        _loss(0.99e18);

        vm.warp(block.timestamp + 30 days);
        oracle.setPrice(address(stock), PX);
        vm.prank(alice);
        vault.executeDCA(id);

        vm.warp(block.timestamp + 30 days);
        oracle.setPrice(address(stock), PX);
        vm.recordLogs();
        vm.prank(alice);
        vault.executeDCA(id); // month 3: completes, never Panics

        assertFalse(_active(vault, id), "the final installment did not complete");
        assertEq(_rem(vault, id), 0);
        assertEq(_shares(vault, id), 0);
        assertEq(vault.totalPrincipal(), _rem(vault, other), "principal ledger drifted");
        assertEq(vault.totalManagedShares(), _shares(vault, other), "share ledger drifted");

        uint256 shortfall = _shortfallFrom(vm.getRecordedLogs());
        // ~1% of the 2,000 that was live during the loss lands on this plan.
        assertApproxEqAbs(shortfall, 20e6, 1e6, "the loss was not reported where it landed");
    }

    function _shortfallFrom(Vm.Log[] memory logs) internal pure returns (uint256 s) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == DcaVault.PlanShortfall.selector) {
                s += abi.decode(logs[i].data, (uint256));
            }
        }
    }

    /// Before (AuditPoC.test_FinalInstallmentRevertsWithoutInterest): at a
    /// non-par share price with no interest since the last slice, the final
    /// installment of many ordinary two-period plans reverted.
    function test_C3_FinalInstallmentWithoutInterestAlwaysCompletes() public {
        _plan(bob, 1_000e6, 100e6);
        y.accrueTo(1.037123456789e18);
        for (uint256 k = 1; k <= 20; k++) {
            uint256 inst = 100e6 + k * 13;
            uint256 id = _plan(alice, 2 * inst, inst);
            vm.warp(block.timestamp + 30 days);
            oracle.setPrice(address(stock), PX);
            vm.prank(alice);
            vault.executeDCA(id); // must not revert
            assertFalse(_active(vault, id));
        }
    }

    /// A loss big enough that the plan's shares no longer cover even this
    /// slice: the plan spends what is left and ends. It does not revert, and
    /// it does not linger with principal and no shares.
    function test_C3_ALossBiggerThanASliceEndsThePlanInsteadOfReverting() public {
        uint256 id = _plan(alice, 5_000e6, 1_000e6);
        _loss(0.2e18); // 4,000 of principal now worth ~800
        vm.warp(block.timestamp + 30 days);
        oracle.setPrice(address(stock), PX);
        vm.recordLogs();
        vm.prank(alice);
        vault.executeDCA(id);
        assertFalse(_active(vault, id));
        assertEq(vault.totalPrincipal(), 0);
        assertEq(vault.totalManagedShares(), 0);
        assertApproxEqAbs(_shortfallFrom(vm.getRecordedLogs()), 3_200e6, 1e6);
    }

    // ================================================================ C4
    /// Before (Repros.test_OneShotPlanPanicsWhenSharePriceIsNotOne,
    /// AuditPoC.test_SingleInstallmentPlanReverts, Halmos P4): a one-period
    /// plan Panicked at create whenever the share price was not exactly 1.0.
    function test_C4_OneShotPlanAtNonParSharePrice() public {
        y.accrueTo(1.07e18);
        vm.prank(alice);
        uint256 id = vault.createPlan(1, 1_000e6, 1_000e6, 30 days);
        assertFalse(_active(vault, id), "one-shot plan should complete at create");
        assertGt(stock.balanceOf(alice), 0);

        _plan(bob, 1_000e6, 100e6);
        y.accrueTo(1.037123456789e18);
        vm.prank(alice);
        vault.createPlan(1, 1_000e6 + 7, 1_000e6 + 7, 30 days);
    }

    function testFuzz_C4_OneShotPlanNeverReverts(uint256 dep, uint256 px) public {
        dep = bound(dep, 1e6, 1_000_000e6);
        px = bound(px, 1e18, 2e18);
        _plan(bob, 1_000e6, 100e6); // pooled shares exist
        y.accrueTo(px);
        vm.prank(alice);
        uint256 id = vault.createPlan(1, dep, dep, 30 days);
        assertFalse(_active(vault, id));
        assertEq(vault.totalManagedShares(), _shares(vault, 1));
    }

    // ================================================================ C5
    /// Before (Repros.test_HaltedFeedDoesNotStallExecutions): with the feed
    /// stale the band was hard-coded to 500bp, so executions carried on 4.9%
    /// off a frozen print — and silently ignored an admin who had tightened
    /// the band to 1%.
    function test_C5_StaleFeedStopsExecutions() public {
        uint256 id = _plan(alice, 10_000e6, 1_000e6);
        oracle.setFresh(false);
        vm.warp(block.timestamp + 30 days);
        swapper.setHaircutBps(490);
        vm.prank(alice);
        vm.expectRevert(DcaVault.StaleOracle.selector);
        vault.executeDCA(id);

        // And the admin's band is the band, fresh or not.
        oracle.setFresh(true);
        vault.setBounds(100, 100);
        swapper.setHaircutBps(150);
        uint256 poolPx = swapper.poolPrice(address(0), address(stock));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DcaVault.PoolDiverged.selector, PX, poolPx));
        vault.executeDCA(id);
    }

    /// A deposit on a frozen feed does not revert (that would break the
    /// deposit button every weekend) and does not buy (that would buy against
    /// a frozen print). The plan opens already due and waits.
    function test_C5_DepositOnAFrozenFeedDefersTheFirstBuy() public {
        oracle.setFresh(false);
        uint256 id = _plan(alice, 2_000e6, 1_000e6);
        (,,, uint256 rem,, uint64 next,, uint32 done, bool active) = vault.plans(id);
        assertTrue(active);
        assertEq(done, 0);
        assertEq(rem, 2_000e6);
        assertEq(next, block.timestamp);
        assertEq(stock.balanceOf(alice), 0);

        vm.prank(keeper);
        vm.expectRevert(DcaVault.StaleOracle.selector);
        vault.executeDCA(id);

        oracle.setFresh(true);
        vm.prank(keeper);
        vault.executeDCA(id);
        (,,,,,,, done,) = vault.plans(id);
        assertEq(done, 1);
        assertGt(stock.balanceOf(alice), 0);
    }

    function test_C5_OracleRejectsBrokenRounds() public {
        ChainlinkOracle cl = new ChainlinkOracle(address(0), false);
        FakeFeed f = new FakeFeed();
        address tok = address(0x70C);
        cl.setFeed(tok, address(f));

        f.set(1e8, 0, false); // never updated
        vm.expectRevert(ChainlinkOracle.BadPrice.selector);
        cl.latestPrice(tok);
        assertFalse(cl.isFresh(tok));

        f.set(1e8, block.timestamp + 1 hours, false); // from the future
        vm.expectRevert(ChainlinkOracle.BadPrice.selector);
        cl.latestPrice(tok);
        assertFalse(cl.isFresh(tok), "a future timestamp must not read as fresh (or Panic)");

        f.set(-1, block.timestamp, false);
        vm.expectRevert(ChainlinkOracle.BadPrice.selector);
        cl.latestPrice(tok);
        assertFalse(cl.isFresh(tok));

        f.set(1e8, block.timestamp - 25 hours, false); // weekend
        (uint256 px,) = cl.latestPrice(tok);
        assertEq(px, 1e8);
        assertFalse(cl.isFresh(tok));

        f.set(1e8, block.timestamp - 1 hours, false);
        assertTrue(cl.isFresh(tok));
    }

    function test_C5_SetFeedChecksDecimals() public {
        ChainlinkOracle cl = new ChainlinkOracle(address(0), false);
        FakeFeed f = new FakeFeed();
        f.setDecimals(18);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.BadDecimals.selector, uint8(18)));
        cl.setFeed(address(1), address(f));
        vm.expectRevert(ChainlinkOracle.BadFeed.selector);
        cl.setFeed(address(1), address(0xE0A)); // no code
        vm.expectRevert(ChainlinkOracle.BadFeed.selector);
        cl.setFeed(address(1), address(0));

        FakeFeed ok = new FakeFeed();
        cl.setFeed(address(1), address(ok));
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.BadDecimals.selector, uint8(18)));
        cl.queueFeed(address(1), address(f));
    }

    // ================================================================ C6
    /// Before (AuditPoC.test_CapGriefing_OneWeiInstallment): one 1-wei
    /// installment plan held the entire $5,000 cap indefinitely for free.
    function test_C6_DustInstallmentCannotSquatTheCap() public {
        DcaVault v5 = _vault(5_000e6);
        _fund(bob, address(v5));
        _fund(alice, address(v5));

        vm.startPrank(bob);
        vm.expectRevert(DcaVault.BadParams.selector);
        v5.createPlan(1, 5_000e6, 1, 1 days);
        vm.expectRevert(DcaVault.BadParams.selector);
        v5.createPlan(1, 5_000e6, 1e6 - 1, 30 days); // under MIN_INSTALLMENT
        vm.expectRevert(DcaVault.BadParams.selector);
        v5.createPlan(1, 121e6, 1e6, 30 days); // 121 periods
        v5.createPlan(1, 120e6, 1e6, 30 days); // exactly MAX_PERIODS is fine
        vm.stopPrank();

        vm.prank(alice);
        v5.createPlan(1, 100e6, 10e6, 30 days);
    }

    /// The cap is OUTSTANDING principal: money already spent on stock or
    /// returned on exit frees room. And lowering the cap below what is
    /// outstanding refuses new plans; it never underflows.
    function test_C6_CapCountsOutstandingPrincipal() public {
        DcaVault v5 = _vault(5_000e6);
        _fund(bob, address(v5));
        _fund(alice, address(v5));

        vm.prank(alice);
        uint256 a = v5.createPlan(1, 5_000e6, 1_000e6, 30 days);
        assertEq(v5.totalPrincipal(), 4_000e6, "the first buy should free its slice");
        vm.prank(bob);
        v5.createPlan(1, 1_000e6, 100e6, 30 days);
        vm.prank(bob);
        vm.expectRevert(DcaVault.CapExceeded.selector);
        v5.createPlan(1, 101e6, 101e6, 30 days);

        vm.prank(alice);
        v5.exitPlan(a);
        vm.prank(bob);
        v5.createPlan(1, 4_000e6, 1_000e6, 30 days);

        v5.setTvlCap(1_000e6); // below what is outstanding
        vm.prank(bob);
        vm.expectRevert(DcaVault.CapExceeded.selector);
        v5.createPlan(1, 1e6, 1e6, 30 days);
    }

    // ================================================================ C7
    /// Before: the fee was PUSHED to feeRecipient inside exitPlan, so a
    /// recipient on USDC's blocklist made every exit with accrued yield revert,
    /// and there was no setter to move it.
    function test_C7_BlocklistedFeeRecipientCannotBlockAnExit() public {
        BlockableUSDC bu = new BlockableUSDC();
        MockYieldAdapter y2 = new MockYieldAdapter(bu);
        MockSwapAdapter sw2 = new MockSwapAdapter(bu, stock, oracle);
        DcaVault v7 = new DcaVault(IERC20(address(bu)), y2, sw2, oracle, 10_000_000e6);
        y2.bindVault(address(v7));
        v7.initRoute(1, _route(address(stock), address(sw2)));
        v7.finishSetup();
        address treasury = address(0x7EA);
        v7.setFeeRecipient(treasury);
        v7.setFee(1_000);

        bu.mint(alice, 100_000e6);
        vm.startPrank(alice);
        bu.approve(address(v7), type(uint256).max);
        uint256 id = v7.createPlan(1, 10_000e6, 1_000e6, 30 days);
        vm.stopPrank();

        y2.accrueTo(1.1e18);
        bu.setBlocked(treasury, true);

        vm.warp(block.timestamp + 30 days);
        oracle.setPrice(address(stock), PX);
        vm.prank(alice);
        v7.executeDCA(id); // a fee accrues; nothing is pushed
        uint256 afterExec = v7.feesAccrued();
        assertGt(afterExec, 0);

        y2.accrueTo(1.2e18); // more yield, so the exit owes a fee too
        vm.prank(alice);
        v7.exitPlan(id); // must not revert
        assertGt(v7.feesAccrued(), afterExec);
        assertFalse(_active(v7, id));

        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        v7.claimFees();

        address treasury2 = address(0x7EB);
        v7.setFeeRecipient(treasury2);
        uint256 owed = v7.feesAccrued();
        vm.expectEmit(true, false, false, true, address(v7));
        emit DcaVault.FeesClaimed(treasury2, owed);
        vm.prank(stranger); // anyone may trigger it; nobody may redirect it
        v7.claimFees();
        assertEq(bu.balanceOf(treasury2), owed);
        assertEq(v7.feesAccrued(), 0);
        assertEq(bu.balanceOf(address(v7)), 0, "vault kept USDC that is nobody's");
    }

    function test_C7_FeeRecipientCannotBeZero() public {
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.setFeeRecipient(address(0));
    }

    // ================================================================ C8
    /// Before (Repros.test_HugeIntervalWrapsScheduleAndAllowsSameBlockLoop):
    /// an interval near 2^64 wrapped nextExecution into the past, and a
    /// stranger fired all ten installments in one block.
    function test_C8_HugeIntervalIsRejected() public {
        uint64 maxIv = vault.MAX_INTERVAL();
        uint64 minIv = vault.MIN_INTERVAL();
        vm.startPrank(alice);
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.createPlan(1, 10_000e6, 1_000e6, type(uint64).max - 13 hours);
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.createPlan(1, 10_000e6, 1_000e6, maxIv + 1);
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.createPlan(1, 10_000e6, 1_000e6, minIv - 1);
        uint256 id = vault.createPlan(1, 10_000e6, 1_000e6, maxIv);
        vm.stopPrank();
        (,,,,, uint64 next,,,) = vault.plans(id);
        assertEq(next, block.timestamp + 366 days);
    }

    function testFuzz_C8_NextExecutionIsAlwaysInTheFuture(uint64 iv, uint256 late) public {
        iv = uint64(bound(iv, 1 days, 366 days));
        vm.prank(alice);
        uint256 id = vault.createPlan(1, 10_000e6, 1_000e6, iv);
        (,,,,, uint64 due,,,) = vault.plans(id);
        assertGt(due, block.timestamp);

        vm.warp(uint256(due) + bound(late, 0, 5 * 366 days));
        oracle.setPrice(address(stock), PX);
        uint256 publicFrom = uint256(due) + vault.grace();
        vm.prank(stranger);
        if (block.timestamp < publicFrom) {
            vm.expectRevert(DcaVault.TooEarlyForPublicCall.selector);
            vault.executeDCA(id);
            vm.prank(alice);
        }
        vault.executeDCA(id);
        (,,,,, uint64 next,,,) = vault.plans(id);
        assertGt(next, block.timestamp, "schedule stepped into the past");
        vm.prank(alice);
        vm.expectRevert(DcaVault.NotYetDue.selector);
        vault.executeDCA(id);
    }

    // =============================================================== C10
    /// Before: `Route.feed` was stored and never read, so the registry could
    /// claim one feed while the price came from another.
    function test_C10_RouteFeedMustMatchTheOracle() public {
        RegistryOracle ro = new RegistryOracle();
        DcaVault vr = new DcaVault(IERC20(address(usdc)), y, swapper, ro, 10_000_000e6);
        y.bindVault(address(vr));
        address f = address(0xF1);
        address g = address(0xF2);
        ro.setFeedFor(address(stock), f);

        DcaVault.Route memory r =
            DcaVault.Route({token: address(stock), pool: address(swapper), feed: g, dexKind: 0, enabled: true});
        vm.expectRevert(DcaVault.FeedMismatch.selector);
        vr.initRoute(1, r);
        r.feed = address(0);
        vm.expectRevert(DcaVault.FeedMismatch.selector);
        vr.initRoute(1, r);
        r.feed = f;
        vr.initRoute(1, r);

        // Re-checked at activation: the oracle rotated its feed meanwhile.
        MockStock s2 = new MockStock("Second", "TWO");
        ro.setFeedFor(address(s2), f);
        vm.expectRevert(DcaVault.FeedMismatch.selector);
        vr.queueRoute(2, DcaVault.Route(address(s2), address(swapper), g, 0, true));
        vr.queueRoute(2, DcaVault.Route(address(s2), address(swapper), f, 0, true));
        ro.setFeedFor(address(s2), g);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(DcaVault.FeedMismatch.selector);
        vr.activateRoute(2);
    }

    function test_C10_RouteNeedsATokenAndAPool() public {
        // queueRoute: setUp already closed the setup window, and both paths
        // share _checkRoute.
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.queueRoute(5, _route(address(0), address(swapper)));
        vm.expectRevert(DcaVault.BadParams.selector);
        vault.queueRoute(5, _route(address(stock), address(0)));
    }

    /// A low-level call to an address with no code SUCCEEDS with empty return
    /// data — which the "token returns nothing" branch used to read as a
    /// transfer that happened.
    function test_C10_SafeTransferRefusesAnAddressWithNoCode() public {
        address ghost = address(0x60057);
        (bool ok, bytes memory data) =
            ghost.call(abi.encodeWithSelector(0xa9059cbb, alice, 1));
        assertTrue(ok && data.length == 0, "premise: a codeless call looks like success");

        SafeTransferHarness h = new SafeTransferHarness();
        vm.expectRevert(SafeTransfer.NoCode.selector);
        h.transfer(ghost, alice, 1);
        vm.expectRevert(SafeTransfer.NoCode.selector);
        h.transferFrom(ghost, alice, bob, 1);
        vm.expectRevert(SafeTransfer.NoCode.selector);
        h.approve(ghost, alice, 1);

        // and a real token still works
        usdc.mint(address(h), 5);
        h.transfer(address(usdc), alice, 5);
    }

    /// Before: the Aerodrome adapter took the pool's reported deltas as the
    /// output. A pool reporting 1e30 out and sending nothing passed any minOut.
    function test_C10_AerodromeAdapterMeasuresWhatActuallyArrived() public {
        AerodromeSwapAdapter aero = new AerodromeSwapAdapter(IERC20(address(usdc)), address(this));
        usdc.mint(address(this), 3_000e6);
        usdc.approve(address(aero), type(uint256).max);
        MockStock junk = new MockStock("junk", "JUNK");

        FakeClPool liar = new FakeClPool(address(usdc), address(junk), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(AerodromeSwapAdapter.Slippage.selector, 0, 1));
        aero.swapExactIn(address(liar), address(junk), 1_000e6, 1, alice);

        FakeClPool greedy = new FakeClPool(address(usdc), address(junk), 1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(AerodromeSwapAdapter.WrongInput.selector, 1_000e6 + 1, 1_000e6)
        );
        aero.swapExactIn(address(greedy), address(junk), 1_000e6, 1, alice);

        FakeClPool honest = new FakeClPool(address(usdc), address(junk), 2, 5e8);
        uint256 out = aero.swapExactIn(address(honest), address(junk), 1_000e6, 5e8, alice);
        assertEq(out, 5e8, "measured output is not what arrived");
        assertEq(junk.balanceOf(alice), 5e8);
        assertEq(usdc.balanceOf(address(aero)), 0, "USDC stranded in the adapter");
    }
}
