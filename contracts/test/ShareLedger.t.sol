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

/// @notice The three tests that are written BEFORE trusting the vault.
/// @dev    Every one of these targets a bug that was written into the design
///         notes as the specification and is invisible in a single-plan test.
contract ShareLedgerTest is Test {
    MockERC20 usdc;
    MockStock stock;
    MockYieldAdapter yield_;
    MockPriceOracle oracle;
    MockSwapAdapter swapper;
    DcaVault vault;

    address POOL = address(0xDEADBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant USDC1 = 1e6; // USDC is 6dp
    uint256 constant PX = 227_56000000; // $227.56, 8dp — live NVDAc feed price

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("Mock NVDAc", "NVDAc");
        yield_ = new MockYieldAdapter(usdc);
        oracle = new MockPriceOracle();
        swapper = new MockSwapAdapter(usdc, stock, oracle);
        oracle.setPrice(address(stock), PX);

        vault = new DcaVault(IERC20(address(usdc)), yield_, swapper, oracle, 1_000_000 * USDC1);
        yield_.bindVault(address(vault));
        vault.initRoute(
            1,
            DcaVault.Route({
                token: address(stock), pool: POOL, feed: address(oracle), dexKind: 0, enabled: true
            })
        );
        vault.finishSetup();

        usdc.mint(alice, 100_000 * USDC1);
        usdc.mint(bob, 100_000 * USDC1);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _plan(address who, uint256 dep, uint256 inst) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.createPlan(1, dep * USDC1, inst * USDC1, 30 days);
    }

    /// TEST 1 — the catastrophe the notes specified.
    /// With an argument-less `balanceOf()` as the yield base, Alice's exit pays
    /// out the ENTIRE pooled position and Bob's exit reverts on an empty adapter.
    function test_AliceExitFirst_BobKeepsHisOwnPrincipalAndYield() public {
        uint256 a = _plan(alice, 10_000, 1_000);
        uint256 b = _plan(bob, 5_000, 500);

        // 10% accrues to everyone proportionally, as REAL assets
        yield_.accrueTo(1.1e18);

        uint256 bobClaimBefore = vault.planYield(b) + 4_500 * USDC1;

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.exitPlan(a);
        uint256 alicePaid = usdc.balanceOf(alice) - aliceBefore;

        // Alice's 9,000 principal grew 10% -> ~9,900. NOT the whole pool (~14,850).
        assertApproxEqRel(
            alicePaid, 9_900 * USDC1, 0.001e18, "alice overpaid - pooled balance leaked"
        );

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob); // must NOT revert
        vault.exitPlan(b);
        uint256 bobPaid = usdc.balanceOf(bob) - bobBefore;

        assertApproxEqRel(bobPaid, 4_950 * USDC1, 0.001e18, "bob lost his yield to alice");
        assertGe(bobPaid, bobClaimBefore * 999 / 1000, "bob shortchanged");
    }

    /// TEST 2 — create and exit in the same block.
    /// ERC-4626 rounds down twice, so 9,000 round-trips to 8,999.999999 and a
    /// literal `total - principal` is an arithmetic Panic on one wei.
    function test_CreateThenExitSameBlock_DoesNotRevert() public {
        uint256 id = _plan(alice, 10_000, 1_000);
        yield_.setSharePrice(1e18 - 1); // one wei below par
        vm.prank(alice);
        vault.exitPlan(id); // must not Panic(0x11)
    }

    /// TEST 3 — donation attack.
    /// Anyone can supply straight into the pooled position. No plan's claim may move.
    function test_DonationIntoAdapter_MovesNobodysClaim() public {
        uint256 a = _plan(alice, 10_000, 1_000);
        uint256 before = vault.planYield(a);

        address attacker = address(0xBAD);
        usdc.mint(attacker, 10_000 * USDC1);
        vm.startPrank(attacker);
        usdc.approve(address(yield_), type(uint256).max);
        yield_.donate(10_000 * USDC1);
        vm.stopPrank();

        assertEq(vault.planYield(a), before, "a raw donation moved a plan's claim");
    }

    /// TEST 4 — an overdue plan cannot be compressed into one block.
    function test_OverduePlan_CannotExecuteTwiceInOneBlock() public {
        uint256 id = _plan(alice, 10_000, 1_000);
        vm.warp(block.timestamp + 95 days); // three intervals overdue

        vault.executeDCA(id);
        vm.expectRevert(DcaVault.NotYetDue.selector);
        vault.executeDCA(id); // same block, must refuse
    }
}
