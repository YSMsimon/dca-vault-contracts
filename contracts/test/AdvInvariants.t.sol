// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle} from "../src/adapters/ChainlinkOracle.sol";
import {MockERC20, MockStock, MockYieldAdapter} from "../src/mocks/Mocks.sol";
import {CpammSwap, FakeFeed} from "./utils/HostileVenues.sol";
import {InvStats} from "./utils/InvStats.sol";

/// Adversarial stateful handler from the round-2 re-test,
/// kept: admin queue/activate/cancel/transfer/accept sequences
/// (vault AND oracle), from random callers, interleaved with user
/// create/execute/exit, sandwiches on a constant-product pool, lending
/// gains/losses, fee changes and claims. Every check is a ghost counter.
///
/// Round 2 (D2) adds: every activation must land inside [eta, eta + 7 days];
/// `disableRoute` must drop a pending entry; the fill bounds may only LOOSEN
/// through a queued `activateBounds` inside its window (or before the first
/// plan). Heavier runs: FOUNDRY_INVARIANT_RUNS / FOUNDRY_INVARIANT_DEPTH.
contract AdvHandler is Test {
    DcaVault public v;
    ChainlinkOracle public cl;
    MockERC20 public usdc;
    MockStock public stock;
    MockStock public t2;
    MockYieldAdapter public y;
    CpammSwap public pool;
    FakeFeed[3] public feeds;

    address[3] public admins = [address(this), address(0xAD1), address(0xAD2)];
    address[4] public users = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    address public keeper = address(0xC0FFEE);
    address public stranger = address(0xBAD);
    address[2] public feeRecips = [address(0xFEE1), address(0xFEE2)];

    // ghost admin model
    address public gVaultAdmin;
    address public gVaultPending;
    address public gOracleAdmin;
    address public gOraclePending;

    // ghost queues
    struct Q {
        address token;
        address pool;
        address feed;
        bool enabled;
        uint256 at;
        bool live;
    }

    mapping(uint32 => Q) public gRouteQ;
    mapping(address => Q) public gFeedQ;

    struct BQ {
        uint16 slip;
        uint16 dev;
        uint256 at;
        bool live;
    }

    BQ public gBoundsQ;

    // plan ghosts
    uint256[] public ids;
    mapping(uint256 => address) public gToken;
    mapping(uint256 => address) public gPool;
    mapping(uint256 => uint256) public gLossEpochAtCreate;
    uint256 public lossEpoch;

    // counters (every one must stay 0)
    uint256 public vRouteEarly;
    uint256 public vRouteImmutable;
    uint256 public vFeedEarly;
    uint256 public vNonAdmin;
    uint256 public vPlanRouteMoved;
    uint256 public vOverdraw; // a plan got more than its burned shares' value
    uint256 public vIsolation; // another plan's shares/rem changed
    uint256 public vFill; // fill worse than bound
    uint256 public vEarly; // executed before due / public before grace
    uint256 public vPanic;
    uint256 public vUnexpected;
    uint256 public vShortfallNoLoss; // shortfall > 2 wei with no loss since create
    uint256 public vFeeOnPrincipal;
    uint256 public vExitLiquidRevert;
    uint256 public vShortfallState;
    uint256 public vExpiredActivation; // an activation after eta + 7 days
    uint256 public vPendingSurvivedDisable;
    uint256 public vBoundsLoosenedEarly;
    bytes public lastBad;
    string public lastBadWhere;

    // stats
    uint256 public nCreate;
    uint256 public nExec;
    uint256 public nExecTries; // F6: _prep found a plan (execute, sandwich, exit)
    uint256 public nCalm; // F6: executeCalm calls that reached a plan
    uint256 public nCalmSmall; // ...on a slice <= 50k USDC
    uint256 public nCalmSmallOk;
    bytes public lastCalmErr;
    uint256 public nExit;
    uint256 public nSandwich;
    uint256 public nShortfall;
    uint256 public nActivateRoute;
    uint256 public nActivateFeed;
    uint256 public nAccept;
    uint256 public nActivateBounds;
    uint256 public nExpiredRefusals;
    uint256 public feesClaimedTotal;
    uint256 public feesChargedTotal;
    uint256 public maxFillLossBps;
    uint256 public maxNoLossShortfall;

    uint256 constant PX = 227_56000000;

    constructor() {
        vm.warp(1_780_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("S", "S");
        t2 = new MockStock("T2", "T2");
        y = new MockYieldAdapter(usdc);
        pool = new CpammSwap(usdc, stock, 20_000_000e6, 20_000_000e6 * 1e10 / PX);
        cl = new ChainlinkOracle();
        for (uint256 i; i < 3; ++i) {
            feeds[i] = new FakeFeed();
            feeds[i].set(int256(pool.poolPrice(address(0), address(0))), block.timestamp, true);
        }
        cl.setFeed(address(stock), address(feeds[0]));
        v = new DcaVault(IERC20(address(usdc)), y, pool, cl, 3_000_000e6);
        y.bindVault(address(v));
        v.initRoute(1, DcaVault.Route(address(stock), address(pool), address(feeds[0]), 0, true));
        v.finishSetup();
        v.setKeeper(keeper, true);
        gVaultAdmin = address(this);
        gOracleAdmin = address(this);
        for (uint256 i; i < 4; ++i) {
            usdc.mint(users[i], 100_000_000e6);
            vm.prank(users[i]);
            usdc.approve(address(v), type(uint256).max);
        }
    }

    // ------------------------------------------------------------ helpers
    function _plan(uint256 id)
        internal
        view
        returns (address o, uint32 rid, uint256 inst, uint256 rem, uint256 sh, uint64 ne, bool act)
    {
        (o, rid, inst, rem, sh, ne,,, act) = v.plans(id);
    }

    function _isPanic(bytes memory e) internal pure returns (bool) {
        return e.length >= 4 && bytes4(e) == bytes4(keccak256("Panic(uint256)"));
    }

    function _ok(bytes memory e) internal pure returns (bool) {
        if (e.length < 4) return false;
        bytes4 s = bytes4(e);
        return s == DcaVault.NotYetDue.selector || s == DcaVault.PlanInactive.selector
            || s == DcaVault.TooEarlyForPublicCall.selector || s == DcaVault.StaleOracle.selector
            || s == DcaVault.PoolDiverged.selector || s == DcaVault.InsufficientAdapterLiquidity.selector
            || s == DcaVault.RouteDisabled.selector || s == DcaVault.CapExceeded.selector
            || s == DcaVault.BadParams.selector || s == DcaVault.Paused.selector
            || s == DcaVault.NotOwner.selector || s == DcaVault.TimelockActive.selector
            || s == DcaVault.NothingQueued.selector || s == DcaVault.RouteImmutable.selector
            || s == DcaVault.FeedMismatch.selector || s == DcaVault.SetupClosed.selector
            || s == DcaVault.NotPendingAdmin.selector || s == DcaVault.SlippageExceeded.selector
            || s == ChainlinkOracle.NotAdmin.selector || s == ChainlinkOracle.NotPendingAdmin.selector
            || s == ChainlinkOracle.TimelockActive.selector || s == ChainlinkOracle.NothingQueued.selector
            || s == ChainlinkOracle.FeedAlreadySet.selector || s == ChainlinkOracle.BadPrice.selector
            || s == DcaVault.QueueExpired.selector || s == ChainlinkOracle.QueueExpired.selector
            || s == ChainlinkOracle.NoFeed.selector
            || keccak256(e) == keccak256(abi.encodeWithSignature("Error(string)", "SLIPPAGE"));
    }

    mapping(bytes4 => uint256) public why;

    function _bad(bytes memory e, string memory where) internal {
        if (
            e.length >= 4
                && (bytes4(e) == DcaVault.QueueExpired.selector || bytes4(e) == ChainlinkOracle.QueueExpired.selector)
        ) nExpiredRefusals++;
        if (keccak256(bytes(where)) == keccak256("execute") || keccak256(bytes(where)) == keccak256("create")) {
            why[e.length >= 4 ? bytes4(e) : bytes4(0)]++;
        }
        if (_isPanic(e)) vPanic++;
        if (!_ok(e)) {
            vUnexpected++;
            lastBad = e;
            lastBadWhere = where;
        }
    }

    function _pick(uint256 s) internal view returns (address) {
        uint256 k = s % 4;
        return k < 3 ? admins[k] : stranger;
    }

    function _ref() internal view returns (uint256 p) {
        (, int256 a,,,) = feeds[0].latestRoundData();
        p = uint256(a);
    }

    struct RouteSnap {
        address token;
        address pool;
        address feed;
        bool en;
    }

    function _rs(uint32 id) internal view returns (RouteSnap memory r) {
        (r.token, r.pool, r.feed,, r.en) = v.routes(id);
    }

    /// Compare route state before/after an action. Only three transitions are
    /// legal: nothing; disable (en true->false, all else same); activation of
    /// the ghost-queued entry at/after +48h.
    function _checkRoute(uint32 id, RouteSnap memory b, bool activated, uint256 queuedAt, Q memory q)
        internal
    {
        RouteSnap memory a = _rs(id);
        if (b.token != address(0) && (a.token != b.token || a.pool != b.pool)) vRouteImmutable++;
        bool changed = a.token != b.token || a.pool != b.pool || a.feed != b.feed || a.en != b.en;
        if (!changed) return;
        bool isDisable = !a.en && b.en && a.token == b.token && a.pool == b.pool && a.feed == b.feed;
        if (isDisable) return;
        if (!activated || block.timestamp < queuedAt + 48 hours) {
            vRouteEarly++;
            return;
        }
        if (block.timestamp > queuedAt + 48 hours + 7 days) vExpiredActivation++;
        if (a.token != q.token || a.pool != q.pool || a.feed != q.feed || a.en != q.enabled) vRouteEarly++;
    }

    // =========================================================== admin: vault
    function transferVaultAdmin(uint256 who, uint256 to) public {
        address c = _pick(who);
        address n = to % 5 == 4 ? address(0) : admins[to % 3];
        vm.prank(c);
        try v.transferAdmin(n) {
            if (c != gVaultAdmin) vNonAdmin++;
            gVaultPending = n;
        } catch (bytes memory e) {
            _bad(e, "transferAdmin");
        }
    }

    function acceptVaultAdmin(uint256 who) public {
        address c = _pick(who);
        vm.prank(c);
        try v.acceptAdmin() {
            if (c != gVaultPending || c == address(0)) vNonAdmin++;
            gVaultAdmin = c;
            gVaultPending = address(0);
            nAccept++;
        } catch (bytes memory e) {
            _bad(e, "acceptAdmin");
        }
    }

    function queueRoute(uint256 who, uint8 idSeed, uint8 variant) public {
        uint32 id = uint32(idSeed % 2) + 1;
        address c = _pick(who);
        address tok = id == 1 ? address(stock) : address(t2);
        if (variant % 5 == 0) tok = id == 1 ? address(t2) : address(stock); // try to re-point
        address pl = variant % 7 == 0 ? address(0xdead) : address(pool);
        address fd = address(feeds[variant % 3]);
        if (variant % 11 == 0) fd = cl.feedOf(tok);
        bool en = variant % 9 != 1;
        RouteSnap memory b1 = _rs(1);
        RouteSnap memory b2 = _rs(2);
        vm.prank(c);
        try v.queueRoute(id, DcaVault.Route(tok, pl, fd, 0, en)) {
            if (c != gVaultAdmin) vNonAdmin++;
            gRouteQ[id] = Q(tok, pl, fd, en, block.timestamp, true);
        } catch (bytes memory e) {
            _bad(e, "queueRoute");
        }
        Q memory q;
        _checkRoute(1, b1, false, 0, q);
        _checkRoute(2, b2, false, 0, q);
    }

    function activateRoute(uint256 who, uint8 idSeed) public {
        uint32 id = uint32(idSeed % 2) + 1;
        address c = _pick(who);
        RouteSnap memory b = _rs(id);
        Q memory q = gRouteQ[id];
        vm.prank(c);
        try v.activateRoute(id) {
            if (c != gVaultAdmin) vNonAdmin++;
            if (!q.live) vRouteEarly++;
            nActivateRoute++;
            _checkRoute(id, b, true, q.at, q);
            delete gRouteQ[id];
        } catch (bytes memory e) {
            _bad(e, "activateRoute");
            _checkRoute(id, b, false, 0, q);
        }
    }

    function cancelRoute(uint256 who, uint8 idSeed) public {
        uint32 id = uint32(idSeed % 2) + 1;
        address c = _pick(who);
        vm.prank(c);
        try v.cancelRoute(id) {
            if (c != gVaultAdmin) vNonAdmin++;
            delete gRouteQ[id];
        } catch (bytes memory e) {
            _bad(e, "cancelRoute");
        }
    }

    function disableRoute(uint256 who, uint8 idSeed) public {
        if (idSeed % 5 != 0) return;
        uint32 id = uint32(idSeed % 2) + 1;
        address c = _pick(who);
        RouteSnap memory b = _rs(id);
        vm.prank(c);
        try v.disableRoute(id) {
            if (c != gVaultAdmin) vNonAdmin++;
            (,,,,, uint64 eta) = v.pendingRoutes(id);
            if (eta != 0) vPendingSurvivedDisable++;
            delete gRouteQ[id];
        } catch (bytes memory e) {
            _bad(e, "disableRoute");
        }
        Q memory q;
        _checkRoute(id, b, false, 0, q);
    }

    function initRoute(uint256 who, uint8 variant) public {
        address c = _pick(who);
        RouteSnap memory b = _rs(2);
        address fd = cl.feedOf(address(t2));
        vm.prank(c);
        try v.initRoute(2, DcaVault.Route(address(t2), address(pool), fd, 0, variant % 2 == 0)) {
            if (c != gVaultAdmin) vNonAdmin++;
            if (v.setupFinished()) vRouteEarly++;
        } catch (bytes memory e) {
            _bad(e, "initRoute");
            Q memory q;
            _checkRoute(2, b, false, 0, q);
        }
    }

    /// Bounds only move up through a queued activation inside its window,
    /// or before finishSetup.
    function _checkBounds(uint16 s0, uint16 d0, bool activated) internal {
        uint16 s1 = v.maxSlippageBps();
        uint16 d1 = v.maxDeviationBps();
        if (s1 <= s0 && d1 <= d0) return;
        if (!v.setupFinished()) return;
        BQ memory q = gBoundsQ;
        if (
            !activated || !q.live || block.timestamp < q.at + 48 hours
                || block.timestamp > q.at + 48 hours + 7 days || s1 != q.slip || d1 != q.dev
        ) vBoundsLoosenedEarly++;
    }

    function setParams(uint256 who, uint16 slip, uint16 dev, uint16 fee, uint8 rec) public {
        address c = _pick(who);
        uint16 s0 = v.maxSlippageBps();
        uint16 d0 = v.maxDeviationBps();
        vm.startPrank(c);
        try v.setBounds(slip % 260, dev % 2200) {
            if (c != gVaultAdmin) vNonAdmin++;
            if (v.setupFinished() && (slip % 260 > s0 || dev % 2200 > d0)) {
                gBoundsQ = BQ(slip % 260, dev % 2200, block.timestamp, true);
            } else {
                // Round 3 (F2): an instant change drops any queued loosening.
                (,, uint64 eta) = v.pendingBounds();
                if (eta != 0) vBoundsLoosenedEarly++;
                delete gBoundsQ;
            }
        } catch (bytes memory e) {
            _bad(e, "setBounds");
        }
        _checkBounds(s0, d0, false);
        try v.setFee(fee % 1100) {
            if (c != gVaultAdmin) vNonAdmin++;
        } catch (bytes memory e) {
            _bad(e, "setFee");
        }
        try v.setFeeRecipient(feeRecips[rec % 2]) {
            if (c != gVaultAdmin) vNonAdmin++;
        } catch (bytes memory e) {
            _bad(e, "setFeeRecipient");
        }
        vm.stopPrank();
    }

    function setCapPauseKeeper(uint256 who, uint256 cap, bool paused, bool k) public {
        address c = _pick(who);
        vm.startPrank(c);
        try v.setTvlCap(bound(cap, 500_000e6, 10_000_000e6)) {
            if (c != gVaultAdmin) vNonAdmin++;
        } catch (bytes memory e) {
            _bad(e, "setTvlCap");
        }
        try v.setDepositsPaused(paused && cap % 10 == 0) {
            if (c != gVaultAdmin) vNonAdmin++;
        } catch (bytes memory e) {
            _bad(e, "setDepositsPaused");
        }
        try v.setKeeper(keeper, k || cap % 2 == 0) {
            if (c != gVaultAdmin) vNonAdmin++;
        } catch (bytes memory e) {
            _bad(e, "setKeeper");
        }
        vm.stopPrank();
    }

    /// The legitimate way back after a disable: current admin queues a
    /// re-enable following the oracle's current feed, waits 48h, activates.
    function adminRestore(uint8 idSeed) public {
        uint32 id = uint32(idSeed % 2) + 1;
        (address tk, address pl,,,) = v.routes(id);
        if (tk == address(0)) return;
        address fd = cl.feedOf(tk);
        if (fd == address(0)) return;
        RouteSnap memory b = _rs(id);
        vm.prank(gVaultAdmin);
        v.queueRoute(id, DcaVault.Route(tk, pl, fd, 0, true));
        gRouteQ[id] = Q(tk, pl, fd, true, block.timestamp, true);
        Q memory none;
        _checkRoute(id, b, false, 0, none);
        vm.warp(block.timestamp + 48 hours);
        b = _rs(id);
        Q memory q = gRouteQ[id];
        vm.prank(gVaultAdmin);
        v.activateRoute(id);
        nActivateRoute++;
        _checkRoute(id, b, true, q.at, q);
        delete gRouteQ[id];
    }

    function boundsOp(uint256 who, bool activate, uint256 dt) public {
        address c = _pick(who);
        if (dt % 3 == 0) vm.warp(block.timestamp + bound(dt, 1 hours, 10 days));
        uint16 s0 = v.maxSlippageBps();
        uint16 d0 = v.maxDeviationBps();
        bool act;
        vm.prank(c);
        if (activate) {
            try v.activateBounds() {
                if (c != gVaultAdmin) vNonAdmin++;
                act = true;
                nActivateBounds++;
            } catch (bytes memory e) {
                _bad(e, "activateBounds");
            }
        } else {
            try v.cancelBounds() {
                if (c != gVaultAdmin) vNonAdmin++;
                delete gBoundsQ;
            } catch (bytes memory e) {
                _bad(e, "cancelBounds");
            }
        }
        _checkBounds(s0, d0, act);
        if (act) delete gBoundsQ;
    }

    /// The legitimate loosening: current admin queues, waits somewhere inside
    /// [48h, 48h + 9 days], activates. Past the window it must be refused.
    function adminLoosen(uint16 slip, uint16 dev, uint256 wait) public {
        slip = uint16(bound(slip, 0, 200));
        dev = uint16(bound(dev, 0, 2000));
        wait = bound(wait, 48 hours, 48 hours + 9 days);
        uint16 s0 = v.maxSlippageBps();
        uint16 d0 = v.maxDeviationBps();
        vm.prank(gVaultAdmin);
        v.setBounds(slip, dev);
        bool queued = v.setupFinished() && (slip > s0 || dev > d0);
        if (queued) gBoundsQ = BQ(slip, dev, block.timestamp, true);
        else delete gBoundsQ; // F2: the instant path dropped any queue
        _checkBounds(s0, d0, false);
        if (!queued) return;
        vm.warp(block.timestamp + wait);
        s0 = v.maxSlippageBps();
        d0 = v.maxDeviationBps();
        bool act;
        vm.prank(gVaultAdmin);
        try v.activateBounds() {
            act = true;
            nActivateBounds++;
            if (wait > 48 hours + 7 days) vExpiredActivation++;
        } catch (bytes memory e) {
            _bad(e, "adminLoosen");
            if (wait <= 48 hours + 7 days) vUnexpected++;
        }
        _checkBounds(s0, d0, act);
        delete gBoundsQ;
    }

    function claimFees() public {
        address r = v.feeRecipient();
        uint256 b = usdc.balanceOf(r);
        uint256 owed = v.feesAccrued();
        try v.claimFees() {
            uint256 got = usdc.balanceOf(r) - b;
            if (got != owed) vFeeOnPrincipal++;
            feesClaimedTotal += got;
        } catch (bytes memory e) {
            _bad(e, "claimFees");
        }
    }

    // =========================================================== admin: oracle
    function transferOracleAdmin(uint256 who, uint256 to) public {
        address c = _pick(who);
        address n = admins[to % 3];
        vm.prank(c);
        try cl.transferAdmin(n) {
            if (c != gOracleAdmin) vNonAdmin++;
            gOraclePending = n;
        } catch (bytes memory e) {
            _bad(e, "o.transferAdmin");
        }
    }

    function acceptOracleAdmin(uint256 who) public {
        address c = _pick(who);
        vm.prank(c);
        try cl.acceptAdmin() {
            if (c != gOraclePending) vNonAdmin++;
            gOracleAdmin = c;
            gOraclePending = address(0);
        } catch (bytes memory e) {
            _bad(e, "o.acceptAdmin");
        }
    }

    function _checkFeeds(address[2] memory tok, address[2] memory before, bool activated, address actTok) internal {
        for (uint256 i; i < 2; ++i) {
            address now_ = cl.feedOf(tok[i]);
            if (now_ == before[i]) continue;
            if (before[i] == address(0)) continue; // first listing is instant by design
            Q memory q = gFeedQ[tok[i]];
            if (!activated || actTok != tok[i] || !q.live || block.timestamp < q.at + 48 hours || now_ != q.feed) {
                vFeedEarly++;
            }
            if (block.timestamp > q.at + 48 hours + 7 days) vExpiredActivation++;
        }
    }

    function oracleOp(uint256 who, uint8 op, uint8 tsel, uint8 fsel) public {
        address c = _pick(who);
        address tok = tsel % 2 == 0 ? address(stock) : address(t2);
        address fd = address(feeds[fsel % 3]);
        address[2] memory toks = [address(stock), address(t2)];
        address[2] memory b = [cl.feedOf(address(stock)), cl.feedOf(address(t2))];
        bool act;
        vm.prank(c);
        if (op % 4 == 0) {
            try cl.setFeed(tok, fd) {
                if (c != gOracleAdmin) vNonAdmin++;
            } catch (bytes memory e) {
                _bad(e, "o.setFeed");
            }
        } else if (op % 4 == 1) {
            try cl.queueFeed(tok, fd) {
                if (c != gOracleAdmin) vNonAdmin++;
                gFeedQ[tok] = Q(tok, address(0), fd, true, block.timestamp, true);
            } catch (bytes memory e) {
                _bad(e, "o.queueFeed");
            }
        } else if (op % 4 == 2) {
            try cl.activateFeed(tok) {
                if (c != gOracleAdmin) vNonAdmin++;
                act = true;
                nActivateFeed++;
            } catch (bytes memory e) {
                _bad(e, "o.activateFeed");
            }
        } else {
            try cl.cancelFeed(tok) {
                if (c != gOracleAdmin) vNonAdmin++;
                delete gFeedQ[tok];
            } catch (bytes memory e) {
                _bad(e, "o.cancelFeed");
            }
        }
        _checkFeeds(toks, b, act, tok);
        if (act) delete gFeedQ[tok];
    }

    // =========================================================== users
    function create(uint256 u, uint32 rseed, uint256 dep, uint256 n, uint256 iv) public {
        address o = users[u % 4];
        uint32 rid = rseed % 4 == 3 ? 2 : 1;
        dep = bound(dep, 1e6, 400_000e6);
        n = bound(n, 1, 12);
        uint256 inst = (dep + n - 1) / n;
        iv = bound(iv, 1 days, 60 days);
        uint256 yBal = usdc.balanceOf(address(y));
        vm.prank(o);
        try v.createPlan(rid, dep, inst, uint64(iv)) returns (uint256 id) {
            ids.push(id);
            (address tk, address pl,,,) = v.routes(rid);
            gToken[id] = tk;
            gPool[id] = pl;
            gLossEpochAtCreate[id] = lossEpoch;
            nCreate++;
            if (v.totalPrincipal() > v.tvlCap()) vUnexpected++;
            yBal; // first-buy accounting covered by ledger invariants
        } catch (bytes memory e) {
            _bad(e, "create");
        }
    }

    struct Pre {
        uint256 id;
        address o;
        uint256 rem;
        uint256 sh;
        uint64 ne;
        uint256 yBal;
        uint256 poolUsdc;
        uint256 ownerStock;
        uint256 ownerUsdc;
        uint256 ref;
        uint256 price;
        uint256 fees;
        uint16 slip;
        uint16 feeBps;
    }

    Pre internal pre;
    uint256[] internal otherSh;
    uint256[] internal otherRem;

    function _snapOthers(uint256 id) internal {
        delete otherSh;
        delete otherRem;
        for (uint256 i; i < ids.length; ++i) {
            (,,, uint256 r, uint256 s,,) = _plan(ids[i]);
            otherSh.push(ids[i] == id ? 0 : s);
            otherRem.push(ids[i] == id ? 0 : r);
        }
    }

    function _checkOthers(uint256 id) internal {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == id) continue;
            (,,, uint256 r, uint256 s,,) = _plan(ids[i]);
            if (s != otherSh[i] || r != otherRem[i]) vIsolation++;
        }
    }

    function _prep(uint256 seed) internal returns (bool) {
        if (ids.length == 0) return false;
        uint256 id = ids[seed % ids.length];
        for (uint256 j; j < ids.length; ++j) {
            (,,,,,, bool a) = _plan(ids[(seed % ids.length + j) % ids.length]);
            if (a) {
                id = ids[(seed % ids.length + j) % ids.length];
                break;
            }
        }
        // F6: warp to the chosen plan's due time most of the time (it was
        // one call in three), staying early one call in eight so NotYetDue
        // and the stranger's grace stay exercised.
        if (seed % 8 != 0) {
            (,,,,, uint64 ne0,) = _plan(id);
            if (ne0 > block.timestamp) vm.warp(ne0 + (seed % 7 == 0 ? 12 hours : 0));
        }
        nExecTries++;
        (address o,,, uint256 rem, uint256 sh, uint64 ne,) = _plan(id);
        pre = Pre(
            id, o, rem, sh, ne, usdc.balanceOf(address(y)), usdc.balanceOf(address(pool)),
            stock.balanceOf(o), usdc.balanceOf(o), _ref(), y.sharePriceWad(), v.feesAccrued(),
            v.maxSlippageBps(), v.feeBps()
        );
        _snapOthers(id);
        return true;
    }

    function _postExec(address caller) internal {
        nExec++;
        Pre memory p = pre;
        if (block.timestamp < p.ne) vEarly++;
        if (caller == stranger && block.timestamp < uint256(p.ne) + 12 hours) vEarly++;
        (,,, uint256 rem, uint256 sh,, bool act) = _plan(p.id);
        uint256 got = p.yBal - usdc.balanceOf(address(y));
        uint256 burned = p.sh - sh;
        if (got > burned * p.price / 1e18) vOverdraw++;
        uint256 principalOut = p.rem - rem;
        uint256 fee = v.feesAccrued() - p.fees;
        uint256 accrued = got > principalOut ? got - principalOut : 0;
        if (fee > accrued * p.feeBps / 10_000) vFeeOnPrincipal++;
        feesChargedTotal += fee;
        uint256 spend = usdc.balanceOf(address(pool)) - p.poolUsdc;
        if (spend + fee != got) vFeeOnPrincipal++;
        uint256 out = stock.balanceOf(p.o) - p.ownerStock;
        if (spend > 0) {
            uint256 fair = spend * 1e10 / p.ref;
            uint256 minOut = spend * 1e10 * (10_000 - p.slip) / (p.ref * 10_000);
            if (out < minOut) vFill++;
            if (out < fair) {
                uint256 l = (fair - out) * 10_000 / fair;
                if (l > maxFillLossBps) maxFillLossBps = l;
            }
        }
        if (got < principalOut) {
            nShortfall++;
            if (act || rem != 0 || sh != 0) vShortfallState++;
            (,,,,,,, uint32 dn,) = v.plans(p.id);
            if (principalOut - got > maxNoLossShortfall && gLossEpochAtCreate[p.id] == lossEpoch) maxNoLossShortfall = principalOut - got;
            if (principalOut - got > 2 + 2 * uint256(dn) && gLossEpochAtCreate[p.id] == lossEpoch) {
                vShortfallNoLoss++;
                lastBadWhere = "shortfall without loss";
            }
        }
        _checkOthers(p.id);
        _checkPlanRoute();
    }

    function _checkPlanRoute() internal {
        for (uint256 i; i < ids.length; ++i) {
            (, uint32 rid,,,,,) = _plan(ids[i]);
            (address tk, address pl,,,) = v.routes(rid);
            if (tk != gToken[ids[i]] || pl != gPool[ids[i]]) vPlanRouteMoved++;
        }
    }

    function execute(uint256 seed, uint8 who) public {
        if (!_prep(seed)) return;
        address c = who % 3 == 0 ? pre.o : who % 3 == 1 ? keeper : stranger;
        vm.prank(c);
        try v.executeDCA(pre.id) {
            _postExec(c);
        } catch (bytes memory e) {
            _bad(e, "execute");
            _checkOthers(pre.id);
        }
    }

    /// F6. The world here is hostile by default: a feed premium past the
    /// slippage bound, a stale feed, a disabled route, a liquidity cap, and
    /// instant tightenings that ratchet the bounds down, each persist until
    /// something resets them, so most executes used to revert and the
    /// 2,000 x 200 re-test saw about one successful execute per run.
    /// This one resets the world first — the route re-enabled and the
    /// bounds restored to the launch values through their real 48h queues,
    /// then feeds re-anchored to the pool and fresh, lending uncapped — and
    /// then executes, due, as the owner (the keeper may be revoked).
    function executeCalm(uint256 seed) public {
        uint256 n = ids.length;
        if (n == 0) return;
        seed |= 1; // never _prep's one-in-eight "stay early" branch
        uint256 id;
        bool found;
        for (uint256 j; j < n && !found; ++j) {
            id = ids[(seed % n + j) % n];
            (,,,,,, found) = _plan(id);
        }
        if (!found) return;
        (, uint32 rid,,,,,) = _plan(id);
        (,,,, bool en) = v.routes(rid);
        if (!en) adminRestore(uint8(rid - 1));
        uint16 s0 = v.maxSlippageBps();
        uint16 d0 = v.maxDeviationBps();
        if (s0 < 100 || d0 < 500) adminLoosen(s0 < 100 ? 100 : s0, d0 < 500 ? 500 : d0, 48 hours);
        feedMove(0, false);
        y.setLiquidityCap(type(uint256).max);
        if (!_prep(seed)) return;
        nCalm++;
        // A slice this small moves the 20M-deep pool well under the 1%
        // bound, so in the calm world it has no business reverting. (A big
        // slice can legitimately fail closed on its own impact.)
        (,, uint256 inst, uint256 rem,,,) = _plan(pre.id);
        bool small = (inst < rem ? inst : rem) <= 50_000e6;
        if (small) nCalmSmall++;
        address c = pre.o;
        vm.prank(c);
        try v.executeDCA(pre.id) {
            if (small) nCalmSmallOk++;
            _postExec(c);
        } catch (bytes memory e) {
            _bad(e, "executeCalm");
            _checkOthers(pre.id);
            if (small) lastCalmErr = e;
        }
    }

    /// Push the pool, execute as keeper/stranger, unwind — atomically.
    function sandwich(uint256 seed, uint256 push, bool asKeeper) public {
        if (!_prep(seed)) return;
        push = bound(push, 1e6, 3_000_000e6);
        address atk = asKeeper ? keeper : stranger;
        usdc.mint(atk, push);
        vm.startPrank(atk);
        usdc.approve(address(pool), type(uint256).max);
        stock.approve(address(pool), type(uint256).max);
        uint256 got = pool.buy(push);
        pre.poolUsdc = usdc.balanceOf(address(pool));
        vm.stopPrank();
        vm.prank(atk);
        try v.executeDCA(pre.id) {
            nSandwich++;
            _postExec(atk);
        } catch (bytes memory e) {
            _bad(e, "sandwich");
        }
        vm.prank(atk);
        pool.sell(got);
    }

    function exit(uint256 seed) public {
        if (seed % 4 != 0) return;
        if (!_prep(seed / 4)) return;
        (,,,,,, bool act) = _plan(pre.id);
        uint256 val = y.assetsOf(pre.sh);
        bool liquid = val <= y.availableLiquidity();
        vm.prank(pre.o);
        try v.exitPlan(pre.id) {
            nExit++;
            uint256 got = pre.yBal - usdc.balanceOf(address(y));
            if (got > y.assetsOf(pre.sh) + 0 && got > pre.sh * pre.price / 1e18) vOverdraw++;
            uint256 fee = v.feesAccrued() - pre.fees;
            feesChargedTotal += fee;
            uint256 acc = got > pre.rem ? got - pre.rem : 0;
            if (fee > acc * pre.feeBps / 10_000) vFeeOnPrincipal++;
            if (usdc.balanceOf(pre.o) - pre.ownerUsdc + fee != got) vFeeOnPrincipal++;
            _checkOthers(pre.id);
        } catch (bytes memory e) {
            _bad(e, "exit");
            if (act && liquid) vExitLiquidRevert++;
        }
    }

    // =========================================================== world
    function warp(uint256 dt) public {
        vm.warp(block.timestamp + bound(dt, 1, 20 days));
    }

    function accrue(uint256 bps) public {
        y.accrueTo(y.sharePriceWad() * (10_000 + bound(bps, 1, 300)) / 10_000);
    }

    function loss(uint256 bps) public {
        y.setSharePrice(y.sharePriceWad() * (10_000 - bound(bps, 1, 3000)) / 10_000);
        uint256 owed = y.assetsOf(y.totalShares());
        uint256 have = usdc.balanceOf(address(y));
        if (have > owed) {
            vm.prank(address(y));
            usdc.transfer(address(0xdead), have - owed);
        }
        lossEpoch++;
    }

    /// Re-anchor every feed to the pool with a premium in [-300, +300] bps,
    /// or make them stale.
    function feedMove(int256 premBps, bool stale) public {
        premBps = bound(premBps, -300, 300);
        uint256 px = pool.poolPrice(address(0), address(0));
        uint256 ref = uint256(int256(px) * 10_000 / (10_000 + premBps));
        for (uint256 i; i < 3; ++i) {
            if (stale && premBps % 4 == 0) feeds[i].set(int256(ref), block.timestamp > 2 days ? block.timestamp - 2 days : 1, false);
            else feeds[i].set(int256(ref), block.timestamp, true);
        }
    }

    function liquidity(uint256 c) public {
        y.setLiquidityCap(c % 8 == 0 ? bound(c, 0, 1_000_000e6) : type(uint256).max);
    }

    function planCount() external view returns (uint256) {
        return ids.length;
    }
}

/// forge-config: default.invariant.fail-on-revert = true
contract AdvInvariants is Test {
    AdvHandler h;

    function setUp() public {
        h = new AdvHandler();
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](35);
        sel[0] = h.transferVaultAdmin.selector;
        sel[1] = h.acceptVaultAdmin.selector;
        sel[2] = h.queueRoute.selector;
        sel[3] = h.activateRoute.selector;
        sel[4] = h.cancelRoute.selector;
        sel[5] = h.disableRoute.selector;
        sel[6] = h.initRoute.selector;
        sel[7] = h.setParams.selector;
        sel[8] = h.setCapPauseKeeper.selector;
        sel[9] = h.claimFees.selector;
        sel[10] = h.transferOracleAdmin.selector;
        sel[11] = h.acceptOracleAdmin.selector;
        sel[12] = h.oracleOp.selector;
        sel[13] = h.create.selector;
        sel[14] = h.execute.selector;
        sel[15] = h.sandwich.selector;
        sel[16] = h.exit.selector;
        sel[17] = h.warp.selector;
        sel[18] = h.accrue.selector;
        sel[19] = h.loss.selector;
        sel[20] = h.feedMove.selector;
        sel[21] = h.liquidity.selector;
        sel[22] = h.adminRestore.selector;
        sel[23] = h.create.selector;
        sel[24] = h.execute.selector;
        sel[25] = h.sandwich.selector;
        sel[26] = h.sandwich.selector;
        sel[27] = h.execute.selector;
        sel[28] = h.create.selector;
        sel[29] = h.create.selector;
        sel[30] = h.boundsOp.selector;
        sel[31] = h.boundsOp.selector;
        sel[32] = h.adminLoosen.selector;
        sel[33] = h.executeCalm.selector; // F6
        sel[34] = h.executeCalm.selector;
        targetSelector(FuzzSelector(address(h), sel));
    }

    function invariant_timelocks() public view {
        assertEq(h.vRouteEarly(), 0, "route change took effect early / unqueued");
        assertEq(h.vRouteImmutable(), 0, "route token/pool changed");
        assertEq(h.vFeedEarly(), 0, "feed change took effect early");
        assertEq(h.vNonAdmin(), 0, "non-admin call succeeded");
        assertEq(h.vPlanRouteMoved(), 0, "a plan's route moved under it");
        assertEq(h.vExpiredActivation(), 0, "a queued change activated after it expired");
        assertEq(h.vPendingSurvivedDisable(), 0, "a pending re-enable survived disableRoute");
        assertEq(h.vBoundsLoosenedEarly(), 0, "the bounds loosened without a timely queue");
    }

    function invariant_money() public view {
        assertEq(h.vOverdraw(), 0, "plan got more than its shares");
        assertEq(h.vIsolation(), 0, "another plan changed");
        assertEq(h.vFill(), 0, "fill below minOut bound");
        assertEq(h.vFeeOnPrincipal(), 0, "fee accounting");
        assertEq(h.vShortfallState(), 0, "shortfall left plan live");
    }

    function invariant_liveness() public view {
        assertEq(h.vEarly(), 0, "early exec");
        assertEq(h.vPanic(), 0, "panic");
        assertEq(h.vUnexpected(), 0, string(abi.encodePacked("unexpected revert at ", h.lastBadWhere())));
        assertEq(h.vExitLiquidRevert(), 0, "exit reverted while liquid");
    }

    function invariant_shortfallNeedsLoss() public view {
        assertEq(h.vShortfallNoLoss(), 0, "shortfall beyond rounding with no loss");
    }

    function invariant_ledger() public view {
        DcaVault v = h.v();
        uint256 n = h.planCount();
        uint256 sh;
        uint256 rem;
        for (uint256 i; i < n; ++i) {
            (,,, uint256 r, uint256 s,,,, bool a) = v.plans(h.ids(i));
            sh += s;
            rem += r;
            if (!a) {
                assertEq(r, 0, "inactive with principal");
                assertEq(s, 0, "inactive with shares");
            }
        }
        assertEq(sh, v.totalManagedShares(), "share sum");
        assertEq(v.totalManagedShares(), h.y().totalShares(), "adapter shares");
        assertEq(rem, v.totalPrincipal(), "principal sum");
        assertEq(h.usdc().balanceOf(address(v)), v.feesAccrued(), "vault usdc == fees");
        assertEq(h.feesChargedTotal(), v.feesAccrued() + h.feesClaimedTotal(), "fee conservation");
    }

    function _why() internal view returns (string memory r) {
        bytes4[9] memory k = [DcaVault.NotYetDue.selector, DcaVault.PlanInactive.selector, DcaVault.TooEarlyForPublicCall.selector,
            DcaVault.StaleOracle.selector, DcaVault.PoolDiverged.selector, bytes4(keccak256("Error(string)")),
            DcaVault.RouteDisabled.selector, DcaVault.InsufficientAdapterLiquidity.selector, DcaVault.CapExceeded.selector];
        for (uint256 i; i < 9; ++i) r = string.concat(r, " ", vm.toString(h.why(k[i])));
    }

    function afterInvariant() public {
        InvStats.record(
            "AdvInvariants",
            string.concat(
                vm.toString(h.nExec()), " ", vm.toString(h.nExecTries()), " ",
                vm.toString(h.planCount()), " ", vm.toString(h.nCalm()), " ",
                vm.toString(h.nCalmSmall()), " ", vm.toString(h.nCalmSmallOk()), " |", _why()
            )
        );
        console.log(
            string.concat(
                vm.toString(h.planCount()), " ", vm.toString(h.nExec()), " ", vm.toString(h.nSandwich()), " ",
                vm.toString(h.nExit()), " ", vm.toString(h.nShortfall()), " ", vm.toString(h.maxFillLossBps()), " ",
                vm.toString(h.nActivateRoute()), " ", vm.toString(h.nActivateFeed()), " ", vm.toString(h.nAccept()), " ", vm.toString(h.maxNoLossShortfall()), " |", _why()
            )
        );
        console.log(
            string.concat(
                "bounds activated ", vm.toString(h.nActivateBounds()), ", expired refusals ",
                vm.toString(h.nExpiredRefusals())
            )
        );
        // F6: every calm execute of a small slice lands, so each run executes
        // at least as many plans as it made such attempts on.
        assertEq(
            h.nCalmSmallOk(),
            h.nCalmSmall(),
            string.concat("F6: a calm execute reverted: ", vm.toString(h.lastCalmErr()))
        );
        assertGe(h.nExec(), h.nCalmSmall(), "F6: fewer successful executes than calm attempts");
    }
}
