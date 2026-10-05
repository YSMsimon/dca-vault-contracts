// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface Vm {
    function prank(address) external;
    function assume(bool) external;
    function warp(uint256) external;
}

interface SVM {
    function createCalldata(string memory contractName) external returns (bytes memory);
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
import {FakeFeed} from "../utils/HostileVenues.sol";

/// @notice Symbolic checks from the round-2 re-test (an internal re-test, not
///         an outside audit, whatever the file name suggests), kept: the ones
///         that PASSED there. The ledger checks that timed out at 60s per
///         query are covered by HalmosLedger and by the fuzz and invariant
///         suites instead. Plus two new ones for D2.
/// @dev    Run: HALMOS_CONTRACT=HalmosReaudit bash scripts/halmos.sh
///         Same build dirs and flags as HalmosLedger — see scripts/halmos.sh
///         for why.
contract HalmosReaudit {
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
    address bob = address(0xB0B);
    uint256 constant CAP = 5_000e6;
    uint256 constant PX = 227_56000000;
    uint256 constant T0 = 1_800_000_000;

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
        vault = new DcaVault(IERC20(address(usdc)), yield_, swapper, oracle, CAP);
        yield_.bindVault(address(vault));
        vault.initRoute(1, DcaVault.Route(address(stock), address(0xDEAD), address(oracle), 0, true));
        vault.finishSetup();
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _create(address who, uint256 d, uint256 i, uint64 iv)
        internal
        returns (bool ok, uint256 id)
    {
        vm.prank(who);
        bytes memory ret;
        (ok, ret) =
            address(vault).call(abi.encodeCall(DcaVault.createPlan, (uint32(1), d, i, iv)));
        if (ok) id = abi.decode(ret, (uint256));
    }

    function _shares(uint256 id) internal view returns (uint256 s) {
        (,,,, s,,,,) = vault.plans(id);
    }

    function _rem(uint256 id) internal view returns (uint256 r) {
        (,,, r,,,,,) = vault.plans(id);
    }

    function _active(uint256 id) internal view returns (bool a) {
        (,,,,,,,, a) = vault.plans(id);
    }

    /// R5b: cancel + requeue restarts the clock; activation strictly before
    ///      requeue + 48h always fails.
    function check_requeueRestartsClock(uint256 t1, uint256 t2) public {
        _create(alice, 1_000e6, 100e6, 1 days);
        DcaVault.Route memory r2 =
            DcaVault.Route(address(stock2), address(0xD00D), address(oracle), 0, true);
        vault.queueRoute(2, r2);
        vm.assume(t1 < 365 days && t2 < 48 hours);
        vm.warp(T0 + t1);
        vault.cancelRoute(2);
        vault.queueRoute(2, r2);
        vm.warp(T0 + t1 + t2);
        (bool ok,) = address(vault).call(abi.encodeCall(DcaVault.activateRoute, (uint32(2))));
        assert(!ok);
    }

    /// R6: oracle — a listed token's feed cannot change before ADMIN_DELAY by
    ///     any two admin calls.
    function check_oracleFeedCannotChangeEarly(uint256 t) public {
        ChainlinkOracle o = new ChainlinkOracle(address(0), false);
        FakeFeed f1 = new FakeFeed();
        FakeFeed f2 = new FakeFeed();
        o.setFeed(address(stock), address(f1));
        o.queueFeed(address(stock), address(f2));
        vm.assume(t < 48 hours);
        vm.warp(T0 + t);
        bytes memory c1 = svm.createCalldata("ChainlinkOracle");
        address(o).call(c1);
        bytes memory c2 = svm.createCalldata("ChainlinkOracle");
        address(o).call(c2);
        assert(o.feedOf(address(stock)) == address(f1));
    }

    /// R5a: one arbitrary admin call (any function, any args) < 48h after
    ///      the queue cannot make route 2 live or repoint route 1.
    function check_oneAdminCallCannotBypassDelay(uint256 t) public {
        (bool okA,) = _create(alice, 1_000e6, 100e6, 1 days);
        assert(okA);
        vault.queueRoute(2, DcaVault.Route(address(stock2), address(0xD00D), address(oracle), 0, true));
        vm.assume(t < 48 hours);
        vm.warp(T0 + t);
        bytes memory c1 = svm.createCalldata("DcaVault");
        address(vault).call(c1);
        (address tok2,,,, bool en2) = vault.routes(2);
        assert(!en2 || tok2 != address(stock2));
        (address tok1, address pool1,,,) = vault.routes(1);
        assert(tok1 == address(stock) && pool1 == address(0xDEAD));
    }

    /// D2: a queued route that was not activated within ACTIVATION_WINDOW of
    ///     its eta can never be activated, at ANY later time.
    function check_expiredRouteQueueNeverActivates(uint256 t) public {
        (bool okA,) = _create(alice, 1_000e6, 100e6, 1 days);
        assert(okA);
        vault.queueRoute(2, DcaVault.Route(address(stock2), address(0xD00D), address(oracle), 0, true));
        vm.assume(t > 48 hours + 7 days && t < 100 * 365 days);
        vm.warp(T0 + t);
        (bool ok,) = address(vault).call(abi.encodeCall(DcaVault.activateRoute, (uint32(2))));
        assert(!ok);
        (,,,, bool en2) = vault.routes(2);
        assert(!en2);
    }

    /// D2: once a plan exists, a queued LOOSENING of the fill bounds cannot
    ///     take effect before ADMIN_DELAY through any one admin call.
    function check_boundsCannotLoosenEarly(uint256 t) public {
        (bool okA,) = _create(alice, 1_000e6, 100e6, 1 days);
        assert(okA);
        uint16 s0 = vault.maxSlippageBps();
        uint16 d0 = vault.maxDeviationBps();
        vault.setBounds(200, 2000);
        vm.assume(t < 48 hours);
        vm.warp(T0 + t);
        bytes memory c1 = svm.createCalldata("DcaVault");
        address(vault).call(c1); // as admin (this contract)
        assert(vault.maxSlippageBps() <= s0);
        assert(vault.maxDeviationBps() <= d0);
    }
}
