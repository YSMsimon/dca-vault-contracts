// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {
    DemoOwned,
    DemoUSDC,
    DemoStock,
    DemoYieldAdapter,
    DemoPriceOracle,
    DemoSwapAdapter
} from "../src/mocks/DemoMocks.sol";

/// @notice The demo deployment's threat model is one passer-by, not an attacker.
/// @dev    Locally the mocks are ungated on purpose — a test needs the worst
///         state cheaply. On Base Sepolia the same openness means a stranger
///         with 30 seconds and free gas can `setPaused(true)` and the next
///         visitor arrives to a dead page. These tests say the switches are
///         shut and the front door is not.
contract DemoMocksTest is Test {
    DemoUSDC usdc;
    DemoStock stock;
    DemoPriceOracle oracle;
    DemoYieldAdapter yieldA;
    DemoSwapAdapter swapA;
    DcaVault vault;

    address owner = address(0x0117E4);
    address stranger = address(0x5747A);
    address keeper = address(0xE8E9E4);

    uint256 constant USDC1 = 1e6;
    uint256 constant PX = 227_56000000;

    function setUp() public {
        usdc = new DemoUSDC(owner);
        oracle = new DemoPriceOracle(owner);
        stock = new DemoStock("Demo NVIDIA", "NVDAc", owner);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        yieldA = new DemoYieldAdapter(usdc, owner, predicted);
        swapA = new DemoSwapAdapter(usdc, stock, oracle, owner);
        vault = new DcaVault(IERC20(address(usdc)), yieldA, swapA, oracle, 250_000 * USDC1);
        require(address(vault) == predicted, "prediction");

        vm.prank(owner);
        oracle.setPrice(address(stock), PX);
        vault.initRoute(
            1,
            DcaVault.Route({
                token: address(stock),
                pool: address(swapA),
                feed: address(oracle),
                dexKind: 0,
                enabled: true
            })
        );
        vault.setKeeper(keeper, true);
        vault.finishSetup();

        // As Deploy.sepolia wires it: the yield adapter is the one minter.
        vm.prank(owner);
        usdc.setMinter(address(yieldA));
    }

    /// The whole point. Every switch that can end the demo, tried by someone
    /// who is not the owner.
    function test_Demo_AStrangerCannotEndTheDemo() public {
        vm.startPrank(stranger);

        vm.expectRevert(DemoOwned.NotOwner.selector);
        stock.setPaused(true);

        vm.expectRevert(DemoOwned.NotOwner.selector);
        stock.setBlocked(address(vault), true);

        vm.expectRevert(DemoOwned.NotOwner.selector);
        yieldA.setSharePrice(0);

        vm.expectRevert(DemoOwned.NotOwner.selector);
        yieldA.accrueTo(1e30);

        vm.expectRevert(DemoOwned.NotOwner.selector);
        yieldA.setLiquidityCap(0);

        vm.expectRevert(DemoOwned.NotOwner.selector);
        oracle.setPrice(address(stock), 1);

        vm.expectRevert(DemoOwned.NotOwner.selector);
        oracle.setFresh(false);

        vm.expectRevert(DemoOwned.NotOwner.selector);
        swapA.setHaircutBps(10_000);

        vm.expectRevert(DemoOwned.NotOwner.selector);
        DemoOwned(address(stock)).setOwner(stranger);

        vm.expectRevert(DemoOwned.NotOwner.selector);
        usdc.setMinter(stranger);

        vm.stopPrank();
    }

    /// C9. A public `mint` with no cooldown let one visitor fill the vault's
    /// whole TVL cap in one transaction and lock every later visitor out.
    /// Measured on a Base Sepolia fork of the live demo before the fix:
    /// mint(room) + createPlan(room, 1e6) took the cap to 249,999 of 250,000
    /// and the next visitor's drip-funded plan reverted CapExceeded.
    function test_Demo_AStrangerCannotMintPastTheFaucet() public {
        vm.prank(stranger);
        vm.expectRevert(DemoUSDC.NotMinter.selector);
        usdc.mint(stranger, 250_000 * USDC1);
        assertEq(usdc.balanceOf(stranger), 0, "a stranger minted demo dollars");

        // ...so filling the cap now costs one drip per $1,000 per four hours,
        // per address, and every address together gets at most DAILY_BUDGET a
        // day (Round2.test_D5_*), and the next visitor still gets in.
        vm.startPrank(stranger);
        usdc.drip();
        usdc.approve(address(vault), type(uint256).max);
        vault.createPlan(1, usdc.DRIP(), 100 * USDC1, 30 days);
        vm.stopPrank();

        address next = address(0x4E47);
        vm.startPrank(next);
        usdc.drip();
        usdc.approve(address(vault), type(uint256).max);
        vault.createPlan(1, 1_000 * USDC1, 100 * USDC1, 30 days);
        vm.stopPrank();
    }

    /// The two callers mint must keep: the owner (seeding the adapter at
    /// deploy) and the yield adapter (interest has to be real dollars).
    function test_Demo_OwnerAndAdapterCanStillMint() public {
        vm.prank(owner);
        usdc.mint(address(yieldA), 10_000 * USDC1);
        assertEq(usdc.balanceOf(address(yieldA)), 10_000 * USDC1);

        vm.prank(address(yieldA));
        usdc.mint(address(yieldA), 1);
        assertEq(usdc.balanceOf(address(yieldA)), 10_000 * USDC1 + 1);
    }

    /// The switches still WORK for the owner — a gate that also locks out the
    /// keeper would have quietly broken the demo instead of protecting it.
    function test_Demo_TheOwnerStillHasEverySwitch() public {
        vm.startPrank(owner);
        stock.setPaused(true);
        assertTrue(stock.paused());
        stock.setPaused(false);

        yieldA.setLiquidityCap(1);
        assertEq(yieldA.liquidityCap(), 1);
        yieldA.setLiquidityCap(type(uint256).max);

        oracle.setFresh(false);
        assertFalse(oracle.isFresh(address(stock)));
        oracle.setFresh(true);

        swapA.setHaircutBps(50);
        assertEq(swapA.haircutBps(), 50);
        vm.stopPrank();
    }

    /// The faucet is the front door and has to stay open to anyone.
    function test_Demo_TheFaucetPoursForAnyone() public {
        vm.prank(stranger);
        usdc.drip();
        assertEq(usdc.balanceOf(stranger), usdc.DRIP(), "no dollars for a first-time visitor");
    }

    /// The cooldown is UX: it keeps one visitor from minting past the TVL cap
    /// and locking everyone else out. It is not security, and it expires.
    function test_Demo_TheFaucetHasACooldownThatExpires() public {
        vm.startPrank(stranger);
        usdc.drip();

        uint256 ready = block.timestamp + usdc.COOLDOWN();
        assertEq(usdc.dripReadyAt(stranger), ready);

        vm.expectRevert(abi.encodeWithSelector(DemoUSDC.DripTooSoon.selector, ready));
        usdc.drip();

        vm.warp(ready);
        usdc.drip();
        assertEq(usdc.balanceOf(stranger), 2 * usdc.DRIP(), "the cooldown never expired");
        assertEq(usdc.dripReadyAt(stranger), block.timestamp + usdc.COOLDOWN());
        vm.stopPrank();
    }

    /// A first-time address is ready NOW, not COOLDOWN seconds after the epoch.
    /// The zero-timestamp case is the one a naive `last + COOLDOWN` gets wrong.
    function test_Demo_AFirstTimeVisitorWaitsForNothing() public view {
        assertEq(usdc.dripReadyAt(stranger), 0);
    }

    /// Gating `mint` would have been the obvious move and would have broken
    /// every buy: the swap adapter mints the stock it sells.
    function test_Demo_TheSwapAdapterCanStillMintTheStockItSells() public {
        vm.prank(stranger);
        usdc.drip();

        vm.startPrank(stranger);
        usdc.approve(address(vault), type(uint256).max);
        uint256 id = vault.createPlan(1, 1_000 * USDC1, 100 * USDC1, 30 days);
        vm.stopPrank();

        (,,,,,,,, bool active) = vault.plans(id);
        assertTrue(active, "the plan did not open");
        assertGt(stock.balanceOf(stranger), 0, "the first installment bought nothing");
    }

    /// The full demo lifecycle, end to end, as a visitor with a faucet and
    /// nothing else. If this passes, the Sepolia deploy is usable by a stranger.
    function test_Demo_AVisitorCanRunTheWholeLifecycle() public {
        vm.prank(stranger);
        usdc.drip();

        vm.startPrank(stranger);
        usdc.approve(address(vault), type(uint256).max);
        uint256 id = vault.createPlan(1, 1_000 * USDC1, 100 * USDC1, 30 days);
        vm.stopPrank();

        // The keeper's other job on a demo chain: interest has to come from
        // somewhere, and on Sepolia there is no Morpho to earn it.
        vm.prank(owner);
        yieldA.accrueTo(1.05e18);
        assertGt(vault.planYield(id), 0, "the demo never earns");

        vm.warp(block.timestamp + 30 days);
        vm.prank(keeper);
        vault.executeDCA(id);

        uint256 before = usdc.balanceOf(stranger);
        vm.prank(stranger);
        vault.exitPlan(id);
        assertGt(usdc.balanceOf(stranger), before, "exit paid out nothing");

        (,,,,,,,, bool active) = vault.plans(id);
        assertFalse(active, "the plan did not close");
    }
}
