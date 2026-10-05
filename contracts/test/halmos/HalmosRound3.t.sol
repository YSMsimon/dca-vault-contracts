// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface Vm {
    function prank(address) external;
    function assume(bool) external;
    function warp(uint256) external;
}

interface SVM {
    function createCalldata(string memory contractName) external returns (bytes memory);
    function createAddress(string memory name) external returns (address);
    function enableSymbolicStorage(address) external;
}

import {DcaVault} from "../../src/DcaVault.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {ChainlinkOracle} from "../../src/adapters/ChainlinkOracle.sol";
import {
    MockERC20,
    MockStock,
    MockYieldAdapter,
    MockPriceOracle,
    MockSwapAdapter
} from "../../src/mocks/Mocks.sol";
import {DemoUSDC, DemoYieldAdapter} from "../../src/mocks/DemoMocks.sol";
import {FakeFeed} from "../utils/HostileVenues.sol";

/// A feed that answers five caller-chosen words.
contract WordsFeed {
    uint8 public constant decimals = 8;
    uint256[5] internal w;

    function set(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) external {
        w = [a, b, c, d, e];
    }

    fallback() external {
        uint256[5] memory r = w;
        assembly {
            return(r, 160)
        }
    }
}

/// @notice Symbolic checks from the round-3 re-test, kept: all eight PASSED
///         there, and still pass on the fixed code. Plus three for the
///         round-3 fixes (F2, F3, F4).
/// @dev    Run: HALMOS_CONTRACT=HalmosRound3 bash scripts/halmos.sh
///         `check_boundsTwoCallsCannotLoosenEarly`
///         explores ~45k paths and takes about half an hour; filter it out with
///         `--function` for a quick pass. setUp now calls `finishSetup`: the
///         setup window is closed by the admin, not by the first plan (F4).
contract HalmosRound3 {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    SVM constant svm = SVM(address(uint160(uint256(keccak256("svm cheat code")))));
    MockERC20 usdc;
    MockStock stock;
    MockStock stock2;
    MockYieldAdapter yield_;
    MockPriceOracle oracle;
    MockSwapAdapter swapper;
    DcaVault vault;
    address alice = address(0xA11CE);
    uint256 constant PX = 227_56000000;
    uint256 constant T0 = 1_800_000_000;
    uint256 constant DELAY = 48 hours;
    uint256 constant WIN = 7 days;

    function setUp() public {
        vm.warp(T0);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("Mock NVDAc", "NVDAc");
        stock2 = new MockStock("Other", "OTH");
        yield_ = new MockYieldAdapter(usdc);
        oracle = new MockPriceOracle();
        swapper = new MockSwapAdapter(usdc, stock, oracle);
        oracle.setPrice(address(stock), PX);
        oracle.setPrice(address(stock2), 1e8);
        vault = new DcaVault(IERC20(address(usdc)), yield_, swapper, oracle, 5_000e6);
        yield_.bindVault(address(vault));
        vault.initRoute(
            1, DcaVault.Route(address(stock), address(0xDEAD), address(oracle), 0, true)
        );
        vault.finishSetup();
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _plan() internal {
        vm.prank(alice);
        vault.createPlan(1, 1_000e6, 100e6, 1 days);
    }

    // ------------------------------------------------ activation windows

    /// Route activation succeeds IFF eta <= now <= eta + 7d.
    function check_routeWindowExact(uint256 t) public {
        _plan();
        vault.queueRoute(
            2, DcaVault.Route(address(stock2), address(0xD00D), address(oracle), 0, true)
        );
        vm.assume(t < 100 * 365 days);
        vm.warp(T0 + t);
        (bool ok,) = address(vault).call(abi.encodeCall(DcaVault.activateRoute, (uint32(2))));
        assert(ok == (t >= DELAY && t <= DELAY + WIN));
        (,,,, bool en) = vault.routes(2);
        assert(en == ok);
    }

    /// Oracle feed activation succeeds IFF eta <= now <= eta + 7d.
    function check_feedWindowExact(uint256 t) public {
        ChainlinkOracle o = new ChainlinkOracle(address(0), false);
        FakeFeed f1 = new FakeFeed();
        FakeFeed f2 = new FakeFeed();
        o.setFeed(address(stock), address(f1));
        o.queueFeed(address(stock), address(f2));
        vm.assume(t < 100 * 365 days);
        vm.warp(T0 + t);
        (bool ok,) = address(o).call(abi.encodeCall(ChainlinkOracle.activateFeed, (address(stock))));
        assert(ok == (t >= DELAY && t <= DELAY + WIN));
        assert((o.feedOf(address(stock)) == address(f2)) == ok);
    }

    /// Bounds: after a plan exists, setBounds(s, d) applies instantly IFF it
    /// does not raise either number; otherwise nothing changes and the pair is
    /// pending. Activation then works IFF inside [eta, eta + 7d].
    function check_boundsQueueAndWindow(uint16 s, uint16 d, uint256 t) public {
        _plan();
        vm.assume(s <= 200 && d <= 2000);
        vault.setBounds(s, d);
        bool tighten = s <= 100 && d <= 500;
        (uint16 ps, uint16 pd, uint64 eta) = vault.pendingBounds();
        if (tighten) {
            assert(vault.maxSlippageBps() == s && vault.maxDeviationBps() == d);
            assert(eta == 0);
        } else {
            assert(vault.maxSlippageBps() == 100 && vault.maxDeviationBps() == 500);
            assert(eta == T0 + DELAY && ps == s && pd == d);
            vm.assume(t < 100 * 365 days);
            vm.warp(T0 + t);
            (bool ok,) = address(vault).call(abi.encodeCall(DcaVault.activateBounds, ()));
            assert(ok == (t >= DELAY && t <= DELAY + WIN));
            if (ok) assert(vault.maxSlippageBps() == s && vault.maxDeviationBps() == d);
        }
    }

    /// Two arbitrary admin calls at arbitrary times < 48h after a queued
    /// loosening cannot raise either bound above its starting value.
    function check_boundsTwoCallsCannotLoosenEarly(uint256 t1, uint256 t2) public {
        _plan();
        vault.setBounds(200, 2000);
        vm.assume(t1 <= t2 && t2 < DELAY);
        vm.warp(T0 + t1);
        address(vault).call(svm.createCalldata("DcaVault"));
        vm.warp(T0 + t2);
        address(vault).call(svm.createCalldata("DcaVault"));
        assert(vault.maxSlippageBps() <= 100);
        assert(vault.maxDeviationBps() <= 500);
    }

    /// disableRoute drops a pending re-enable: after a disable at ANY time,
    /// one arbitrary admin call and an activateRoute within 48h of the disable
    /// leave the route disabled.
    function check_disableRouteClearsPending(uint256 t1, uint256 t2) public {
        _plan();
        vault.queueRoute(
            1, DcaVault.Route(address(stock), address(0xDEAD), address(oracle), 0, true)
        );
        vm.assume(t1 < 30 days && t2 < DELAY);
        vm.warp(T0 + t1);
        vault.disableRoute(1);
        (,,,,, uint64 eta) = vault.pendingRoutes(1);
        assert(eta == 0);
        address(vault).call(svm.createCalldata("DcaVault"));
        vm.warp(T0 + t1 + t2);
        address(vault).call(abi.encodeCall(DcaVault.activateRoute, (uint32(1))));
        (,,,, bool en) = vault.routes(1);
        assert(!en);
    }

    // ------------------------------------------------ DemoUSDC budget

    /// Inductive step over ARBITRARY prior faucet state: from any state with
    /// drippedToday <= DAILY_BUDGET and budgetDay <= today, one drip keeps it
    /// <= DAILY_BUDGET, stamps today, mints exactly DRIP, and — when the prior
    /// window was today — adds exactly DRIP to the counter. Hence the sum of
    /// drips inside any one UTC day never exceeds DAILY_BUDGET.
    function check_dripBudgetInductive(uint256 t) public {
        DemoUSDC d = new DemoUSDC(address(this));
        svm.enableSymbolicStorage(address(d));
        vm.assume(t >= T0 && t < T0 + 100 * 365 days);
        vm.warp(t);
        uint256 day = t / 1 days;
        uint256 prevDay = d.budgetDay();
        uint256 prevUsed = d.drippedToday();
        uint256 prevSupply = d.totalSupply();
        vm.assume(prevDay <= day && prevUsed <= d.DAILY_BUDGET());
        vm.assume(prevSupply < type(uint128).max);
        address who = svm.createAddress("who");
        vm.assume(d.balanceOf(who) < type(uint128).max);
        vm.prank(who);
        (bool ok,) = address(d).call(abi.encodeCall(DemoUSDC.drip, ()));
        if (ok) {
            assert(d.budgetDay() == day);
            assert(d.drippedToday() <= d.DAILY_BUDGET());
            assert(d.totalSupply() == prevSupply + d.DRIP());
            if (prevDay == day) assert(d.drippedToday() == prevUsed + d.DRIP());
            else assert(d.drippedToday() == d.DRIP());
        } else {
            assert(d.totalSupply() == prevSupply);
        }
    }

    // ------------------------------------------------ VaultBound

    /// Test mock bound to the vault: any caller that is not the vault, with
    /// any calldata, cannot reduce the adapter's USDC or change its shares.
    function check_mockAdapterOnlyVault() public {
        _plan();
        uint256 bal = usdc.balanceOf(address(yield_));
        uint256 sh = yield_.totalShares();
        address caller = svm.createAddress("caller");
        vm.assume(caller != address(vault));
        vm.prank(caller);
        address(yield_).call(svm.createCalldata("MockYieldAdapter"));
        assert(usdc.balanceOf(address(yield_)) >= bal);
        assert(yield_.totalShares() == sh);
        assert(yield_.vault() == address(vault) || caller == address(this));
    }

    /// Demo adapter: nobody but the vault — not the owner, not the deployer —
    /// can move its USDC, change its shares or re-bind it.
    function check_demoAdapterOnlyVault() public {
        DemoUSDC du = new DemoUSDC(address(this));
        address v = address(0x7777);
        DemoYieldAdapter dy = new DemoYieldAdapter(du, address(this), v);
        du.setMinter(address(dy));
        du.mint(address(dy), 10_000e6);
        uint256 bal = du.balanceOf(address(dy));
        uint256 sh = dy.totalShares();
        address caller = svm.createAddress("caller");
        vm.assume(caller != v);
        vm.prank(caller);
        address(dy).call(svm.createCalldata("DemoYieldAdapter"));
        assert(du.balanceOf(address(dy)) >= bal);
        assert(dy.totalShares() == sh);
        assert(dy.vault() == v);
    }

    // ------------------------------------------------ round-3 fixes

    /// F2: after a loosening is queued, ANY instant (non-loosening) setBounds
    /// drops it, and then no activation at any time applies it.
    function check_instantChangeDropsQueuedLoosening(uint16 s, uint16 d, uint256 t) public {
        _plan();
        vault.setBounds(200, 2000); // queued
        vm.assume(s <= 100 && d <= 500);
        vault.setBounds(s, d); // instant
        (,, uint64 eta) = vault.pendingBounds();
        assert(eta == 0);
        vm.assume(t < 100 * 365 days);
        vm.warp(T0 + t);
        (bool ok,) = address(vault).call(abi.encodeCall(DcaVault.activateBounds, ()));
        assert(!ok);
        assert(vault.maxSlippageBps() == s && vault.maxDeviationBps() == d);
    }

    /// F4: while the setup window is open, no admin call other than
    /// finishSetup — with any arguments — lets a plan into existence.
    function check_noPlanBeforeFinishSetup() public {
        MockYieldAdapter y2 = new MockYieldAdapter(usdc);
        DcaVault v = new DcaVault(IERC20(address(usdc)), y2, swapper, oracle, 5_000e6);
        y2.bindVault(address(v));
        v.initRoute(1, DcaVault.Route(address(stock), address(0xDEAD), address(oracle), 0, true));
        bytes memory c = svm.createCalldata("DcaVault");
        vm.assume(bytes4(c) != DcaVault.finishSetup.selector);
        address(v).call(c); // as admin (this contract)
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        (bool ok,) =
            address(v).call(abi.encodeCall(DcaVault.createPlan, (1, 1_000e6, 100e6, 1 days)));
        assert(!ok);
        assert(v.nextPlanId() == 1);
        assert(!v.setupFinished());
    }

    /// F3: for ANY five words a feed returns, isFresh never reverts, and
    /// isFresh true means latestPrice answers the same price, within range.
    function check_isFreshImpliesLatestPrice(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e)
        public
    {
        ChainlinkOracle o = new ChainlinkOracle(address(0), false);
        WordsFeed f = new WordsFeed();
        o.setFeed(address(stock), address(f));
        f.set(a, b, c, d, e);
        (bool ok, bytes memory ret) =
            address(o).call(abi.encodeCall(ChainlinkOracle.isFresh, (address(stock))));
        assert(ok);
        if (abi.decode(ret, (bool))) {
            (bool ok2, bytes memory r2) =
                address(o).call(abi.encodeCall(ChainlinkOracle.latestPrice, (address(stock))));
            assert(ok2);
            (uint256 px, uint256 ts) = abi.decode(r2, (uint256, uint256));
            assert(px == b && ts == d);
            assert(px > 0 && px <= o.MAX_PRICE());
            assert(a <= type(uint80).max && e <= type(uint80).max);
        }
    }
}
