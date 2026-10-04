// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {
    MockERC20,
    MockStock,
    MockYieldAdapter,
    MockPriceOracle,
    MockSwapAdapter
} from "../src/mocks/Mocks.sol";

/// @notice Who may pull the trigger, and when.
/// @dev    Written because wiring the real keeper up to a local deploy showed
///         the allowlist the code COMMENTS described did not exist: the
///         protocol's own bot was treated as a stranger and had to sit out the
///         full 12-hour grace on every period, so every buy would have landed
///         at least half a day late, systematically.
contract KeeperAuthTest is Test {
    MockERC20 usdc;
    MockStock stock;
    MockYieldAdapter yield_;
    MockPriceOracle oracle;
    MockSwapAdapter swapper;
    DcaVault vault;

    address alice = address(0xA11CE);
    address keeper = address(0xC0FFEE);
    address stranger = address(0x57A);

    uint256 constant USDC1 = 1e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("Mock NVDAc", "NVDAc");
        yield_ = new MockYieldAdapter(usdc);
        oracle = new MockPriceOracle();
        swapper = new MockSwapAdapter(usdc, stock, oracle);
        oracle.setPrice(address(stock), 227_56000000);

        vault = new DcaVault(IERC20(address(usdc)), yield_, swapper, oracle, 1_000_000 * USDC1);
        yield_.bindVault(address(vault));
        vault.initRoute(
            1,
            DcaVault.Route({
                token: address(stock),
                pool: address(swapper),
                feed: address(oracle),
                dexKind: 0,
                enabled: true
            })
        );
        vault.finishSetup();
        usdc.mint(alice, 100_000 * USDC1);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _plan() internal returns (uint256 id) {
        vm.prank(alice);
        id = vault.createPlan(1, 10_000 * USDC1, 1_000 * USDC1, 30 days);
    }

    function test_allowlistedKeeperExecutesOnTime() public {
        uint256 id = _plan();
        vault.setKeeper(keeper, true);

        (,,,,, uint64 due,,,) = vault.plans(id);
        vm.warp(due); // due to the second, not a minute later

        vm.prank(keeper);
        vault.executeDCA(id);

        (,,,,,,, uint32 periods,) = vault.plans(id);
        assertEq(periods, 2, "period 1 fires on create, so the keeper's is the 2nd");
    }

    function test_strangerStillWaitsOutGrace() public {
        uint256 id = _plan();
        (,,,,, uint64 due,,,) = vault.plans(id);

        vm.warp(due);
        vm.prank(stranger);
        vm.expectRevert(DcaVault.TooEarlyForPublicCall.selector);
        vault.executeDCA(id);

        // ...and is welcome once the window has passed.
        vm.warp(due + vault.grace() + 1);
        vm.prank(stranger);
        vault.executeDCA(id);
    }

    function test_revokedKeeperIsAStrangerAgain() public {
        uint256 id = _plan();
        vault.setKeeper(keeper, true);
        vault.setKeeper(keeper, false);

        (,,,,, uint64 due,,,) = vault.plans(id);
        vm.warp(due);
        vm.prank(keeper);
        vm.expectRevert(DcaVault.TooEarlyForPublicCall.selector);
        vault.executeDCA(id);
    }

    function test_onlyAdminSetsKeepers() public {
        vm.prank(stranger);
        vm.expectRevert(DcaVault.NotOwner.selector);
        vault.setKeeper(stranger, true);
    }

    function test_keeperCannotExecuteBeforeItIsDue() public {
        uint256 id = _plan();
        vault.setKeeper(keeper, true);
        vm.prank(keeper);
        vm.expectRevert(DcaVault.NotYetDue.selector);
        vault.executeDCA(id);
    }
}
