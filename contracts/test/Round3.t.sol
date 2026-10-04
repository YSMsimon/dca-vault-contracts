// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle} from "../src/adapters/ChainlinkOracle.sol";
import {AerodromeSwapAdapter} from "../src/adapters/AerodromeSwapAdapter.sol";
import {
    MockERC20,
    MockStock,
    MockYieldAdapter,
    MockPriceOracle,
    MockSwapAdapter
} from "../src/mocks/Mocks.sol";
import {
    DemoUSDC,
    DemoStock,
    DemoYieldAdapter,
    DemoPriceOracle,
    DemoSwapAdapter
} from "../src/mocks/DemoMocks.sol";
import {FakeFeed} from "./utils/HostileVenues.sol";
import {DripFactory} from "./Round2.t.sol";

/// A feed whose `latestRoundData` returns raw, attacker-chosen bytes.
///   mode 0: return `raw` verbatim        mode 1: revert with `raw`
///   mode 2: return-data bomb, sized to the feed's own gas, with a valid prefix
///   mode 3: revert-data bomb, sized the same way
///   mode 4: burn every unit of gas
/// From the round-3 re-test.
contract RawFeed {
    bytes public raw;
    uint8 public mode;

    function set(bytes calldata r, uint8 m) external {
        raw = r;
        mode = m;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    fallback() external {
        uint8 m = mode;
        if (m == 0 || m == 1) {
            bytes memory r = raw;
            if (m == 0) {
                assembly {
                    return(add(r, 32), mload(r))
                }
            }
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
        if (m == 4) {
            while (true) {}
        }
        // n words with 3n + n^2/512 ~ 0.95 * gasleft
        uint256 g = gasleft() * 95 / 100;
        uint256 n = _sqrt(512 * g + 589_824) - 768;
        uint256 size = n * 32;
        uint256 ts = block.timestamp;
        if (m == 2) {
            assembly {
                mstore(0, 1)
                mstore(32, 100000000)
                mstore(64, ts)
                mstore(96, ts)
                mstore(128, 1)
                return(0, size)
            }
        }
        assembly {
            revert(0, size)
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 yy = (x + 1) / 2;
        while (yy < z) {
            z = yy;
            yy = (x / yy + yy) / 2;
        }
    }
}

/// A token with code whose `decimals()` answers in whatever way `mode` says.
///   0: 8 (normal)   1: revert   2: 16 bytes   3: 8 with dirty high bits
///   4: 64 bytes, first word 8   5: 18   6: burn all gas (INVALID)
contract OddToken {
    uint8 public mode;

    function setMode(uint8 m) external {
        mode = m;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        uint8 m = mode;
        if (m == 1) revert();
        if (m == 2) {
            bytes memory r = abi.encode(uint256(8));
            assembly {
                return(add(r, 32), 16)
            }
        }
        if (m == 3) return abi.encode((uint256(1) << 200) | 8);
        if (m == 4) return abi.encode(uint256(8), uint256(18));
        if (m == 5) return abi.encode(uint256(18));
        if (m == 6) {
            assembly {
                invalid()
            }
        }
        return abi.encode(uint256(8));
    }
}

/// A Slipstream-shaped pool that only quotes: `slot0` at a settable price.
contract QuotePool {
    address public token0;
    address public token1;
    uint160 public sqrtP;

    constructor(address t0, address t1, uint160 p) {
        token0 = t0;
        token1 = t1;
        sqrtP = p;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (sqrtP, 0, 0, 0, 0, true);
    }
}

/// @notice The hardening plan, ROUND 3 (docs/hardening-plan.md, F1..F7).
/// @dev    Each finding was first shown on the unfixed code (an earlier
///         revision) by the re-test's own reproductions: they PASSED there by
///         demonstrating the finding. Each is rewritten here to assert the
///         SAFE behaviour, so it fails if the finding comes back. A
///         "Before (...)" note names the original reproduction (AuditPoC3.*,
///         R3New.*); those are not published.
///         F1's end-to-end proof, the real Deploy.s.sol on a Base mainnet
///         fork, is ForkDeploy.t.sol; F5's is DeployScripts.t.sol; F6 is the
///         invariant suites and R3Invariants.t.sol.
contract Round3Test is Test {
    MockERC20 usdc;
    MockStock stock;
    MockYieldAdapter y;
    MockPriceOracle oracle;
    MockSwapAdapter swapper;
    DcaVault vault;

    address alice = address(0xA11CE);
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
    }

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
        returns (uint256 rem, uint64 ne, uint32 done, bool active)
    {
        (,,, rem,, ne,, done, active) = v.plans(id);
    }

    /// A vault still in its setup window, on the mock oracle.
    function _openVault() internal returns (DcaVault v) {
        MockYieldAdapter y2 = new MockYieldAdapter(usdc);
        v = new DcaVault(IERC20(address(usdc)), y2, swapper, oracle, 10_000_000e6);
        y2.bindVault(address(v));
    }

    // ================================================================= F1
    /// Before (AuditPoC3.test_C9): the real
    /// B20 on a Base fork is a one-byte `0xef` stub the EVM cannot run, so
    /// `decimals()` read as 0, `initRoute` reverted BadTokenDecimals(0), and
    /// the mainnet deploy died in `forge script` before broadcasting. It
    /// also burned every unit of gas it was given (393M in the trace).
    function test_F1_AB20StubIsAdmittedAndCheaply() public {
        address b20 = address(0xb20000000000000000000078ee7ce2fE4908108C);
        vm.etch(b20, hex"ef");
        oracle.setPrice(b20, PX);
        DcaVault v = _openVault();
        uint256 g = gasleft();
        v.initRoute(1, _route(b20, address(swapper), address(oracle)));
        assertLt(g - gasleft(), 250_000, "the decimals probe is not bounded");
        (address t,,,, bool en) = v.routes(1);
        assertEq(t, b20);
        assertTrue(en);
    }

    /// A token that ANSWERS must answer 8; a token with no code is refused;
    /// a token whose `decimals()` cannot be read is refused too, unless it is
    /// the B20 stub (round-4 re-test: with a pushed pool, an unreadable
    /// wrong-decimals token filled at a wrong price inside the bound).
    function test_F1_TheDecimalsRuleByCase() public {
        DcaVault v = _openVault();
        OddToken t = new OddToken();
        // cannot be read: revert, short return data, out of gas -> refused
        uint8[3] memory unreadable = [uint8(1), 2, 6];
        for (uint32 i; i < 3; ++i) {
            OddToken ti = new OddToken();
            ti.setMode(unreadable[i]);
            vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 0));
            v.initRoute(10 + i, _route(address(ti), address(swapper), address(oracle)));
        }
        // ...except the one-byte B20 stub, which is what a real B20 looks
        // like to this EVM (see test_F1_AB20StubIsAdmittedAndCheaply)
        address notStub = address(new OddTokenStubLike());
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 0));
        v.initRoute(13, _route(notStub, address(swapper), address(oracle)));
        // answers 8: admitted, including with trailing words
        t.setMode(0);
        v.initRoute(20, _route(address(t), address(swapper), address(oracle)));
        OddToken t4 = new OddToken();
        t4.setMode(4);
        v.initRoute(21, _route(address(t4), address(swapper), address(oracle)));
        // answers anything else: refused by name, with the value it gave
        OddToken t5 = new OddToken();
        t5.setMode(5);
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 18));
        v.initRoute(30, _route(address(t5), address(swapper), address(oracle)));
        OddToken t3 = new OddToken();
        t3.setMode(3);
        vm.expectRevert(
            abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, (uint256(1) << 200) | 8)
        );
        v.initRoute(31, _route(address(t3), address(swapper), address(oracle)));
        MockERC20 narrow = new MockERC20("n", "n", 6);
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 6));
        v.initRoute(32, _route(address(narrow), address(swapper), address(oracle)));
        // no code at all: refused, as before
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 0));
        v.initRoute(33, _route(address(0xE0A), address(swapper), address(oracle)));
        // the same rule on the queued path
        v.finishSetup();
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 0));
        v.queueRoute(34, _route(address(0xE0A), address(swapper), address(oracle)));
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 18));
        v.queueRoute(34, _route(address(t5), address(swapper), address(oracle)));
        OddToken t6 = new OddToken();
        t6.setMode(6);
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 0));
        v.queueRoute(34, _route(address(t6), address(swapper), address(oracle)));
    }

    /// Round 4 (re-test N4-1 / static NEW-1): an 18-decimal stock whose
    /// `decimals()` cannot be read used to be admitted, and the pool-price
    /// backstop only held while the pool was honestly priced: pushed to
    /// 8dp parity, it filled 1e-10 of fair value. Now it is refused at every
    /// door, so no pool price can matter.
    function test_F1_AnUnreadableWrongDecimalsTokenIsRefused() public {
        OddToken wide = new OddToken();
        wide.setMode(1); // decimals() reverts
        FakeFeed f = new FakeFeed();
        f.set(100e8, block.timestamp, true);
        ChainlinkOracle cl = new ChainlinkOracle();
        cl.setFeed(address(wide), address(f));
        QuotePool pool = new QuotePool(address(usdc), address(wide), uint160(1 << 96));
        MockYieldAdapter y2 = new MockYieldAdapter(usdc);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        AerodromeSwapAdapter aero = new AerodromeSwapAdapter(IERC20(address(usdc)), predicted);
        DcaVault v = new DcaVault(IERC20(address(usdc)), y2, aero, cl, 10_000_000e6);
        y2.bindVault(address(v));
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 0));
        v.initRoute(1, _route(address(wide), address(pool), address(f)));
        v.finishSetup();
        vm.expectRevert(abi.encodeWithSelector(DcaVault.BadTokenDecimals.selector, 0));
        v.queueRoute(1, _route(address(wide), address(pool), address(f)));
    }

    // ================================================================= F2
    /// Before (R3New.test_N1, AuditPoC3.test_C2): an instant tightening left
    /// a queued loosening in place, and it applied at its eta, undoing the
    /// incident response with no fresh notice.
    function test_F2_ATighteningDropsAPendingLoosening() public {
        vm.prank(alice);
        vault.createPlan(1, 10_000e6, 1_000e6, 30 days);
        vault.setBounds(200, 2000); // loosening: queued
        (,, uint64 eta) = vault.pendingBounds();
        assertEq(eta, block.timestamp + 48 hours);

        vm.warp(block.timestamp + 47 hours);
        vm.expectEmit(false, false, false, true, address(vault));
        emit DcaVault.BoundsSet(10, 50);
        vm.expectEmit(false, false, false, true, address(vault));
        emit DcaVault.BoundsCancelled();
        vault.setBounds(10, 50); // incident: tighten
        (uint16 ps, uint16 pd, uint64 eta2) = vault.pendingBounds();
        assertEq(eta2, 0, "the loosening survived the tightening");
        assertEq(ps, 0);
        assertEq(pd, 0);

        vm.warp(eta);
        vm.expectRevert(DcaVault.NothingQueued.selector);
        vault.activateBounds();
        assertEq(vault.maxSlippageBps(), 10);
        assertEq(vault.maxDeviationBps(), 50);

        // AuditPoC3.test_C2's shape: a pair queued as a deviation-only
        // loosening no longer turns into a slippage loosening after a tighten.
        vault.setBounds(10, 800);
        vault.setBounds(5, 50);
        (,, eta2) = vault.pendingBounds();
        assertEq(eta2, 0);

        // Loosening again means fresh notice, from now.
        vault.setBounds(100, 500);
        (,, eta2) = vault.pendingBounds();
        assertEq(eta2, block.timestamp + 48 hours);
    }

    /// With nothing queued, an instant change emits no BoundsCancelled.
    function test_F2_NoCancelEventWhenNothingIsQueued() public {
        vm.recordLogs();
        vault.setBounds(50, 300);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != DcaVault.BoundsCancelled.selector);
        }
    }

    /// Any pair, any order: after an instant (non-loosening) change there is
    /// never a loosening pending.
    function testFuzz_F2_NoLooseningSurvivesAnInstantChange(
        uint16 s1,
        uint16 d1,
        uint16 s2,
        uint16 d2
    ) public {
        s1 = uint16(bound(s1, 0, 200));
        d1 = uint16(bound(d1, 0, 2000));
        s2 = uint16(bound(s2, 0, 200));
        d2 = uint16(bound(d2, 0, 2000));
        vault.setBounds(s1, d1);
        uint16 cs = vault.maxSlippageBps();
        uint16 cd = vault.maxDeviationBps();
        vault.setBounds(s2, d2);
        (,, uint64 eta) = vault.pendingBounds();
        if (s2 <= cs && d2 <= cd) {
            assertEq(eta, 0, "a pending loosening survived an instant change");
            assertEq(vault.maxSlippageBps(), s2);
            assertEq(vault.maxDeviationBps(), d2);
        } else {
            assertEq(eta, block.timestamp + 48 hours);
        }
    }

    // ================================================================= F3
    function _clWith(RawFeed rf) internal returns (ChainlinkOracle cl, DcaVault v, MockStock s) {
        s = new MockStock("S", "S");
        MockPriceOracle po = new MockPriceOracle();
        po.setPrice(address(s), 1e8);
        MockSwapAdapter sw = new MockSwapAdapter(usdc, s, po);
        cl = new ChainlinkOracle();
        cl.setFeed(address(s), address(rf));
        MockYieldAdapter y2 = new MockYieldAdapter(usdc);
        v = new DcaVault(IERC20(address(usdc)), y2, sw, cl, 1e15);
        y2.bindVault(address(v));
        v.initRoute(1, _route(address(s), address(sw), address(rf)));
        v.finishSetup();
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
    }

    /// The deposit goes in with no first buy, and the plan opens due.
    function _depositWaits(DcaVault v) internal {
        vm.prank(alice);
        uint256 id = v.createPlan(1, 100e6, 10e6, 1 days);
        (uint256 rem, uint64 ne, uint32 done, bool act) = _p(v, id);
        assertEq(rem, 100e6, "a first buy ran against a garbage feed");
        assertEq(done, 0);
        assertEq(ne, block.timestamp);
        assertTrue(act);
    }

    /// Before (R3New.test_N2, AuditPoC3.test_C6): a round id outside uint80
    /// read FRESH in isFresh, then latestPrice's typed decode reverted inside
    /// createPlan's first buy, so the garbage feed blocked deposits.
    function test_F3_AnOutOfRangeRoundIdIsNotFreshAndDepositsGoThrough() public {
        RawFeed rf = new RawFeed();
        (ChainlinkOracle cl, DcaVault v, MockStock s) = _clWith(rf);
        uint256 t = block.timestamp;
        rf.set(abi.encode(uint256(1) << 80, int256(1e8), t, t, uint256(1)), 0);
        assertFalse(cl.isFresh(address(s)));
        vm.expectRevert(ChainlinkOracle.BadPrice.selector);
        cl.latestPrice(address(s));
        _depositWaits(v);

        rf.set(abi.encode(uint256(1), int256(1e8), t, t, type(uint256).max), 0);
        assertFalse(cl.isFresh(address(s)));
        vm.expectRevert(ChainlinkOracle.BadPrice.selector);
        cl.latestPrice(address(s));
        _depositWaits(v);

        // The edge: uint80.max itself is a valid round id.
        rf.set(
            abi.encode(uint256(type(uint80).max), int256(1e8), t, t, uint256(type(uint80).max)), 0
        );
        assertTrue(cl.isFresh(address(s)));
        (uint256 px,) = cl.latestPrice(address(s));
        assertEq(px, 1e8);
    }

    /// Before (R3New.test_N2b): an `int256.max` answer passed both reads,
    /// then `diff * 10_000` overflowed in _minOut: Panic 0x11 out of
    /// createPlan. Now anything above MAX_PRICE is garbage.
    function test_F3_AHugeAnswerIsRejectedAndCannotPanic() public {
        RawFeed rf = new RawFeed();
        (ChainlinkOracle cl, DcaVault v, MockStock s) = _clWith(rf);
        uint256 t = block.timestamp;
        rf.set(abi.encode(uint256(1), type(int256).max, t, t, uint256(1)), 0);
        assertFalse(cl.isFresh(address(s)));
        vm.expectRevert(ChainlinkOracle.BadPrice.selector);
        cl.latestPrice(address(s));
        _depositWaits(v);

        uint256 max = cl.MAX_PRICE();
        rf.set(abi.encode(uint256(1), int256(max + 1), t, t, uint256(1)), 0);
        assertFalse(cl.isFresh(address(s)));
        rf.set(abi.encode(uint256(1), int256(max), t, t, uint256(1)), 0);
        assertTrue(cl.isFresh(address(s)));
        (uint256 px,) = cl.latestPrice(address(s));
        assertEq(px, max);
    }

    /// Before (R3New.test_N3, AuditPoC3.test_C7): isFresh copied ALL return
    /// or revert data, so a feed returning as much as its gas allowed ran
    /// isFresh out of gas in the copy, whatever the caller supplied, and
    /// createPlan reverted with it. Now at most 160 bytes are ever copied.
    function test_F3_AReturnDataBombCannotRevertIsFresh() public {
        RawFeed rf = new RawFeed();
        (ChainlinkOracle cl, DcaVault v, MockStock s) = _clWith(rf);
        for (uint8 m = 2; m <= 4; ++m) {
            rf.set("", m);
            (bool ok, bytes memory ret) = address(cl).call{gas: 10_000_000}(
                abi.encodeCall(ChainlinkOracle.isFresh, (address(s)))
            );
            assertTrue(ok, "isFresh reverted");
            // A revert bomb and a gas burner read as not fresh.
            if (m != 2) assertFalse(abi.decode(ret, (bool)));
        }
        // A revert bomb no longer blocks deposits.
        rf.set("", 3);
        vm.prank(alice);
        (bool ok2,) = address(v).call{gas: 10_000_000}(
            abi.encodeCall(DcaVault.createPlan, (1, 100e6, 10e6, 1 days))
        );
        assertTrue(ok2, "createPlan reverted on a revert-data bomb");
    }

    /// The two reads cannot disagree: whatever the feed returns, isFresh
    /// never reverts, and isFresh true means latestPrice answers.
    function testFuzz_F3_IsFreshImpliesLatestPrice(
        uint256 rid,
        int256 answer,
        uint256 started,
        uint256 ts,
        uint256 air,
        uint8 shape
    ) public {
        RawFeed rf = new RawFeed();
        (ChainlinkOracle cl,, MockStock s) = _clWith(rf);
        // Bias toward the interesting region so the fresh branch is reached.
        if (shape % 2 == 0) {
            rid = bound(rid, 0, uint256(type(uint80).max) + 2);
            air = bound(air, 0, uint256(type(uint80).max) + 2);
            answer = int256(bound(uint256(answer), 0, 2e16));
            ts = bound(ts, block.timestamp - 2 days, block.timestamp + 1);
        }
        bytes memory r = abi.encode(rid, answer, started, ts, air);
        if (shape % 5 == 1) r = abi.encodePacked(r, uint256(7), uint256(9)); // trailing words
        if (shape % 7 == 3) {
            assembly {
                mstore(r, 159)
            }
        }
        rf.set(r, shape % 11 == 5 ? 1 : 0);
        bool fresh = cl.isFresh(address(s));
        if (fresh) {
            (uint256 px, uint256 at) = cl.latestPrice(address(s));
            assertEq(px, uint256(answer));
            assertEq(at, ts);
            assertLe(px, cl.MAX_PRICE());
            assertLe(rid, type(uint80).max);
            assertLe(air, type(uint80).max);
        }
    }

    // ================================================================= F4
    /// Before (R3New.test_N4): deposits were open from construction, so a
    /// stranger's createPlan could land between two initRoute transactions
    /// of a deploy and close the setup window on the rest.
    function test_F4_NobodyCanCloseTheSetupWindowMidDeploy() public {
        DemoUSDC du = new DemoUSDC(address(this));
        DemoPriceOracle o = new DemoPriceOracle(address(this));
        DemoStock s1 = new DemoStock("A", "A", address(this));
        DemoStock s2 = new DemoStock("B", "B", address(this));
        o.setPrice(address(s1), PX);
        o.setPrice(address(s2), PX);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        DemoYieldAdapter ya = new DemoYieldAdapter(du, address(this), predicted);
        DemoSwapAdapter sa = new DemoSwapAdapter(du, s1, o, address(this));
        DcaVault v = new DcaVault(IERC20(address(du)), ya, sa, o, 100_000_000e6);
        assertTrue(v.depositsPaused(), "deposits open at construction");
        assertFalse(v.setupFinished());
        v.initRoute(1, _route(address(s1), address(sa), address(o)));

        // the attacker's transaction lands here
        address atk = address(0xA7C);
        vm.startPrank(atk);
        du.drip();
        du.approve(address(v), type(uint256).max);
        vm.expectRevert(DcaVault.Paused.selector);
        v.createPlan(1, 1e6, 1e6, 1 days);
        vm.stopPrank();

        v.initRoute(2, _route(address(s2), address(sa), address(o)));
        v.finishSetup();
        vm.prank(atk);
        v.createPlan(1, 1e6, 1e6, 1 days);
    }

    function test_F4_FinishSetupClosesTheWindowOnceAndOpensDeposits() public {
        DcaVault v = _openVault();
        // Paused from the constructor, and it cannot be opened any other way.
        vm.expectRevert(DcaVault.SetupOpen.selector);
        v.setDepositsPaused(false);
        v.setDepositsPaused(true); // pausing is always allowed
        v.initRoute(1, _route(address(stock), address(swapper), address(oracle)));
        v.setBounds(200, 2000); // setup: instant
        assertEq(v.maxSlippageBps(), 200);
        v.setBounds(100, 500);

        vm.prank(thief);
        vm.expectRevert(DcaVault.NotOwner.selector);
        v.finishSetup();

        // The admin paused on purpose during setup (above), so finishing
        // setup keeps deposits paused (round 4: it used to open them).
        vm.expectEmit(false, false, false, true, address(v));
        emit DcaVault.SetupFinished();
        vm.expectEmit(false, false, false, true, address(v));
        emit DcaVault.DepositsPausedSet(true);
        v.finishSetup();
        assertTrue(v.setupFinished());
        assertTrue(v.depositsPaused(), "a pause set during setup was lifted");
        v.setDepositsPaused(false);
        assertFalse(v.depositsPaused());

        vm.expectRevert(DcaVault.SetupClosed.selector);
        v.finishSetup();
        vm.expectRevert(DcaVault.SetupClosed.selector);
        v.initRoute(2, _route(address(stock), address(swapper), address(oracle)));
        v.setBounds(200, 2000); // no plan yet, but setup is over: queued
        assertEq(v.maxSlippageBps(), 100, "a loosening after finishSetup was instant");

        // Pausing and unpausing later does not reopen anything.
        v.setDepositsPaused(true);
        v.setDepositsPaused(false);
        vm.expectRevert(DcaVault.SetupClosed.selector);
        v.initRoute(2, _route(address(stock), address(swapper), address(oracle)));
    }

    /// No plan can exist while the setup window is open.
    function testFuzz_F4_NoPlanBeforeFinishSetup(bool pauseFirst, uint256 dep) public {
        DcaVault v = _openVault();
        v.initRoute(1, _route(address(stock), address(swapper), address(oracle)));
        if (pauseFirst) v.setDepositsPaused(true);
        dep = bound(dep, 1e6, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(DcaVault.Paused.selector);
        v.createPlan(1, dep, dep, 1 days);
        assertEq(v.nextPlanId(), 1);
    }

    /// Round 4: with no pause during setup, finishSetup opens deposits.
    function test_R4_FinishSetupOpensDepositsWhenNotPausedInSetup() public {
        DcaVault v = _openVault();
        v.initRoute(1, _route(address(stock), address(swapper), address(oracle)));
        vm.expectEmit(false, false, false, true, address(v));
        emit DcaVault.DepositsPausedSet(false);
        v.finishSetup();
        assertFalse(v.depositsPaused());
    }

    /// Round 4 (re-test N4-2 / static NEW-3): the feed read forwarded all gas,
    /// so a fresh-but-gas-hungry feed made every deposit run out of gas. The
    /// read is capped: such a feed reads as not fresh, cheaply.
    function test_R4_AGasHungryFeedReadsNotFreshAndCheaply() public {
        ChainlinkOracle cl = new ChainlinkOracle();
        GasHungryFeed hungry = new GasHungryFeed();
        address tok = address(new MockERC20("h", "h", 8));
        cl.setFeed(tok, address(hungry));
        uint256 g = gasleft();
        bool fresh = cl.isFresh(tok);
        uint256 used = g - gasleft();
        assertFalse(fresh, "a feed that needs more than the cap read as fresh");
        assertLt(used, 200_000, "the feed read was not capped");
        // a real-sized feed is unaffected
        FakeFeed ok = new FakeFeed();
        ok.set(100e8, block.timestamp, true);
        address tok2 = address(new MockERC20("o", "o", 8));
        cl.setFeed(tok2, address(ok));
        assertTrue(cl.isFresh(tok2));
    }

    // ================================================================= F7
    /// Documented, not fixed (docs/threat-model.md, *The Base Sepolia demo*):
    /// the budget is per fixed UTC day, so twice the daily budget can pour
    /// out inside two seconds around midnight; no single UTC day ever
    /// exceeds it.
    function test_F7_TheFaucetBurstsAtMidnight() public {
        DemoUSDC du = new DemoUSDC(address(this));
        uint256 n = du.DAILY_BUDGET() / du.DRIP();
        uint256 mid = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(mid - 1);
        for (uint160 i; i < n; ++i) {
            vm.prank(address(0x5000 + i));
            du.drip();
        }
        vm.prank(address(0x4FFF));
        vm.expectRevert(abi.encodeWithSelector(DemoUSDC.FaucetDry.selector, mid));
        du.drip();
        vm.warp(mid);
        for (uint160 i; i < n; ++i) {
            vm.prank(address(0x6000 + i));
            du.drip();
        }
        assertEq(du.totalSupply(), 2 * du.DAILY_BUDGET(), "two days' budget in two seconds");
        vm.prank(address(0x4FFF));
        vm.expectRevert(abi.encodeWithSelector(DemoUSDC.FaucetDry.selector, mid + 1 days));
        du.drip();
    }

    /// Documented, not fixed: one transaction of one-drip children takes a
    /// whole day's budget, and everyone else waits for the next UTC day.
    function test_F7_OneTransactionCanTakeADaysBudget() public {
        DemoUSDC du = new DemoUSDC(address(this));
        vm.warp((block.timestamp / 1 days + 1) * 1 days); // just after midnight
        DripFactory f = new DripFactory();
        uint256 n = du.DAILY_BUDGET() / du.DRIP();
        vm.prank(thief);
        f.run(du, n);
        assertEq(du.balanceOf(thief), du.DAILY_BUDGET());
        assertEq(du.faucetRemainingToday(), 0);
        assertEq(du.dripReadyAt(alice), (block.timestamp / 1 days + 1) * 1 days);
        vm.prank(alice);
        vm.expectRevert();
        du.drip();
    }
}

/// Burns gas, then answers a valid, fresh round: fine to a caller that
/// forwards everything, fatal to its transaction.
contract GasHungryFeed {
    uint8 public constant decimals = 8;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        // Needs about 300k gas before it answers; a real proxy needs < 20k.
        uint256 x;
        for (uint256 i; i < 1_000; ++i) x = uint256(keccak256(abi.encode(x)));
        return (1, 100e8, block.timestamp, block.timestamp, 1);
    }
}

/// Has code that is not the B20 stub and whose decimals() reverts.
contract OddTokenStubLike {
    function decimals() external pure returns (uint8) {
        revert();
    }
}
