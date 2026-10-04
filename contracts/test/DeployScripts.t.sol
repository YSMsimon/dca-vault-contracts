// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {DemoUSDC, DemoYieldAdapter} from "../src/mocks/DemoMocks.sol";
import {DeployLocal} from "../script/Deploy.local.s.sol";
import {DeploySepolia} from "../script/Deploy.sepolia.s.sol";

/// @notice The REAL deploy scripts, run end to end in-process (round 3, F4 and
///         F5). The mainnet one needs Base state and lives in ForkDeploy.t.sol.
/// @dev    Both scripts write their addresses to a tracked file under
///         contracts/deployments. Each test puts the file back before it
///         asserts anything, so a failing assertion cannot leave the tree
///         dirty. (A script that reverts never reaches its write.)
contract DeployScriptsTest is Test {
    address constant KEEPER = address(0x4EE9E7);
    address constant OWNER = address(0x0DE3);

    function _vaultFrom(Vm.Log[] memory logs) internal pure returns (DcaVault v) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == DcaVault.SetupFinished.selector) {
                return DcaVault(logs[i].emitter);
            }
        }
        revert("no SetupFinished: the script never called finishSetup");
    }

    /// Every route is listed, the window is closed, deposits are open.
    function _assertLive(DcaVault v, uint32 routes) internal view {
        assertTrue(v.setupFinished(), "setup window left open");
        assertFalse(v.depositsPaused(), "deposits left paused");
        for (uint32 i = 1; i <= routes; ++i) {
            (address t,,,, bool en) = v.routes(i);
            assertTrue(t != address(0) && en, "a launch route is missing");
        }
        vm.assertEq(v.nextPlanId(), 1);
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
}
