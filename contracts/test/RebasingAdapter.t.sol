// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20, MockStock, MockPriceOracle, MockSwapAdapter} from "../src/mocks/Mocks.sol";
import {MockRebasingPool, MockRebasingAdapter} from "../src/mocks/RebasingMocks.sol";

/// @notice The abstraction proof: the ledger survives a backend with no shares.
/// @dev    Every other adapter test runs against MockYieldAdapter, which is
///         ERC-4626-shaped and therefore hands the vault a share to ledger. Aave
///         does not. An aToken balance is `scaled × index` and the number simply
///         grows; there is no share token to hold.
///
///         So these run the SAME vault against a pool that has never heard of a
///         share, with the adapter manufacturing one out of the pool's scaled
///         unit. If the per-plan ledger is sound, nothing below should care
///         which backend it is talking to — and that is the claim Production
///         Readiness rests on when it gates the TVL cap on two adapters.
contract RebasingAdapterTest is Test {
    MockERC20 usdc;
    MockStock stock;
    MockRebasingPool pool;
    MockRebasingAdapter adapter;
    MockPriceOracle oracle;
    MockSwapAdapter swapper;
    DcaVault vault;

    address POOL = address(0xDEADBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant USDC1 = 1e6;
    uint256 constant PX = 227_56000000;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("Mock NVDAc", "NVDAc");
        pool = new MockRebasingPool(usdc);
        adapter = new MockRebasingAdapter(usdc, pool);
        oracle = new MockPriceOracle();
        swapper = new MockSwapAdapter(usdc, stock, oracle);
        oracle.setPrice(address(stock), PX);

        vault = new DcaVault(IERC20(address(usdc)), adapter, swapper, oracle, 1_000_000 * USDC1);
        adapter.bindVault(address(vault));
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

    /// The bug this whole interface is shaped to prevent, now against a pool
    /// that rebases: Alice exits first and must not carry off the interest that
    /// accrued on Bob's money.
    function test_Rebasing_AliceExitFirstLeavesBobsInterestAlone() public {
        uint256 a = _plan(alice, 10_000, 1_000);
        uint256 b = _plan(bob, 10_000, 1_000);

        // Two periods have already fired on deposit, so the idle balances are
        // 9,000 each. 1% on the pool, and the index — not any balance the vault
        // stores — is the only thing that moved.
        pool.accrue(1.01e18);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.exitPlan(a);
        uint256 alicePaid = usdc.balanceOf(alice) - aliceBefore;

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.exitPlan(b);
        uint256 bobPaid = usdc.balanceOf(bob) - bobBefore;

        // 9,000 idle + 1% = 9,090 each, give or take the rounding the scaled
        // unit imposes. Neither may be paid out of the other's share.
        assertApproxEqAbs(alicePaid, 9_090 * USDC1, 2, "alice did not get her own interest");
        assertApproxEqAbs(bobPaid, 9_090 * USDC1, 2, "bob's interest went missing");
        assertApproxEqAbs(alicePaid, bobPaid, 2, "identical plans, different payouts");
    }

    /// Interest arrives as the index moving. A ledger that stored an asset
    /// amount instead of a share count would show nothing here.
    function test_Rebasing_InterestShowsUpWithoutAnySharesChanging() public {
        uint256 id = _plan(alice, 10_000, 1_000);
        uint256 before = vault.planYield(id);
        assertEq(before, 0, "nothing earned yet");

        uint256 scaledBefore = pool.scaledBalanceOf(address(adapter));
        pool.accrue(1.02e18);
        uint256 scaledAfter = pool.scaledBalanceOf(address(adapter));

        assertEq(scaledAfter, scaledBefore, "a rebase must not mint shares");
        assertApproxEqAbs(vault.planYield(id), 180 * USDC1, 2, "2% of 9,000 idle");
    }

    /// A donation straight into the pool is the attack that bricks any adapter
    /// whose accounting is derived from a raw balance.
    function test_Rebasing_DonationMovesNobodysClaim() public {
        uint256 id = _plan(alice, 10_000, 1_000);
        uint256 owed = vault.planYield(id);

        usdc.mint(address(this), 50_000 * USDC1);
        usdc.transfer(address(pool), 50_000 * USDC1);

        assertEq(vault.planYield(id), owed, "a donation became someone's yield");
    }

    /// The pool short-fills rather than reverting, which is Aave-shaped enough
    /// to matter: the ledger has to debit what was ACTUALLY burned.
    function test_Rebasing_ShortFillDebitsWhatWasActuallyBurned() public {
        _plan(alice, 10_000, 1_000);
        pool.accrue(1.01e18);

        uint256 scaledBefore = pool.scaledBalanceOf(address(adapter));
        pool.setLiquidityCap(1_000 * USDC1);

        vm.prank(address(vault));
        (uint256 got, uint256 burned) = adapter.withdraw(5_000 * USDC1);

        assertEq(got, 1_000 * USDC1, "the cap is the fill");
        assertEq(
            scaledBefore - pool.scaledBalanceOf(address(adapter)),
            burned,
            "reported burn disagrees with the pool"
        );
        // Derived from the asset amount it ASKED for, the debit would have been
        // five times too big and four plans' worth of interest would vanish.
        assertLt(burned, 5_000 * USDC1 * 1e27 / pool.index() / 2, "debited the ask, not the fill");
    }

    /// A falling index is a loss the user absorbs on exit, never a revert.
    function test_Rebasing_LossIsAbsorbedOnExitAndNeverReverts() public {
        uint256 id = _plan(alice, 10_000, 1_000);
        pool.slash(0.9e18); // the adapter is now worth less than principal

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.exitPlan(id);
        uint256 paid = usdc.balanceOf(alice) - before;

        assertLt(paid, 9_000 * USDC1, "a 10% loss did not reach the user");
        assertApproxEqAbs(paid, 8_100 * USDC1, 2, "the loss was not proportional");
        (,,,,,,,, bool active) = vault.plans(id);
        assertFalse(active, "the plan has to close even at a loss");
    }
}
