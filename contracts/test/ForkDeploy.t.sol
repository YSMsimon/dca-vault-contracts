// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle, IAggregatorV3} from "../src/adapters/ChainlinkOracle.sol";
import {AerodromeSwapAdapter} from "../src/adapters/AerodromeSwapAdapter.sol";
import {MorphoAdapter} from "../src/adapters/MorphoAdapter.sol";
import {MockERC20, MockYieldAdapter, MockSwapAdapter} from "../src/mocks/Mocks.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// @notice Round 3, F1: the REAL mainnet deploy script, run in-process against
///         a Base mainnet fork. Nothing is broadcast: a test cannot broadcast,
///         and the fork is local.
/// @dev    Before: `forge script` executes
///         locally first, and there the B20 token is a one-byte `0xef` stub
///         backed by a precompile the EVM cannot run. `_checkRoute`'s
///         `decimals()` probe failed, read 0, burned 393M gas and reverted
///         `BadTokenDecimals(0)`, so Deploy.s.sol could never reach the
///         broadcast. No test had routed a real B20 until this one.
///
///         Forks at LATEST, like Fork.t.sol, because the point is that the
///         script runs against the chain as it is today. BASE_RPC_URL=off
///         skips it.
contract ForkDeployTest is Test {
    address constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address constant NVDAC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;
    address constant NVDAC_FEED = 0x04689a41629776563E6822F76f2e57D148d28513;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address constant MULTISIG = address(0x5afe5afE5afE5afE5afE5aFe5aFe5Afe5Afe5AfE);

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.skip(keccak256(bytes(rpc)) == keccak256("off") || bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
    }

    function test_Fork_DeployScriptListsTheFourLaunchRoutes() public {
        // The B20 really is the stub this test is about.
        assertEq(NVDAC.code.length, 1, "NVDAc is no longer a 1-byte stub: re-read this test");
        vm.setEnv("ADMIN_MULTISIG", vm.toString(MULTISIG));

        Deploy d = new Deploy();
        vm.recordLogs();
        d.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        DcaVault v;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == DcaVault.SetupFinished.selector) {
                v = DcaVault(logs[i].emitter);
            }
        }
        assertTrue(address(v) != address(0), "the script never reached finishSetup");

        // Route 1 (NVDAc) is listed, enabled, and priced off the right feed.
        (address t, address p, address f, uint8 kind, bool en) = v.routes(1);
        assertEq(t, NVDAC);
        assertEq(p, NVDAC_POOL);
        assertEq(f, NVDAC_FEED);
        assertEq(kind, 0);
        assertTrue(en, "route 1 is not enabled");
        ChainlinkOracle o = ChainlinkOracle(address(v.oracle()));
        assertEq(o.feedOf(NVDAC), NVDAC_FEED);
        // Round 6: the oracle is deployed with Base's sequencer uptime feed.
        // It is immutable, so a deploy without it could not be put right.
        assertEq(
            o.sequencerUptimeFeed(), SEQUENCER_UPTIME_FEED, "the oracle has no sequencer check"
        );
        // Round 6b: and CLOSED ON WEEKENDS. Immutable too: an oracle
        // deployed without the rule buys against Friday's print on Saturday.
        assertTrue(o.closedOnWeekends(), "the mainnet oracle is built without the weekend rule");
        _assertTheScriptDeployedTheSource(v, o);
        (uint256 px,) = o.latestPrice(NVDAC);
        assertGt(px, 50e8);

        // The other three are listed too, each on a feed the oracle has.
        for (uint32 id = 2; id <= 4; ++id) {
            (address tk, address pl, address fd,, bool on) = v.routes(id);
            assertTrue(on, "a launch route is not enabled");
            assertEq(tk.code.length, 1, "a launch token is not a B20 stub");
            assertGt(pl.code.length, 0, "a launch pool has no code");
            assertEq(o.feedOf(tk), fd, "the oracle and the route disagree on a feed");
            (uint256 q,) = o.latestPrice(tk);
            assertGt(q, 50e8);
        }
        (address none,,,,) = v.routes(5);
        assertEq(none, address(0), "a fifth route appeared");

        // The launch posture the script documents: the setup window is
        // closed, and deposits are NOT open. The deploy does not take money.
        assertEq(address(v.usdc()), USDC);
        assertEq(v.tvlCap(), 5_000e6);
        assertEq(v.feeBps(), 0);
        assertTrue(v.setupFinished(), "setup window left open");
        assertTrue(v.depositsPaused(), "the deploy opened deposits by itself");
        assertEq(v.feeRecipient(), MULTISIG);
        assertEq(v.pendingAdmin(), MULTISIG);
        assertEq(o.pendingAdmin(), MULTISIG);
        assertTrue(v.admin() != MULTISIG, "admin moved in one step");

        // Nothing instant is left, and the multisig can take over.
        vm.startPrank(MULTISIG);
        v.acceptAdmin();
        o.acceptAdmin();
        vm.expectRevert(DcaVault.SetupClosed.selector);
        v.initRoute(5, DcaVault.Route(NVDAC, NVDAC_POOL, NVDAC_FEED, 0, true));
        // Opening deposits is the multisig's call, and only the multisig's.
        v.setDepositsPaused(false);
        assertFalse(v.depositsPaused(), "the multisig could not open deposits");
        vm.stopPrank();

        _assertFreshnessOnTheDeployedOracle(v, o);
    }

    /// @dev Round 6b. Each of the four contracts the script deployed has
    ///      exactly the code the same contract has when it is created here
    ///      with the same constructor arguments. A script carries the
    ///      creation code of what it deploys inside its own artifact, and
    ///      forge 1.8.3 with `dynamic_test_linking` (on by default) does not
    ///      rebuild a script when only a function BODY in contracts/src
    ///      changed: tests see the new code and the script goes on
    ///      deploying the old. DeployScripts.t.sol says how it was measured.
    function _assertTheScriptDeployedTheSource(DcaVault v, ChainlinkOracle o) internal {
        _sameCode(
            address(o), address(new ChainlinkOracle(SEQUENCER_UPTIME_FEED, true)), "ChainlinkOracle"
        );
        _sameCode(
            address(v.swapper()),
            address(new AerodromeSwapAdapter(v.usdc(), address(v))),
            "AerodromeSwapAdapter"
        );
        MorphoAdapter y = MorphoAdapter(address(v.adapter()));
        _sameCode(
            address(y),
            address(new MorphoAdapter(v.usdc(), y.vault4626(), address(v))),
            "MorphoAdapter"
        );
        _sameCode(
            address(v),
            address(new DcaVault(v.usdc(), v.adapter(), v.swapper(), v.oracle(), v.tvlCap())),
            "DcaVault"
        );
    }

    function _sameCode(address deployed, address built, string memory what) internal view {
        assertEq(
            keccak256(deployed.code),
            keccak256(built.code),
            string.concat(
                "STALE BUILD: the script deployed a ",
                what,
                " that is not what contracts/src compiles to. Run `forge clean` (or pass --force)",
                " and test again, and NEVER run `forge script` to deploy without it"
            )
        );
    }

    /// The Saturday 00:00:00 UTC at or before `ts`, by whole weeks from one
    /// that was checked against a calendar (2026-10-03).
    function _saturdayAtOrBefore(uint256 ts) internal pure returns (uint256 sat) {
        sat = 1790985600;
        while (sat > ts) sat -= 7 days;
        while (ts - sat >= 7 days) sat += 7 days;
    }

    /// @dev Round 6b. This suite forks at the latest block, and the oracle
    ///      the script deploys refuses weekends, so anything said here about
    ///      freshness has to be true on a Saturday and on a Wednesday alike.
    ///      Two parts, and neither branches on the day it is run:
    ///
    ///      (a) At the fork block `isFresh` is asserted EQUAL to its three
    ///          rules, each read from its own source: the calendar, the real
    ///          feed's age, the real sequencer feed. On a weekend that is
    ///          `false` whatever the feed says; on a weekday it follows the
    ///          feed.
    ///      (b) The weekend itself is then asserted on every run, by moving
    ///          the fork's clock to the next Saturday and Monday with a
    ///          one-minute-old print served at each real feed's address, so
    ///          that the calendar is all that can decide.
    function _assertFreshnessOnTheDeployedOracle(DcaVault v, ChainlinkOracle o) internal {
        bytes memory sel = abi.encodeWithSignature("latestRoundData()");
        address[4] memory tokens;
        address[4] memory feeds;

        // (a) the fork block, as it is.
        uint256 sat = _saturdayAtOrBefore(block.timestamp);
        bool weekend = block.timestamp - sat < 49 hours;
        emit log_named_string("fork block falls in the weekend closure", weekend ? "yes" : "no");
        assertEq(
            o.weekendClosed(), weekend, "weekendClosed() is not the calendar at the fork block"
        );
        for (uint32 id = 1; id <= 4; ++id) {
            (tokens[id - 1],, feeds[id - 1],,) = v.routes(id);
            (,,, uint256 updatedAt,) = IAggregatorV3(feeds[id - 1]).latestRoundData();
            bool young = block.timestamp - updatedAt <= o.HEARTBEAT();
            assertEq(
                o.isFresh(tokens[id - 1]),
                !weekend && young && o.sequencerUp(),
                "isFresh is not the weekend, the heartbeat and the sequencer"
            );
        }

        // (b) the weekend after the fork block. Friday 23:59:59 open,
        // Saturday 00:00:00 closed, Monday 00:59:59 closed, Monday 01:00:00
        // open.
        uint256 next = sat + 7 days;
        uint256[4] memory when = [next - 1, next, next + 49 hours - 1, next + 49 hours];
        bool[4] memory closed = [false, true, true, false];
        for (uint256 w; w < 4; ++w) {
            vm.warp(when[w]);
            vm.mockCall(
                SEQUENCER_UPTIME_FEED,
                sel,
                abi.encode(uint80(1), int256(0), uint256(1), uint256(1), uint80(1))
            );
            for (uint256 i; i < 4; ++i) {
                vm.mockCall(
                    feeds[i],
                    sel,
                    abi.encode(uint80(1), int256(200e8), when[w] - 60, when[w] - 60, uint80(1))
                );
                assertEq(o.weekendClosed(), closed[w], "weekendClosed");
                assertEq(
                    o.isFresh(tokens[i]), !closed[w], "a one-minute-old print, by the calendar"
                );
            }
        }
        vm.clearMockedCalls();
    }

    /// The probe on a real B20 is admitted and costs a bounded amount of gas
    /// (it used to burn all 393M it was forwarded).
    function test_Fork_ARealB20RouteIsAdmittedCheaply() public {
        ChainlinkOracle o = new ChainlinkOracle(address(0), false);
        o.setFeed(NVDAC, NVDAC_FEED);
        MockERC20 u = new MockERC20("u", "u", 6);
        MockYieldAdapter y = new MockYieldAdapter(u);
        DcaVault v = new DcaVault(IERC20(address(u)), y, MockSwapAdapter(address(0x1)), o, 5_000e6);
        uint256 g = gasleft();
        v.initRoute(1, DcaVault.Route(NVDAC, NVDAC_POOL, NVDAC_FEED, 0, true));
        assertLt(g - gasleft(), 250_000, "the decimals probe is not bounded");
        (address t,,,, bool en) = v.routes(1);
        assertEq(t, NVDAC);
        assertTrue(en);
    }
}
