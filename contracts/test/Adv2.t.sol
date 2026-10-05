// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20, MockStock, MockYieldAdapter, MockPriceOracle, MockSwapAdapter} from "../src/mocks/Mocks.sol";
import {DemoUSDC, DemoStock, DemoYieldAdapter, DemoPriceOracle, DemoSwapAdapter} from "../src/mocks/DemoMocks.sol";
import {CpammSwap} from "./utils/HostileVenues.sol";

/// @notice The round-2 re-test's adversarial unit suite,
///         kept. The tests that demonstrated D1, D2, D5 and D7 moved to
///         Round2.t.sol, rewritten to assert the fix; what stays here are the
///         fuzzers and edge checks that passed against the hardened vault and
///         must keep passing.
contract Adv2Test is Test {
    MockERC20 usdc;
    MockStock stock;
    MockYieldAdapter y;
    MockPriceOracle oracle;
    MockSwapAdapter swapper;
    DcaVault vault;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
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
        vault.initRoute(1, DcaVault.Route(address(stock), address(swapper), address(oracle), 0, true));
        vault.finishSetup();
        _fund(alice, address(vault));
        _fund(bob, address(vault));
        _fund(carol, address(vault));
    }

    function _fund(address who, address sp) internal {
        usdc.mint(who, 1_000_000e6);
        vm.prank(who);
        usdc.approve(sp, type(uint256).max);
    }

    function _p(DcaVault v, uint256 id)
        internal
        view
        returns (uint256 rem, uint256 sh, uint64 ne, uint32 done, bool active)
    {
        (,,, rem, sh, ne,, done, active) = v.plans(id);
    }

    function _loss(uint256 wad) internal {
        y.setSharePrice(y.sharePriceWad() * wad / 1e18);
        uint256 owed = y.assetsOf(y.totalShares());
        uint256 have = usdc.balanceOf(address(y));
        if (have > owed) {
            vm.prank(address(y));
            usdc.transfer(address(0xdead), have - owed);
        }
    }

    // =========================================================== timelock
    /// Pending queues survive an admin handover; the new admin inherits them.
    function test_PendingSurvivesAdminHandover() public {
        vm.prank(alice);
        vault.createPlan(1, 10_000e6, 1_000e6, 30 days);
        MockStock t2 = new MockStock("T2", "T2");
        vault.queueRoute(7, DcaVault.Route(address(t2), address(swapper), address(oracle), 0, true));
        vault.transferAdmin(address(0xB055));
        vm.prank(address(0xB055));
        vault.acceptAdmin();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.activateRoute(7); // old admin cannot
        (,,,,, uint64 eta) = vault.pendingRoutes(7);
        assertGt(eta, 0, "still pending under the new admin");
    }

    /// Timelock boundary: exactly eta works, eta-1 does not.
    function testFuzz_ActivateNeverEarly(uint32 dt) public {
        vm.prank(alice);
        vault.createPlan(1, 10_000e6, 1_000e6, 30 days);
        MockStock t2 = new MockStock("T2", "T2");
        uint256 t0 = block.timestamp;
        vault.queueRoute(7, DcaVault.Route(address(t2), address(swapper), address(oracle), 0, true));
        vm.warp(t0 + (dt % (4 days)));
        try vault.activateRoute(7) {
            assertGe(block.timestamp, t0 + 48 hours);
        } catch {
            assertLt(block.timestamp, t0 + 48 hours);
        }
    }

    /// Re-queue resets the eta; a later queue cannot inherit an earlier eta.
    function test_RequeueResetsEta() public {
        vm.prank(alice);
        vault.createPlan(1, 10_000e6, 1_000e6, 30 days);
        MockStock t2 = new MockStock("T2", "T2");
        MockStock t3 = new MockStock("T3", "T3");
        vault.queueRoute(7, DcaVault.Route(address(t2), address(swapper), address(oracle), 0, true));
        vm.warp(block.timestamp + 47 hours);
        vault.queueRoute(7, DcaVault.Route(address(t3), address(swapper), address(oracle), 0, true));
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert();
        vault.activateRoute(7);
    }

    // =========================================================== slippage
    /// At every allowed slippage/deviation setting, and any push size, a
    /// sandwich either reverts or costs the victim <= maxSlippageBps vs feed.
    function testFuzz_SandwichBoundAtEverySetting(uint16 slip, uint16 dev, uint256 push, uint256 premBps, uint256 inst)
        public
    {
        slip = uint16(bound(slip, 0, 200));
        dev = uint16(bound(dev, 0, 2000));
        push = bound(push, 0, 2_000_000e6);
        premBps = bound(premBps, 0, 300);
        inst = bound(inst, 1e6, 200_000e6);
        CpammSwap pool = new CpammSwap(usdc, stock, 5_000_000e6, 5_000_000e6 * 1e10 / PX);
        uint256 ref = pool.poolPrice(address(0), address(0)) * 10_000 / (10_000 + premBps);
        oracle.setPrice(address(stock), ref);
        DcaVault v = new DcaVault(IERC20(address(usdc)), y, pool, oracle, type(uint256).max);
        y.bindVault(address(v));
        v.initRoute(1, DcaVault.Route(address(stock), address(pool), address(oracle), 0, true));
        v.setBounds(slip, dev);
        v.finishSetup();
        oracle.setFresh(false); // no first buy
        vm.prank(carol);
        usdc.approve(address(v), type(uint256).max);
        usdc.mint(carol, inst * 2);
        vm.prank(carol);
        uint256 id = v.createPlan(1, inst * 2, inst, 30 days);
        oracle.setFresh(true);
        vm.warp(block.timestamp + 12 hours);
        _sandwich(v, pool, id, push, inst, ref, slip);
    }

    function _sandwich(DcaVault v, CpammSwap pool, uint256 id, uint256 push, uint256 inst, uint256 ref, uint16 slip)
        internal
    {
        address atk = address(0xA77);
        usdc.mint(atk, push);
        vm.startPrank(atk);
        usdc.approve(address(pool), type(uint256).max);
        stock.approve(address(pool), type(uint256).max);
        uint256 bought = push > 0 ? pool.buy(push) : 0;
        uint256 before = stock.balanceOf(carol);
        try v.executeDCA(id) {
            uint256 got = stock.balanceOf(carol) - before;
            uint256 fair = inst * 1e10 / ref;
            if (got < fair) {
                assertLe((fair - got) * 10_000, uint256(slip) * fair + 10_000, "fill beyond bound");
            }
            fillsOk++;
        } catch {}
        if (bought > 0) pool.sell(bought);
        vm.stopPrank();
    }

    uint256 fillsOk;

    // =========================================================== loss/shortfall
    /// A loss hits every plan in proportion to its shares; nobody pays for
    /// someone else. Plans driven to completion in different orders.
    uint256 sA;
    uint256 sB;
    uint256 pa;
    uint256 pb;

    function testFuzz_LossIsProportional(uint256 lossWad, uint256 accWad, uint8 order, uint256 dA, uint256 dB)
        public
    {
        // From 5 and 4 USDC, not 4 and 3: split by rounding the installment
        // up, the last period is up to 3 wei short of the others, and it has
        // to be at least MIN_INSTALLMENT too.
        dA = bound(dA, 5e6, 300_000e6);
        dB = bound(dB, 4e6, 300_000e6);
        accWad = bound(accWad, 1e18, 1.2e18);
        lossWad = bound(lossWad, 0.01e18, 1e18);
        oracle.setFresh(false);
        vm.prank(alice);
        pa = vault.createPlan(1, dA, (dA + 3) / 4, 1 days);
        vm.prank(bob);
        pb = vault.createPlan(1, dB, (dB + 2) / 3, 1 days);
        oracle.setFresh(true);
        y.accrueTo(y.sharePriceWad() * accWad / 1e18);
        _loss(lossWad);
        (, uint256 sha,,,) = _p(vault, pa);
        (, uint256 shb,,,) = _p(vault, pb);
        uint256 va = y.assetsOf(sha);
        uint256 vb = y.assetsOf(shb);
        uint256 aUsd0 = usdc.balanceOf(alice);
        uint256 bUsd0 = usdc.balanceOf(bob);
        for (uint256 i; i < 12; ++i) {
            bool aFirst = (order >> (i % 8)) & 1 == 1;
            _step(aFirst ? pa : pb, i, order);
            _step(aFirst ? pb : pa, i, order);
            vm.warp(block.timestamp + 1 days);
        }
        uint256 outA = sA + usdc.balanceOf(alice) - aUsd0;
        uint256 outB = sB + usdc.balanceOf(bob) - bUsd0;
        console.log("A value/out", va, outA);
        console.log("B value/out", vb, outB);
        assertLe(outA, va, "A got more than its shares' value");
        assertLe(outB, vb, "B got more than its shares' value");
        assertGe(outA + 8, va, "A short beyond rounding");
        assertGe(outB + 8, vb, "B short beyond rounding");
        assertEq(vault.totalPrincipal(), 0);
        assertEq(vault.totalManagedShares(), 0);
        assertEq(y.totalShares(), 0);
    }

    function _step(uint256 id, uint256 i, uint8 order) internal {
        (,,,, bool act) = _p(vault, id);
        if (!act) return;
        address o = id == pa ? alice : bob;
        if (i == 5 && id == pb && (order & 1) == 1) {
            vm.prank(o);
            vault.exitPlan(id);
            return;
        }
        uint256 before = usdc.balanceOf(address(swapper));
        vm.prank(o);
        vault.executeDCA(id);
        uint256 s = usdc.balanceOf(address(swapper)) - before;
        if (id == pa) sA += s;
        else sB += s;
    }

    /// A heavy loss when rem is just above the value: can a plan owner choose
    /// when the "shortfall end" happens to dodge the fee? (fee is on accrued
    /// only, so there is nothing to dodge). Check fee is never charged on a
    /// shortfall slice and never on principal.
    function testFuzz_FeeNeverOnPrincipal(uint16 fee, uint256 accWad, uint256 lossWad, uint256 dep) public {
        fee = uint16(bound(fee, 0, 1000));
        accWad = bound(accWad, 1e18, 1.5e18);
        lossWad = bound(lossWad, 0.3e18, 1e18);
        // From 11 USDC, not 10: the last of the ten periods is up to 9 wei
        // short of the others, and it has to be at least MIN_INSTALLMENT too.
        dep = bound(dep, 11e6, 500_000e6);
        vault.setFee(fee);
        oracle.setFresh(false);
        vm.prank(alice);
        uint256 id = vault.createPlan(1, dep, (dep + 9) / 10, 1 days);
        oracle.setFresh(true);
        y.accrueTo(y.sharePriceWad() * accWad / 1e18);
        _loss(lossWad);
        (, uint256 sh,,,) = _p(vault, id);
        uint256 val = y.assetsOf(sh);
        uint256 expectedFeeMax = val > dep ? (val - dep) * fee / 10_000 + 1 : 0;
        uint256 f0 = vault.feesAccrued();
        for (uint256 i; i < 12; ++i) {
            (,,,, bool act) = _p(vault, id);
            if (!act) break;
            vm.prank(alice);
            vault.executeDCA(id);
            vm.warp(block.timestamp + 1 days);
        }
        assertLe(vault.feesAccrued() - f0, expectedFeeMax, "fee beyond yield");
        assertEq(usdc.balanceOf(address(vault)), vault.feesAccrued());
        vault.claimFees();
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // =========================================================== params
    /// The vault's whole admission rule for a plan, against a model of it:
    /// what the model accepts is created and runs to its end in at most 120
    /// buys, and what it does not is refused.
    ///
    /// Round 6b. This used to draw the deposit, the installment and the
    /// interval freely. A free uint64 interval is almost never one the vault
    /// accepts, so nearly every run was refused for its interval and the
    /// split never decided anything: the test passed with the last-period
    /// rule (round 6, R5-5) deleted, and with either of its off-by-ones. Now
    /// seven runs in eight take an interval the vault accepts, and seven in
    /// eight BUILD the deposit as k installments plus a tail, with the tail
    /// on each side of every edge the rule has.
    function testFuzz_CreateParamsEdges(uint256 dep, uint256 inst, uint64 iv, uint256 tail, uint8 mode)
        public
    {
        // One run in eight keeps the free interval: too short and too long
        // are still refused.
        if (mode % 8 != 0) iv = uint64(bound(iv, 1 days, 366 days));
        uint256 shape = (mode >> 3) % 8;
        if (shape == 0) {
            // Free: any deposit and any installment, as before.
            dep = bound(dep, 0, 1_000_000e6);
            inst = bound(inst, 0, 10_000_000e6);
        } else {
            inst = bound(inst, 1e6, 3_000e6);
            // Whole periods: a few, or right at the 120-period ceiling.
            uint256 k = dep % 8 < 5 ? 1 + (dep >> 8) % 6 : 118 + (dep >> 8) % 4;
            if (shape == 1) tail = 0; // the deposit divides
            else if (shape == 2) tail = 1; // the smallest dust there is
            else if (shape == 3) tail = 1e6 - 1; // one wei under the minimum
            else if (shape == 4) tail = 1e6; // exactly the minimum: the shortest tail admitted
            else if (shape == 5) tail = 1e6 + 1;
            else if (shape == 6) tail = bound(tail, 1, 1e6 - 1); // any dust
            else tail = bound(tail, 1e6, 3_000e6); // any real last period
            // A tail is a remainder, so it is under the installment.
            if (tail >= inst) tail = inst - 1;
            dep = k * inst + tail;
            assertEq(dep % inst, tail);
        }
        bool okExpected = inst >= 1e6 && inst <= dep && (dep + inst - 1) / inst <= 120 && iv >= 1 days
            && iv <= 366 days;
        // The last period is held to the minimum too (round 6, R5-5).
        if (okExpected && dep % inst != 0 && dep % inst < 1e6) okExpected = false;
        oracle.setFresh(false);
        vm.prank(alice);
        try vault.createPlan(1, dep, inst, iv) returns (uint256 id) {
            assertTrue(okExpected, "accepted bad params");
            oracle.setFresh(true);
            uint256 n;
            for (uint256 i; i < 125; ++i) {
                (,, uint64 ne,, bool act) = _p(vault, id);
                if (!act) break;
                vm.warp(ne);
                vm.prank(alice);
                vault.executeDCA(id);
                n++;
            }
            assertLe(n, 120);
            (,,,, bool act2) = _p(vault, id);
            assertFalse(act2);
        } catch {
            assertFalse(okExpected, "rejected good params");
        }
    }

    /// Stale-feed create -> no first buy -> stranger after grace once fresh.
    function test_StaleCreateThenExecutions() public {
        oracle.setFresh(false);
        vm.prank(alice);
        uint256 id = vault.createPlan(1, 3000e6, 1000e6, 7 days);
        (uint256 rem,, uint64 ne, uint32 done,) = _p(vault, id);
        assertEq(rem, 3000e6);
        assertEq(done, 0);
        assertEq(ne, block.timestamp);
        vm.prank(address(0xBAD));
        vm.expectRevert(DcaVault.TooEarlyForPublicCall.selector);
        vault.executeDCA(id);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(address(0xBAD));
        vm.expectRevert(DcaVault.StaleOracle.selector);
        vault.executeDCA(id);
        oracle.setFresh(true);
        vm.prank(address(0xBAD));
        vault.executeDCA(id);
        vm.prank(address(0xBAD));
        vm.expectRevert(DcaVault.NotYetDue.selector);
        vault.executeDCA(id);
        (rem,, ne, done,) = _p(vault, id);
        assertEq(done, 1);
        assertEq(ne, block.timestamp - 12 hours + 7 days);
    }

    // =========================================================== demo
    function _demo()
        internal
        returns (DemoUSDC du, DemoYieldAdapter ya, DcaVault v, DemoStock ds, DemoPriceOracle o)
    {
        address owner = address(0x0A);
        vm.startPrank(owner);
        du = new DemoUSDC(owner);
        o = new DemoPriceOracle(owner);
        ds = new DemoStock("D", "D", owner);
        o.setPrice(address(ds), PX);
        address predicted = vm.computeCreateAddress(owner, vm.getNonce(owner) + 2);
        ya = new DemoYieldAdapter(du, owner, predicted);
        DemoSwapAdapter sa = new DemoSwapAdapter(du, ds, o, owner);
        v = new DcaVault(IERC20(address(du)), ya, sa, o, 100_000_000e6);
        assertEq(address(v), predicted, "prediction");
        v.initRoute(1, DcaVault.Route(address(ds), address(sa), address(o), 0, true));
        v.finishSetup();
        du.setMinter(address(ya));
        du.mint(address(ya), 10_000e6);
        vm.stopPrank();
    }

    /// DemoUSDC minter permissions: only owner + minter; minter is replaceable
    /// only by owner; owner handoff is single-step.
    function test_DemoUsdcMinterPermissions() public {
        (DemoUSDC du, DemoYieldAdapter ya,,,) = _demo();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        du.mint(address(0xBAD), 1);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        du.setMinter(address(0xBAD));
        vm.prank(address(ya));
        du.mint(address(0xBEEF), 5); // the adapter can mint arbitrary amounts anywhere
        assertEq(du.balanceOf(address(0xBEEF)), 5);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        ya.accrueTo(2e18);
    }
}
