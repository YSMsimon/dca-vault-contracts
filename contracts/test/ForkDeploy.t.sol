// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle} from "../src/adapters/ChainlinkOracle.sol";
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
    }

    /// The probe on a real B20 is admitted and costs a bounded amount of gas
    /// (it used to burn all 393M it was forwarded).
    function test_Fork_ARealB20RouteIsAdmittedCheaply() public {
        ChainlinkOracle o = new ChainlinkOracle();
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
