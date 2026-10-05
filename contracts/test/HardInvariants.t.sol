// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";
import {IYieldAdapter} from "../src/interfaces/IYieldAdapter.sol";
import {
    MockERC20, MockStock, MockYieldAdapter, MockPriceOracle
} from "../src/mocks/Mocks.sol";
import {MockRebasingPool, MockRebasingAdapter} from "../src/mocks/RebasingMocks.sol";
import {InvStats} from "./utils/InvStats.sol";

/// @notice The hard test's stateful suite (2026-09-28), kept as a permanent
///         regression net. Six actors, a hostile swap venue, a lending leg that
///         can lose money (ERC-4626-shaped and rebasing), stale feeds, price
///         shocks, paused stock, keeper rotation, route toggles and cap cuts.
/// @dev    Against the unfixed code this suite FAILED `invariant_noPanicInCreate`
///         (one-shot plan, C4) and `invariant_probe_fillWithinImpactBound`
///         (fills 385-396bp worse than the feed, C2). Both are asserted here as
///         plain invariants now, alongside C11: the handler classifies every
///         revert and anything that is not an expected custom error (or a
///         hostile mock's own named refusal) fails `invariant_noUnexpectedRevert`.
///
/// Swap venue with a settable pool premium (the pool price the vault reads,
/// relative to the oracle) and a settable post-quote shortfall. Enforces minOut
/// like AerodromeSwapAdapter does.
contract HostileSwap is ISwapAdapter {
    MockERC20 public immutable usdc;
    MockPriceOracle public immutable oracle;
    int256 public premiumBps; // pool price = ref * (1 + premium)
    uint256 public shortfallBps; // fill worse than the pool price by this much
    bool public enforceMin = true;

    constructor(MockERC20 u, MockPriceOracle o) {
        usdc = u;
        oracle = o;
    }

    function setPremium(int256 b) external {
        premiumBps = b;
    }

    function setShortfall(uint256 b) external {
        shortfallBps = b;
    }

    function setEnforceMin(bool e) external {
        enforceMin = e;
    }

    function poolPrice(address, address t) public view returns (uint256) {
        (uint256 p,) = oracle.latestPrice(t);
        return uint256(int256(p) * (10_000 + premiumBps) / 10_000);
    }

    function swapExactIn(address, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 out)
    {
        usdc.transferFrom(msg.sender, address(this), amountIn);
        uint256 px = poolPrice(address(0), tokenOut);
        out = amountIn * 1e10 / px * (10_000 - shortfallBps) / 10_000;
        if (enforceMin) require(out >= minOut, "SLIPPAGE");
        MockStock(tokenOut).mint(to, out);
    }
}

contract HardHandler is Test {
    DcaVault public vault;
    MockERC20 public usdc;
    MockStock public stock;
    MockPriceOracle public oracle;
    HostileSwap public swap;
    IYieldAdapter public adapter;
    MockYieldAdapter public y4626; // set when !rebasing
    MockRebasingPool public rpool; // set when rebasing
    bool public rebasing;
    address public admin;

    address[] public actors;
    uint256[] public planIds;
    address public keeper = address(0xBEEF01);
    address constant STRANGER = address(0x5757);
    address constant SINK = address(0xdead);

    uint256 constant REF = 227_56000000;

    // ------------------------------------------------------------ ghosts
    bool public lossHappened; // any event that can legitimately push a plan under water
    bool public capLowered;
    uint256 public panics; // Panic(uint256) from any vault entry point
    uint256 public panicsCreate;
    uint256 public execOk;
    uint256 public execCalls; // F6: execute attempts on an ACTIVE plan
    uint256 public execHealthy; // ...of which the world was healthy (see _healthy)
    uint256 public panicsCreateOneShot;
    uint256 public panicsCreateMulti;
    uint256 public panicsExec;
    uint256 public panicsExit;
    uint256 public lastPanicCode;
    string public lastPanicWhere;
    uint256 public capViolations;
    uint256 public doubleExec; // executed before its own nextExecution
    uint256 public isolationViolations;
    string public lastIsolation;
    uint256 public exitMismatch; // exit paid != assetsOf(shares) - fee
    uint256 public exitUnderPrincipal; // exit paid < remaining principal without any loss event
    uint256 public maxExitShortWei;
    uint256 public exitRevertedWhileLiquid;
    uint256 public execRevertedHealthy; // executes that "should" have succeeded
    bytes public lastHealthyRevert;
    uint256 public maxFillLossBps; // worst fill vs Chainlink reference, bps
    uint256 public idleUsdcDonated; // USDC donated straight into the vault
    uint256 public completedMismatch;
    uint256 public stoppedPlanInconsistent;
    uint256 public stuckFinalExec; // plan with remaining<=installment whose owner exec reverted w/ panic
    uint256 public ledgerOps; // supplies + withdrawals: each may round one share-unit against the pool
    uint256 public unexpected; // C11: a revert that is not on the allowlist
    bytes public lastUnexpected;
    string public lastUnexpectedWhere;
    mapping(uint256 => uint256) public deposited;
    mapping(uint256 => uint256) public execCount;
    mapping(bytes4 => uint256) public execWhy; // execute reverts, by selector
    uint256 public createOk;
    uint256 public calmTries; // executeCalm calls that reached an active plan
    uint256 public calmOk;
    // Round 6b: plans built with the SHORTEST last period the vault admits
    // (see createPlan), and how many of those last periods were bought.
    uint256 public shortTails;
    uint256 public shortTailsBought;
    mapping(uint256 => bool) public isShortTail;

    constructor(
        DcaVault v,
        MockERC20 u,
        MockStock s,
        MockPriceOracle o,
        HostileSwap sw,
        IYieldAdapter a,
        MockYieldAdapter y,
        MockRebasingPool rp,
        address[] memory act,
        address adm
    ) {
        vault = v;
        usdc = u;
        stock = s;
        oracle = o;
        swap = sw;
        adapter = a;
        y4626 = y;
        rpool = rp;
        rebasing = address(rp) != address(0);
        actors = act;
        admin = adm;
    }

    // ------------------------------------------------------------ helpers
    function _plan(uint256 id)
        internal
        view
        returns (
            address owner,
            uint256 inst,
            uint256 rem,
            uint256 shares,
            uint64 nextExec,
            uint64 interval,
            uint32 done,
            bool active
        )
    {
        (owner,, inst, rem, shares, nextExec, interval, done, active) = vault.plans(id);
    }

    function _isPanic(bytes memory err, string memory where) internal returns (bool) {
        if (err.length == 36 && bytes4(err) == bytes4(0x4e487b71)) {
            uint256 code;
            assembly {
                code := mload(add(err, 36))
            }
            panics++;
            if (keccak256(bytes(where)) == keccak256("createPlan")) panicsCreate++;
            else if (keccak256(bytes(where)) == keccak256("executeDCA")) panicsExec++;
            else panicsExit++;
            lastPanicCode = code;
            lastPanicWhere = where;
            return true;
        }
        return false;
    }

    /// @dev C11. What each entry point is ALLOWED to revert with. Anything
    ///      else — a Panic, empty revert data, an error from nowhere — is a
    ///      finding.
    function _allowed(bytes memory err) internal pure returns (bool) {
        if (err.length < 4) return false;
        bytes4 s = bytes4(err);
        if (
            s == DcaVault.NotYetDue.selector || s == DcaVault.PlanInactive.selector
                || s == DcaVault.TooEarlyForPublicCall.selector || s == DcaVault.StaleOracle.selector
                || s == DcaVault.PoolDiverged.selector
                || s == DcaVault.InsufficientAdapterLiquidity.selector
                || s == DcaVault.RouteDisabled.selector || s == DcaVault.CapExceeded.selector
                || s == DcaVault.BadParams.selector || s == DcaVault.Paused.selector
                || s == DcaVault.TimelockActive.selector || s == DcaVault.NothingQueued.selector
                || s == DcaVault.QueueExpired.selector
        ) return true;
        // The hostile mocks' own named refusals: a venue refusing a fill
        // below minOut, and a B20-style issuer pause.
        if (s == bytes4(keccak256("Error(string)"))) {
            bytes32 h = keccak256(err);
            return h == keccak256(abi.encodeWithSignature("Error(string)", "SLIPPAGE"))
                || h == keccak256(abi.encodeWithSignature("Error(string)", "STOCK_PAUSED"));
        }
        return false;
    }

    function _classify(bytes memory err, string memory where) internal returns (bool panic) {
        panic = _isPanic(err, where);
        if (!_allowed(err)) {
            unexpected++;
            lastUnexpected = err;
            lastUnexpectedWhere = where;
        }
    }

    struct Snap {
        uint256 rem;
        uint256 shares;
        uint64 nextExec;
        uint32 done;
        bool active;
        uint256 ownerUsdc;
        uint256 ownerStock;
    }

    function _snapAll() internal view returns (Snap[] memory s) {
        s = new Snap[](planIds.length);
        for (uint256 i; i < planIds.length; ++i) {
            (address o,, uint256 rem, uint256 sh, uint64 ne,, uint32 d, bool a) = _plan(planIds[i]);
            s[i] = Snap(rem, sh, ne, d, a, usdc.balanceOf(o), stock.balanceOf(o));
        }
    }

    /// Everything not owned by `actor` must be untouched.
    function _checkIsolation(Snap[] memory before, address actor, string memory where) internal {
        for (uint256 i; i < before.length; ++i) {
            (address o,, uint256 rem, uint256 sh, uint64 ne,, uint32 d, bool a) = _plan(planIds[i]);
            if (o == actor) continue;
            if (
                rem != before[i].rem || sh != before[i].shares || ne != before[i].nextExec
                    || d != before[i].done || a != before[i].active
                    || usdc.balanceOf(o) < before[i].ownerUsdc
                    || stock.balanceOf(o) < before[i].ownerStock
            ) {
                isolationViolations++;
                lastIsolation = where;
            }
        }
    }

    // ------------------------------------------------------------ actions
    function createPlan(uint256 seed, uint256 dep, uint256 months, uint256 ivSeed) public {
        address a = actors[seed % actors.length];
        uint256 cap = vault.tvlCap();
        // extreme sizes: 1 unit .. the cap, biased to edges
        uint256 mode = seed % 5;
        if (mode == 0) dep = bound(dep, 1, 100);
        else if (mode == 1) dep = cap > vault.totalPrincipal() ? cap - vault.totalPrincipal() : 1;
        else if (mode == 2) dep = bound(dep, cap / 2, cap + 10);
        else dep = bound(dep, 1e6, 100_000e6);
        months = bound(months, 3, 60);
        // Rounded UP, so the last period is the short one, by less than
        // `months` wei. Rounded down, the remainder was an extra period of a
        // few wei, which the vault refuses since round 6 (R5-5): this handler
        // then created almost nothing, and every invariant below passed on
        // an empty vault.
        uint256 inst = (dep + months - 1) / months;
        // Round 6b (review finding 8). Rounding up leaves every last period
        // within `months` wei of a full one, so the edge R5-5 created, a
        // last period of barely the minimum, was in none of these runs.
        // One ordinary deposit in four is now built the other way round:
        // one to three whole periods (few, so that a run of 64 calls gets
        // as far as the last one), then a tail of MIN_INSTALLMENT plus 0 to
        // 7 wei. (seed 3, which HandlerSanity uses, is not one of them.)
        bool shortTail = mode >= 3 && (seed / 5) % 4 == 3;
        if (shortTail) {
            months = 1 + months % 3;
            inst = bound(dep, 2e6, 2_000e6);
            dep = months * inst + vault.MIN_INSTALLMENT() + (seed / 20) % 8;
        }
        uint64 iv = uint64(bound(ivSeed, 1 days, 90 days));
        usdc.mint(a, dep);
        uint256 tpBefore = vault.totalPrincipal();
        Snap[] memory s = _snapAll();
        vm.startPrank(a);
        usdc.approve(address(vault), type(uint256).max);
        try vault.createPlan(1, dep, inst, iv) returns (uint256 id) {
            planIds.push(id);
            createOk++;
            deposited[id] = dep;
            if (shortTail) {
                shortTails++;
                isShortTail[id] = true;
            }
            // 1 normally; 0 when the feed was frozen and the first buy waits.
            (,,,,,,, uint32 done,) = vault.plans(id);
            execCount[id] = done;
            ledgerOps += 1 + done;
            if (!capLowered && tpBefore + dep > vault.tvlCap()) capViolations++;
        } catch (bytes memory err) {
            if (_classify(err, "createPlan")) {
                if (inst == dep) panicsCreateOneShot++;
                else panicsCreateMulti++;
            }
        }
        vm.stopPrank();
        _checkIsolation(s, a, "createPlan");
    }

    struct Ex {
        uint256 id;
        address o;
        uint256 inst;
        uint256 rem;
        uint256 slice;
        uint256 want;
        uint256 spend;
        uint256 ref;
        uint256 stockBefore;
        bool due;
        address caller;
    }

    /// @dev Round 3 (F6). This used to take `planIds[seed % n]`, usually a
    ///      finished plan, and return; and nothing ever moved time to a due
    ///      date, so the 2,000 x 200 re-test logged ZERO successful executes.
    ///      Now it takes the first ACTIVE plan from `seed` and, when `toDue`,
    ///      warps to its due time (plus grace for a stranger) unless `seed`
    ///      says to stay early, which keeps NotYetDue / grace exercised.
    function _prep(uint256 seed, uint8 who, bool toDue) internal returns (Ex memory e, bool ok) {
        uint256 n = planIds.length;
        bool act;
        for (uint256 j; j < n; ++j) {
            e.id = planIds[(seed % n + j) % n];
            (,,,,,,, act) = _plan(e.id);
            if (act) break;
        }
        if (!act) return (e, false);
        uint256 sh;
        uint64 ne;
        (e.o, e.inst, e.rem, sh, ne,,,) = _plan(e.id);
        e.caller = who == 0 ? e.o : who == 1 ? keeper : STRANGER;
        if (toDue && seed % 8 != 0) {
            uint256 due = uint256(ne) + (who == 2 ? 12 hours : 0);
            if (due > block.timestamp) vm.warp(due);
        }
        execCalls++;
        e.stockBefore = stock.balanceOf(e.o);
        (e.ref,) = oracle.latestPrice(address(stock));
        uint256 value = adapter.assetsOf(sh);
        uint256 accrued = value > e.rem ? value - e.rem : 0;
        e.slice = e.inst < e.rem ? e.inst : e.rem;
        e.want = e.slice + accrued;
        e.spend = e.want - accrued * vault.feeBps() / 10_000;
        e.due = block.timestamp >= ne;
        ok = true;
    }

    function _execAs(uint256 seed, uint8 who, bool toDue) internal {
        if (planIds.length == 0) return;
        (Ex memory e, bool ok) = _prep(seed, who, toDue);
        if (!ok) return;
        if (_healthy(e, who)) execHealthy++;
        Snap[] memory s = _snapAll();
        vm.recordLogs();
        vm.prank(e.caller);
        try vault.executeDCA(e.id) {
            if (!e.due) doubleExec++;
            execCount[e.id]++;
            execOk++;
            ledgerOps++;
            // The short last period itself: what was left was under one
            // installment, and this buy spent it.
            if (isShortTail[e.id] && e.rem < e.inst) shortTailsBought++;
            _fill(e);
        } catch (bytes memory err) {
            execWhy[err.length >= 4 ? bytes4(err) : bytes4(0)]++;
            bool panic = _classify(err, "executeDCA");
            if (panic && e.rem <= e.inst) stuckFinalExec++;
            if (_healthy(e, who)) {
                execRevertedHealthy++;
                lastHealthyRevert = err;
            }
        }
        _checkIsolation(s, e.o, "executeDCA");
    }

    /// @dev `spend` is read from the vault's own DCAExecuted event
    ///      (slice + accrued - fee), because the final slice spends whatever
    ///      the redemption returned and a pre-computed figure would be wrong.
    function _fill(Ex memory e) internal {
        uint256 got = stock.balanceOf(e.o) - e.stockBefore;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == DcaVault.DCAExecuted.selector) {
                (uint256 sl, uint256 ac,, uint256 fe) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                e.spend = sl + ac - fe;
            }
        }
        if (e.ref > 0 && e.spend > 1e4) {
            uint256 fair = e.spend * 1e10 / e.ref;
            if (got < fair) {
                uint256 lossBps = (fair - got) * 10_000 / fair;
                if (lossBps > maxFillLossBps) maxFillLossBps = lossBps;
            }
        }
    }

    function _healthy(Ex memory e, uint8 who) internal view returns (bool) {
        return e.due && who != 2 && !lossHappened && e.ref > 0 && swap.premiumBps() == 0
            && swap.shortfallBps() == 0 && !stock.paused() && oracle.fresh() && _liquid(e.want)
            && _routeOn();
    }

    function _liquid(uint256 want) internal view returns (bool) {
        return adapter.availableLiquidity() >= want;
    }

    function _routeOn() internal view returns (bool en) {
        (,,,, en) = vault.routes(1);
    }

    function executeOwner(uint256 seed) public {
        _execAs(seed, 0, true);
    }

    function executeKeeper(uint256 seed) public {
        _execAs(seed, 1, true);
    }

    function executeStranger(uint256 seed) public {
        _execAs(seed, 2, true);
    }

    /// F6. Every hostile switch in this handler is sticky until something
    /// resets it, so most of a run is spent in a world where nothing can
    /// execute, and nothing did. These two put the world back first — feed
    /// fresh at the reference, honest venue, stock live, lending uncapped,
    /// the route re-enabled through its real 48h queue if a disable is in
    /// force — and then act, due. Losses, fees, cap cuts and keeper rotation
    /// are left exactly as they were: those are the states worth executing
    /// through.
    function _calm() internal {
        oracle.setPrice(address(stock), REF);
        oracle.setFresh(true);
        swap.setPremium(0);
        swap.setShortfall(0);
        stock.setPaused(false);
        if (rebasing) rpool.setLiquidityCap(type(uint256).max);
        else y4626.setLiquidityCap(type(uint256).max);
        if (!_routeOn()) {
            (address t, address p, address f, uint8 k,) = vault.routes(1);
            vm.prank(admin);
            vault.queueRoute(1, DcaVault.Route({token: t, pool: p, feed: f, dexKind: k, enabled: true}));
            vm.warp(block.timestamp + vault.ADMIN_DELAY());
            oracle.setPrice(address(stock), REF); // keep the mock feed's timestamp current
            vm.prank(admin);
            vault.activateRoute(1);
        }
    }

    function executeCalm(uint256 seed, bool asKeeper) public {
        if (planIds.length == 0) return;
        _calm();
        uint256 tries0 = execCalls;
        uint256 ok0 = execOk;
        // `seed | 1`: never the one-in-eight "stay early" branch.
        _execAs(seed | 1, asKeeper ? 1 : 0, true);
        if (execCalls > tries0) calmTries++;
        if (execOk > ok0) calmOk++;
    }

    function createCalm(uint256 seed, uint256 dep, uint256 months, uint256 ivSeed) public {
        _calm();
        // mode 3: an ordinary deposit, 1..100k USDC; one in four of them
        // with the short tail (the seed's next digit picks it).
        createPlan(seed / 10 * 5 + 3, dep, months, ivSeed);
    }

    /// keeper fires the same plan twice in one block: the second call must
    /// not move time, or it would not be the same block.
    function executeTwice(uint256 seed) public {
        _execAs(seed, 1, true);
        _execAs(seed, 1, false);
    }

    function exitPlan(uint256 seed) public {
        if (planIds.length == 0) return;
        uint256 id = planIds[seed % planIds.length];
        (address o,, uint256 rem, uint256 sh,,,, bool act) = _plan(id);
        if (!act) return;
        uint256 value = adapter.assetsOf(sh);
        uint256 accrued = value > rem ? value - rem : 0;
        uint256 fee = accrued * vault.feeBps() / 10_000;
        bool liquid = adapter.availableLiquidity() >= value;
        uint256 balBefore = usdc.balanceOf(o);
        Snap[] memory s = _snapAll();
        vm.prank(o);
        try vault.exitPlan(id) {
            uint256 paid = usdc.balanceOf(o) - balBefore;
            if (paid != value - fee) exitMismatch++;
            if (!lossHappened && paid < rem) {
                // Rounding, not loss: the supply rounds shares down and every
                // exact withdraw rounds the burn up, each by under one share
                // unit, against THIS plan (the documented D7 drift). A flat
                // 3 wei held only while executes almost never ran; once F6
                // made them run, 3-4 executes at index > 1 came out 4 wei
                // short. The bound is per ledger operation of this plan.
                uint256 tol = (1 + execCount[id]) * (adapter.assetsOf(1) + 1) + 2;
                if (rem - paid > tol) exitUnderPrincipal++;
                if (rem - paid > maxExitShortWei) maxExitShortWei = rem - paid;
            }
            (,, uint256 rem2, uint256 sh2,,,, bool act2) = _plan(id);
            if (rem2 != 0 || sh2 != 0 || act2) stoppedPlanInconsistent++;
        } catch (bytes memory err) {
            _classify(err, "exitPlan");
            if (liquid) exitRevertedWhileLiquid++;
        }
        _checkIsolation(s, o, "exitPlan");
    }

    function warp(uint256 by) public {
        uint256 m = by % 4;
        if (m == 0) by = bound(by, 1, 1 hours);
        else if (m == 1) by = bound(by, 11 hours, 13 hours);
        else by = bound(by, 1 days, 400 days);
        vm.warp(block.timestamp + by);
        // keep the feed "updated" unless a stale action says otherwise
    }

    function accrue(uint256 wad) public {
        if (rebasing) {
            rpool.accrue(bound(wad, 1e18, 1.05e18));
        } else {
            uint256 cur = y4626.sharePriceWad();
            y4626.accrueTo(cur * bound(wad, 1e18, 1.05e18) / 1e18);
        }
    }

    /// A REAL loss: value falls and the assets leave.
    function loss(uint256 wad) public {
        wad = bound(wad, 0.9e18, 0.9999e18);
        lossHappened = true;
        if (rebasing) {
            rpool.slash(wad);
            uint256 owed = rpool.totalScaled() * rpool.index() / rpool.RAY();
            uint256 have = usdc.balanceOf(address(rpool));
            if (have > owed) {
                vm.prank(address(rpool));
                usdc.transfer(SINK, have - owed);
            }
        } else {
            uint256 np = y4626.sharePriceWad() * wad / 1e18;
            if (np == 0) np = 1;
            y4626.setSharePrice(np);
            uint256 owed = y4626.assetsOf(y4626.totalShares());
            uint256 have = usdc.balanceOf(address(y4626));
            if (have > owed) {
                vm.prank(address(y4626));
                usdc.transfer(SINK, have - owed);
            }
        }
    }

    function priceMove(uint256 seed) public {
        uint256 m = seed % 6;
        uint256 np;
        if (m == 0) np = 0;
        else if (m == 1) np = REF * 3;
        else if (m == 2) np = REF / 3;
        else np = bound(seed, REF / 2, REF * 2);
        oracle.setPrice(address(stock), np);
    }

    function restorePrice() public {
        oracle.setPrice(address(stock), REF);
        swap.setPremium(0);
        swap.setShortfall(0);
        oracle.setFresh(true);
    }

    function setStale(uint256 seed) public {
        oracle.setFresh(seed % 3 != 0);
    }

    function setPremium(int256 b) public {
        swap.setPremium(bound(b, -2500, 2500));
    }

    function setShortfall(uint256 b) public {
        swap.setShortfall(bound(b, 0, 300));
    }

    function liquidityCap(uint256 c) public {
        c = c % 3 == 0 ? type(uint256).max : bound(c, 0, 1_000_000e6);
        if (rebasing) rpool.setLiquidityCap(c);
        else y4626.setLiquidityCap(c);
    }

    function donateToAdapter(uint256 amt) public {
        amt = bound(amt, 1, 50_000e6);
        if (rebasing) usdc.mint(address(rpool), amt);
        else usdc.mint(address(y4626), amt);
    }

    function donateToVault(uint256 amt) public {
        amt = bound(amt, 1, 50_000e6);
        usdc.mint(address(vault), amt);
        idleUsdcDonated += amt;
    }

    function rotateKeeper(uint256 seed) public {
        vm.startPrank(admin);
        vault.setKeeper(keeper, false);
        keeper = address(uint160(0xBEEF00 + (seed % 16)));
        vault.setKeeper(keeper, true);
        vm.stopPrank();
    }

    function setFee(uint16 bps) public {
        vm.prank(admin);
        vault.setFee(uint16(bound(bps, 0, 1000)));
    }

    /// Disabling is instant; re-enabling is queued and needs `activateRoute`
    /// after the delay (the `warp` action gets there).
    function toggleRoute(uint256 seed) public {
        (address t, address p, address f, uint8 k,) = vault.routes(1);
        vm.prank(admin);
        if (seed % 4 == 0) {
            vault.disableRoute(1);
        } else {
            vault.queueRoute(1, DcaVault.Route({token: t, pool: p, feed: f, dexKind: k, enabled: true}));
        }
    }

    /// F6: a queued re-enable is activated inside its window when there is
    /// one (warping to its eta if needed), so a disable does not silence
    /// executions for the rest of the run.
    function activateRoute() public {
        (,,,,, uint64 eta) = vault.pendingRoutes(1);
        if (eta > block.timestamp) vm.warp(eta);
        vm.prank(admin);
        try vault.activateRoute(1) {}
        catch (bytes memory err) {
            _classify(err, "activateRoute");
        }
    }

    /// Anyone may push accrued fees to the recipient.
    function claimFees() public {
        try vault.claimFees() {}
        catch (bytes memory err) {
            _classify(err, "claimFees");
        }
    }

    function pauseStock(uint256 seed) public {
        stock.setPaused(seed % 4 == 0);
    }

    function lowerCap(uint256 c) public {
        capLowered = true;
        vm.prank(admin);
        vault.setTvlCap(bound(c, 0, 1_000_000e6));
    }

    function planCount() external view returns (uint256) {
        return planIds.length;
    }
}

abstract contract HardBase is Test {
    MockERC20 usdc;
    MockStock stock;
    MockPriceOracle oracle;
    HostileSwap swap;
    DcaVault vault;
    HardHandler h;
    IYieldAdapter adapter;
    MockYieldAdapter y4626;
    MockRebasingPool rpool;

    uint256 constant CAP = 1_000_000e6;

    function _rebasing() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(1_780_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("Mock NVDAc", "NVDAc");
        oracle = new MockPriceOracle();
        swap = new HostileSwap(usdc, oracle);
        oracle.setPrice(address(stock), 227_56000000);
        if (_rebasing()) {
            rpool = new MockRebasingPool(usdc);
            adapter = new MockRebasingAdapter(usdc, rpool);
        } else {
            y4626 = new MockYieldAdapter(usdc);
            adapter = y4626;
        }
        vault = new DcaVault(IERC20(address(usdc)), adapter, swap, oracle, CAP);
        if (_rebasing()) MockRebasingAdapter(address(adapter)).bindVault(address(vault));
        else y4626.bindVault(address(vault));
        vault.initRoute(
            1,
            DcaVault.Route({
                token: address(stock), pool: address(swap), feed: address(oracle), dexKind: 0, enabled: true
            })
        );
        vault.finishSetup();
        vault.setFeeRecipient(address(0xFEE5));
        address[] memory a = new address[](6);
        for (uint256 i; i < 6; ++i) a[i] = address(uint160(0xA100 + i));
        h = new HardHandler(vault, usdc, stock, oracle, swap, adapter, y4626, rpool, a, address(this));
        vault.setKeeper(h.keeper(), true);
        targetContract(address(h));
    }

    /// F6: the handler really drives executions. Every `executeCalm` — a
    /// due plan in a world put back to healthy, whatever losses, fee, cap
    /// cuts and keeper rotations came before — must land, so each run
    /// executes at least as many plans as it made calm attempts on. (At
    /// 2,000 x 200 that is ~7 calm attempts and ~10 successful executes a
    /// run; it was ZERO successful executes before F6.)
    function afterInvariant() public {
        emit log_named_uint("execOk", h.execOk());
        InvStats.record(
            _rebasing() ? "HardInvariantsRebasing" : "HardInvariants4626",
            string.concat(
                vm.toString(h.execOk()), " ", vm.toString(h.execCalls()), " ",
                vm.toString(h.execHealthy()), " ", vm.toString(h.createOk()), " ",
                vm.toString(h.calmTries()), " ", vm.toString(h.calmOk()), " |", _why(),
                // Appended in round 6b, after everything that was there:
                // short-tail plans created, and short last periods bought.
                " | ", vm.toString(h.shortTails()), " ", vm.toString(h.shortTailsBought())
            )
        );
        assertEq(h.calmOk(), h.calmTries(), "F6: a calm execute reverted");
        assertGe(h.execOk(), h.calmTries(), "F6: fewer successful executes than calm attempts");
    }

    function _why() internal view returns (string memory r) {
        bytes4[9] memory k = [
            DcaVault.NotYetDue.selector,
            DcaVault.TooEarlyForPublicCall.selector,
            DcaVault.StaleOracle.selector,
            DcaVault.PoolDiverged.selector,
            bytes4(keccak256("Error(string)")),
            DcaVault.RouteDisabled.selector,
            DcaVault.InsufficientAdapterLiquidity.selector,
            DcaVault.SlippageExceeded.selector,
            DcaVault.PlanInactive.selector
        ];
        for (uint256 i; i < 9; ++i) r = string.concat(r, " ", vm.toString(h.execWhy(k[i])));
    }

    function invariant_noPanicInCreate() public view {
        assertEq(h.panicsCreateOneShot(), 0, "Panic in createPlan (installment == deposit)");
    }

    function invariant_noPanicInCreateMultiPeriod() public view {
        assertEq(h.panicsCreateMulti(), 0, "Panic in createPlan (multi-period)");
    }

    function invariant_noPanicInExecute() public view {
        assertEq(h.panicsExec(), 0, "Panic in executeDCA");
    }

    function invariant_noPanicInExit() public view {
        assertEq(h.panicsExit(), 0, "Panic in exitPlan");
    }

    function invariant_shareLedgerSums() public view {
        uint256 sum;
        uint256 n = h.planCount();
        for (uint256 i; i < n; ++i) {
            (,,,, uint256 sh,,,,) = vault.plans(h.planIds(i));
            sum += sh;
        }
        assertEq(sum, vault.totalManagedShares());
    }

    function invariant_principalSums() public view {
        uint256 sum;
        uint256 n = h.planCount();
        for (uint256 i; i < n; ++i) {
            (,,, uint256 rem,,,,,) = vault.plans(h.planIds(i));
            sum += rem;
        }
        assertEq(sum, vault.totalPrincipal());
    }

    function invariant_capNeverExceededByCreate() public view {
        assertEq(h.capViolations(), 0);
        if (!h.capLowered()) assertLe(vault.totalPrincipal(), vault.tvlCap());
    }

    function invariant_neverExecutedBeforeDue() public view {
        assertEq(h.doubleExec(), 0);
    }

    function invariant_isolation() public view {
        assertEq(h.isolationViolations(), 0, h.lastIsolation());
    }

    function invariant_exitPaysExactlyItsShares() public view {
        assertEq(h.exitMismatch(), 0);
        assertEq(h.stoppedPlanInconsistent(), 0);
    }

    function invariant_exitNeverRevertsWhenLiquid() public view {
        assertEq(h.exitRevertedWhileLiquid(), 0);
    }

    /// The vault's USDC is exactly what was donated to it plus fees not yet
    /// claimed: it never spends a stranger's donation, and it never keeps a
    /// plan's money after the transaction that moved it.
    function invariant_vaultUsdcIsDonationsPlusFees() public view {
        assertEq(
            usdc.balanceOf(address(vault)),
            h.idleUsdcDonated() + vault.feesAccrued(),
            "vault USDC != donations + unclaimed fees"
        );
    }

    /// C11: nothing reverted outside the allowlist.
    function invariant_noUnexpectedRevert() public view {
        assertEq(
            h.unexpected(),
            0,
            string.concat(
                "unexpected revert in ", h.lastUnexpectedWhere(), ": ", vm.toString(h.lastUnexpected())
            )
        );
    }

    function invariant_vaultHoldsNoStock() public view {
        assertEq(stock.balanceOf(address(vault)), 0);
    }

    function invariant_completedMatchesExecutions() public view {
        uint256 n = h.planCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = h.planIds(i);
            (,,,,,,, uint32 done,) = vault.plans(id);
            assertEq(done, h.execCount(id));
        }
    }

    /// Solvency: without any loss event, the pooled position covers principal.
    function invariant_solvencyNoLoss() public view {
        if (h.lossHappened()) return;
        // Every supply rounds shares DOWN and every exact withdraw rounds the
        // burn UP, each against the pool, by under one share-unit's value plus
        // a wei. Without a loss the index only rises, so today's unit is the
        // largest there has been. (The first version allowed a flat 2 wei per
        // plan; the rebasing leg at index > 1 beat that by 1 wei at 2,000 runs.)
        uint256 v = adapter.assetsOf(vault.totalManagedShares());
        uint256 slack = h.ledgerOps() * (adapter.assetsOf(1) + 2);
        assertGe(v + slack, vault.totalPrincipal(), "pool worth less than principal");
    }

    // ---- the hard test's probes, which the unfixed code broke; they must hold now
    function invariant_probe_exitNeverUnderPrincipalWithoutLoss() public view {
        assertEq(h.exitUnderPrincipal(), 0, "exit paid less than remaining principal, no loss");
    }

    function invariant_probe_healthyExecNeverReverts() public view {
        assertEq(h.execRevertedHealthy(), 0, "a due, authorised, healthy execute reverted");
    }

    /// C2. Threat model: the worst fill anyone can cause by choosing the
    /// block, pushing the pool, or both, is maxSlippageBps against the feed.
    function invariant_probe_fillWithinSlippageBound() public view {
        assertLe(
            h.maxFillLossBps(), uint256(vault.maxSlippageBps()) + 1, "fill worse than the slippage bound"
        );
    }
}

contract HardInvariants4626 is HardBase {
    function _rebasing() internal pure override returns (bool) {
        return false;
    }
}

contract HardInvariantsRebasing is HardBase {
    function _rebasing() internal pure override returns (bool) {
        return true;
    }
}

contract HandlerSanity is HardBase {
    function _rebasing() internal pure override returns (bool) {
        return false;
    }

    /// The handler measures what it claims to: a 300bp pool premium is
    /// refused outright (it is past the 100bp bound), and a 60bp one fills
    /// and is measured as roughly 60bp of loss against the feed.
    function test_handlerMeasuresFillLoss() public {
        h.createPlan(3, 50_000e6, 10, 30 days);
        h.setPremium(300);
        vm.warp(block.timestamp + 31 days);
        h.executeOwner(0);
        (,,,,,,, uint32 done,) = vault.plans(1);
        assertEq(done, 1, "a fill 300bp past the feed went through");
        assertEq(h.maxFillLossBps(), 0);

        h.setPremium(60);
        h.executeOwner(0);
        (,,,,,,, done,) = vault.plans(1);
        assertEq(done, 2);
        assertApproxEqAbs(h.maxFillLossBps(), 60, 1);
        assertEq(h.unexpected(), 0);
    }

    /// Round 6b (review finding 8). The handler's short-tail mode builds
    /// what it says: whole periods and then the shortest last period the
    /// vault admits, exactly MIN_INSTALLMENT or a few wei over, and the
    /// handler's own executes carry such a plan through that last period.
    function test_handlerBuildsAShortTail() public {
        // seed % 5 == 3 and (seed / 5) % 4 == 3; (seed / 20) % 8 is the wei.
        _shortTail(18, 0); // a tail of exactly 1 USDC
        _shortTail(118, 5); // and of 1 USDC and 5 wei
        assertEq(h.shortTails(), 2);
        assertEq(h.shortTailsBought(), 2);
        assertEq(h.unexpected(), 0);
        assertEq(h.panics(), 0);

        // The seed the other sanity test uses still takes the ceiling split.
        h.createPlan(3, 50_000e6, 10, 30 days);
        assertEq(h.shortTails(), 2);
        (,, uint256 inst,,,,,,) = vault.plans(3);
        assertEq(inst, 5_000e6);
    }

    function _shortTail(uint256 seed, uint256 smallWei) internal {
        uint256 id = vault.nextPlanId();
        h.createPlan(seed, 50_000e6, 10, 30 days);
        assertTrue(h.isShortTail(id), "the seed did not select the short tail");
        (,, uint256 inst, uint256 rem,,,, uint32 done, bool active) = vault.plans(id);
        uint256 dep = h.deposited(id);
        // `months` 10 is two whole periods in this mode.
        assertEq(dep, 2 * inst + 1e6 + smallWei, "dep = k * inst + MIN_INSTALLMENT + small");
        assertEq(dep % inst, 1e6 + smallWei);
        assertEq(rem, dep - inst);
        assertEq(done, 1);
        // The second whole period, then the short one.
        for (uint256 i; i < 2; ++i) {
            assertTrue(active, "the plan ended early");
            h.executeOwner(1);
            (,,, rem,,,, done, active) = vault.plans(id);
        }
        assertEq(done, 3);
        assertEq(rem, 0);
        assertFalse(active, "the short last period was not bought");
    }
}
