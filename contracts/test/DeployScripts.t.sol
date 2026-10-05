// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ChainlinkOracle} from "../src/adapters/ChainlinkOracle.sol";
import {AerodromeSwapAdapter} from "../src/adapters/AerodromeSwapAdapter.sol";
import {MorphoAdapter} from "../src/adapters/MorphoAdapter.sol";
import {MockERC20, MockStock} from "../src/mocks/Mocks.sol";
import {DemoUSDC, DemoYieldAdapter} from "../src/mocks/DemoMocks.sol";
import {DeployLocal} from "../script/Deploy.local.s.sol";
import {DeploySepolia} from "../script/Deploy.sepolia.s.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// A Chainlink price feed that needs no storage, so its code can be etched at
/// an address: 8 decimals, and a print that is always one minute old.
contract EtchedFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 ts = block.timestamp - 60;
        return (1, 200e8, ts, ts, 1);
    }
}

/// The sequencer uptime feed, likewise: up, and since long ago.
contract EtchedUptime {
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 0, 1, 1, 1);
    }
}

/// @notice The REAL deploy scripts, run end to end in-process (round 3, F4 and
///         F5). The mainnet one needs Base state: ForkDeploy.t.sol runs it
///         against a fork, and here it runs offline against stand-ins etched
///         at the addresses it hard-codes (round 6b), for what no fork is
///         needed to see: how it builds the oracle.
/// @dev    The local and Sepolia scripts write their addresses to a tracked
///         file under contracts/deployments. Each test puts the file back
///         before it asserts anything, so a failing assertion cannot leave
///         the tree dirty. (A script that reverts never reaches its write.)
contract DeployScriptsTest is Test {
    address constant KEEPER = address(0x4EE9E7);
    address constant OWNER = address(0x0DE3);
    // The same stand-in Safe ForkDeploy.t.sol uses: both set ADMIN_MULTISIG
    // in the one process, so they must set it to the same thing.
    address constant MULTISIG = address(0x5afe5afE5afE5afE5afE5aFe5aFe5Afe5Afe5AfE);
    // Saturday 2026-10-03 00:00:00 UTC, and the Wednesday after at 15:00.
    uint256 constant SAT = 1790985600;
    uint256 constant WED = 1791385200;

    function _vaultFrom(Vm.Log[] memory logs) internal pure returns (DcaVault v) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == DcaVault.SetupFinished.selector) {
                return DcaVault(logs[i].emitter);
            }
        }
        revert("no SetupFinished: the script never called finishSetup");
    }

    /// Every route is listed, the window is closed, deposits are open.
    function _assertLive(DcaVault v, uint32 routes) internal {
        assertTrue(v.setupFinished(), "setup window left open");
        assertFalse(v.depositsPaused(), "deposits left paused");
        for (uint32 i = 1; i <= routes; ++i) {
            (address t,,,, bool en) = v.routes(i);
            assertTrue(t != address(0) && en, "a launch route is missing");
        }
        vm.assertEq(v.nextPlanId(), 1);
        _sameCode(
            address(v),
            address(new DcaVault(v.usdc(), v.adapter(), v.swapper(), v.oracle(), v.tvlCap())),
            "DcaVault"
        );
    }

    /// THE SCRIPT DEPLOYED WHAT THE SOURCE SAYS (round 6b). `deployed` is a
    /// contract a deploy script created, and `built` is the same contract
    /// with the same constructor arguments created HERE: their code must be
    /// identical, immutables and all.
    ///
    /// It is not a formality. A script carries the creation code of what it
    /// deploys inside its own artifact, and forge 1.8.3 with
    /// `dynamic_test_linking` (on by default) does NOT rebuild a script when
    /// only a function BODY in contracts/src changed. Tests are linked at run
    /// time and see the new code. The script goes on deploying the old one:
    /// measured, with `forge script` as well as through a test. Without this
    /// check every test in this file passed on a script that deployed an
    /// oracle with the weekend rule taken out of `isFresh`.
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

    /// Round 6b: the weekend rule is the MAINNET oracle's. The local and
    /// Sepolia scripts build stand-in oracles with no calendar in them, and
    /// must stay that way: a demo that would not buy from Saturday to Monday
    /// would look broken two days a week. At Saturday noon UTC every route's
    /// price is fresh, and a deposit buys at once.
    function _assertBuysOnASaturday(DcaVault v, uint32 routes, bool demoFaucet) internal {
        uint256 was = block.timestamp;
        vm.warp(SAT + 12 hours);
        IPriceOracle o = v.oracle();
        // Not a ChainlinkOracle: there is no weekend flag to ask it for.
        (bool hasFlag,) = address(o).staticcall(abi.encodeWithSignature("closedOnWeekends()"));
        assertFalse(hasFlag, "this script now deploys an oracle with a weekend flag");
        for (uint32 i = 1; i <= routes; ++i) {
            (address t,,,,) = v.routes(i);
            assertTrue(o.isFresh(t), "a stand-in price is not fresh on a Saturday");
        }

        address user = address(0x5A7);
        (address token,,,,) = v.routes(1);
        MockERC20 usdc = MockERC20(address(v.usdc()));
        vm.startPrank(user);
        if (demoFaucet) DemoUSDC(address(usdc)).drip();
        else usdc.mint(user, 1_000e6);
        usdc.approve(address(v), 100e6);
        uint256 id = v.createPlan(1, 100e6, 10e6, 1 days);
        vm.stopPrank();
        assertGt(MockStock(token).balanceOf(user), 0, "no first buy on a Saturday");
        (,,,,,,, uint32 done,) = v.plans(id);
        assertEq(done, 1);
        vm.warp(was);
    }

    /// F4: the local deploy (Deploy.local.s.sol, on anvil) still ends with
    /// the vault open, and nothing instant is left.
    function test_DeployLocal_FinishesSetupLast() public {
        string memory path = "./contracts/deployments/local.json";
        string memory before = vm.readFile(path);
        DeployLocal s = new DeployLocal();
        vm.recordLogs();
        s.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.writeFile(path, before);

        DcaVault v = _vaultFrom(logs);
        _assertLive(v, 4);
        // finishSetup is the script's LAST vault call.
        uint256 lastVaultLog;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(v)) lastVaultLog = i;
        }
        assertEq(logs[lastVaultLog].topics[0], DcaVault.DepositsPausedSet.selector);
        assertEq(logs[lastVaultLog - 1].topics[0], DcaVault.SetupFinished.selector);
        vm.prank(v.admin());
        vm.expectRevert(DcaVault.SetupClosed.selector);
        v.initRoute(9, DcaVault.Route(address(1), address(1), address(1), 0, true));
        _assertBuysOnASaturday(v, 4, false);
    }

    /// F5: with DEMO_OWNER set, the vault's admin and fee recipient go to the
    /// owner as well (admin in two steps). Before, both stayed with the
    /// deployer while every demo contract around them was handed over.
    function test_DeploySepolia_HandsTheVaultToDemoOwner() public {
        string memory path = "./contracts/deployments/baseSepolia.json";
        string memory before = vm.readFile(path);
        vm.chainId(84532);
        vm.setEnv("DEMO_KEEPER", vm.toString(KEEPER));

        // 1) DEMO_OWNER set: everything goes to the owner.
        vm.setEnv("DEMO_OWNER", vm.toString(OWNER));
        DeploySepolia s = new DeploySepolia();
        vm.recordLogs();
        s.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.writeFile(path, before);

        DcaVault v = _vaultFrom(logs);
        _assertLive(v, 4);
        address deployer = v.admin();
        assertTrue(deployer != OWNER, "admin moved in one step");
        assertEq(v.pendingAdmin(), OWNER, "vault admin not handed to DEMO_OWNER");
        assertEq(v.feeRecipient(), OWNER, "fee recipient left with the deployer");
        assertTrue(v.keepers(KEEPER));
        assertEq(DemoUSDC(address(v.usdc())).owner(), OWNER);
        assertEq(DemoYieldAdapter(address(v.adapter())).owner(), OWNER);
        assertEq(DemoYieldAdapter(address(v.adapter())).vault(), address(v));
        vm.prank(OWNER);
        v.acceptAdmin();
        assertEq(v.admin(), OWNER);
        _assertBuysOnASaturday(v, 4, true);

        // 2) DEMO_OWNER = the deployer (what an unset one defaults to): the
        //    deployer keeps everything, and nothing is left pending.
        vm.setEnv("DEMO_OWNER", vm.toString(deployer));
        s = new DeploySepolia();
        vm.recordLogs();
        s.run();
        logs = vm.getRecordedLogs();
        vm.writeFile(path, before);
        DcaVault v2 = _vaultFrom(logs);
        _assertLive(v2, 4);
        assertEq(v2.admin(), deployer);
        assertEq(v2.pendingAdmin(), address(0));
        assertEq(v2.feeRecipient(), deployer);
    }

    /// Round 6b: the MAINNET script (Deploy.s.sol), offline. All it needs of
    /// Base is at addresses it hard-codes: each feed must have code and
    /// answer 8 decimals, and each token must be the one-byte B20 stub. Both
    /// are etched here, at the addresses packages/config/addresses.base.json
    /// lists, and the real script runs in-process.
    ///
    /// What it pins: the oracle is built CLOSED ON WEEKENDS and with the
    /// sequencer uptime feed. Both are immutable, so a deploy that got
    /// either wrong could not be put right, and ForkDeploy.t.sol, which
    /// asserts the same against real Base state, is skipped offline.
    function test_DeployMainnet_BuildsTheOracleClosedOnWeekends() public {
        string memory cfg = vm.readFile("./packages/config/addresses.base.json");
        address uptime = vm.parseJsonAddress(cfg, ".core.SequencerUptimeFeed.address");
        vm.etch(uptime, address(new EtchedUptime()).code);
        bytes memory feedCode = address(new EtchedFeed()).code;
        address[4] memory tokens;
        for (uint256 i; i < 4; ++i) {
            string memory route = string.concat(".routes[", vm.toString(i), "]");
            tokens[i] = vm.parseJsonAddress(cfg, string.concat(route, ".token"));
            vm.etch(tokens[i], hex"ef");
            vm.etch(vm.parseJsonAddress(cfg, string.concat(route, ".feed")), feedCode);
        }
        vm.setEnv("ADMIN_MULTISIG", vm.toString(MULTISIG));
        vm.warp(WED);

        Deploy d = new Deploy();
        vm.recordLogs();
        d.run();
        DcaVault v = _vaultFrom(vm.getRecordedLogs());

        // The posture the script documents, unchanged: four routes, the
        // window closed, deposits NOT open, the Safe pending on both.
        assertTrue(v.setupFinished(), "setup window left open");
        assertTrue(v.depositsPaused(), "the deploy opened deposits by itself");
        assertEq(v.pendingAdmin(), MULTISIG);
        assertEq(v.feeRecipient(), MULTISIG);
        ChainlinkOracle o = ChainlinkOracle(address(v.oracle()));
        assertEq(o.pendingAdmin(), MULTISIG);

        assertTrue(o.closedOnWeekends(), "the mainnet oracle is built WITHOUT the weekend rule");
        assertEq(o.sequencerUptimeFeed(), uptime, "the mainnet oracle has no sequencer check");
        assertTrue(o.sequencerUp());

        // All four contracts are what the source compiles to (see _sameCode).
        _sameCode(address(o), address(new ChainlinkOracle(uptime, true)), "ChainlinkOracle");
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

        // And the flag does what it says through the oracle the script
        // built: a one-minute-old print is fresh on a Wednesday, and not
        // from Saturday 00:00:00 to Monday 00:59:59 UTC.
        uint256[5] memory when = [WED, SAT - 1, SAT, SAT + 49 hours - 1, SAT + 49 hours];
        bool[5] memory closed = [false, false, true, true, false];
        for (uint256 w; w < 5; ++w) {
            vm.warp(when[w]);
            assertEq(o.weekendClosed(), closed[w], "weekendClosed");
            for (uint32 i; i < 4; ++i) {
                (address t,,,, bool en) = v.routes(i + 1);
                assertEq(t, tokens[i], "a route is not the token the config lists");
                assertTrue(en, "a launch route is not enabled");
                assertEq(o.isFresh(t), !closed[w], "isFresh");
            }
        }
    }
}
