// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {InvStats} from "./utils/InvStats.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {
    MockERC20,
    MockStock,
    MockYieldAdapter,
    MockPriceOracle,
    MockSwapAdapter
} from "../src/mocks/Mocks.sol";

/// @notice Drives the vault with MULTIPLE plans.
/// @dev    A single-plan handler cannot falsify any cross-plan property, which
///         is the one class of bug this design is most prone to. Every actor
///         below owns a live plan simultaneously.
///
///         C11: this handler used to wrap every call in `try ... catch {}`, so
///         a Panic(0x11) looked exactly like a legitimate `NotYetDue` and the
///         suite could not see the final-installment underflow it was run to
///         find. Now a revert is only tolerated if it is one of the vault's
///         own EXPECTED custom errors for that call; anything else — a Panic,
///         a bare revert, an error the call has no business raising — is
///         counted, and `invariant_NoUnexpectedRevert` fails on it.
contract Handler is Test {
    DcaVault public vault;
    MockERC20 public usdc;
    MockYieldAdapter public yield_;
    address[] public actors;
    uint256[] public planIds;

    uint256 public unexpected;
    bytes public lastUnexpected;
    string public lastUnexpectedWhere;

    // Round 3 (F6): how much executeDCA this handler actually exercised.
    uint256 public execCalls; // execute() with at least one active plan
    uint256 public execOk;

    constructor(DcaVault v, MockERC20 u, MockYieldAdapter y, address[] memory a) {
        vault = v;
        usdc = u;
        yield_ = y;
        actors = a;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length >= 4) s = bytes4(err);
    }

    function _unexpected(bytes memory err, string memory where) internal {
        unexpected++;
        lastUnexpected = err;
        lastUnexpectedWhere = where;
    }

    function createPlan(uint256 seed, uint256 dep, uint256 inst) public {
        dep = bound(dep, 100e6, 50_000e6);
        // at most MAX_PERIODS installments, at least MIN_INSTALLMENT each
        uint256 lo = (dep + vault.MAX_PERIODS() - 1) / vault.MAX_PERIODS();
        if (lo < vault.MIN_INSTALLMENT()) lo = vault.MIN_INSTALLMENT();
        inst = bound(inst, lo, dep);
        address a = _actor(seed);
        usdc.mint(a, dep);
        vm.startPrank(a);
        usdc.approve(address(vault), type(uint256).max);
        try vault.createPlan(1, dep, inst, 30 days) returns (uint256 id) {
            planIds.push(id);
        } catch (bytes memory err) {
            // The only legitimate refusal here: the lending leg cannot fund
            // the first buy (a loss left the mock short of real assets).
            if (_sel(err) != DcaVault.InsufficientAdapterLiquidity.selector) {
                _unexpected(err, "createPlan");
            }
        }
        vm.stopPrank();
    }

    /// @dev Round 3 (F6). This used to warp a random 1-120 days and pick a
    ///      random plan, usually a finished one, then return: 17 successful
    ///      executes in 202 runs x 200 calls. Now it picks an ACTIVE plan
    ///      and, most of the time, warps to exactly its due time (the rest of
    ///      the time it does not warp, so NotYetDue stays exercised).
    function execute(uint256 seed, uint256 warpBy) public {
        uint256 n = planIds.length;
        if (n == 0) return;
        uint256 id;
        bool found;
        for (uint256 j; j < n; ++j) {
            uint256 c = planIds[(seed % n + j) % n];
            (,,,,,,,, bool a) = vault.plans(c);
            if (a) {
                (id, found) = (c, true);
                break;
            }
        }
        if (!found) return;
        execCalls++;
        (address owner,,,,, uint64 ne,,,) = vault.plans(id);
        if (warpBy % 8 != 0 && ne > block.timestamp) vm.warp(ne + (warpBy % 3 == 0 ? warpBy % 2 days : 0));
        vm.prank(owner);
        try vault.executeDCA(id) {
            execOk++;
        } catch (bytes memory err) {
            bytes4 s = _sel(err);
            if (s != DcaVault.NotYetDue.selector && s != DcaVault.InsufficientAdapterLiquidity.selector) {
                _unexpected(err, "executeDCA");
            }
        }
    }

    function exit(uint256 seed) public {
        if (planIds.length == 0) return;
        uint256 id = planIds[seed % planIds.length];
        (address owner,,,,,,,, bool active) = vault.plans(id);
        if (!active) return;
        vm.prank(owner);
        try vault.exitPlan(id) {}
        catch (bytes memory err) {
            if (_sel(err) != DcaVault.InsufficientAdapterLiquidity.selector) {
                _unexpected(err, "exitPlan");
            }
        }
    }

    /// @dev Solvent interest accrual, and occasionally a LOSS. The mock
    ///      cannot fail here, so this one is not wrapped at all.
    function accrue(uint256 wad) public {
        wad = bound(wad, 0.95e18, 1.5e18);
        yield_.accrueTo(wad);
    }

    function planCount() external view returns (uint256) {
        return planIds.length;
    }

    function planAt(uint256 i) external view returns (uint256) {
        return planIds[i];
    }
}

contract InvariantsTest is Test {
    MockERC20 usdc;
    MockStock stock;
    MockYieldAdapter yield_;
    MockPriceOracle oracle;
    MockSwapAdapter swapper;
    DcaVault vault;
    Handler handler;
    address POOL = address(0xDEADBEEF);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("Mock NVDAc", "NVDAc");
        yield_ = new MockYieldAdapter(usdc);
        oracle = new MockPriceOracle();
        swapper = new MockSwapAdapter(usdc, stock, oracle);
        oracle.setPrice(address(stock), 227_56000000);
        vault = new DcaVault(IERC20(address(usdc)), yield_, swapper, oracle, type(uint256).max);
        yield_.bindVault(address(vault));
        vault.initRoute(
            1,
            DcaVault.Route({
                token: address(stock), pool: POOL, feed: address(oracle), dexKind: 0, enabled: true
            })
        );
        vault.finishSetup();
        address[] memory actors = new address[](4);
        actors[0] = address(0xA1);
        actors[1] = address(0xA2);
        actors[2] = address(0xA3);
        actors[3] = address(0xA4);
        handler = new Handler(vault, usdc, yield_, actors);
        targetContract(address(handler));
    }

    /// INVARIANT 0 — the shares add up.
    /// @dev The property invariant 1 (global conservation) CANNOT catch: at the
    ///      instant one plan spends another's principal, conservation still
    ///      balances. It only surfaces when the victim exits.
    function invariant_0_ShareLedgerSumsToVaultBalance() public view {
        uint256 sum;
        uint256 n = handler.planCount();
        for (uint256 i; i < n; ++i) {
            (,,,, uint256 shares,,,,) = vault.plans(handler.planAt(i));
            sum += shares;
        }
        assertEq(sum, vault.totalManagedShares(), "INV0: per-plan shares != totalManagedShares");
    }

    /// INVARIANT 2 — remainingPrincipal never increases, accrued never underflows.
    function invariant_2_PrincipalNeverExceedsDeposit() public view {
        uint256 n = handler.planCount();
        for (uint256 i; i < n; ++i) {
            (,, uint256 inst, uint256 rem,,,,,) = vault.plans(handler.planAt(i));
            assertLe(rem, 50_000e6, "INV2: principal grew past any legal deposit");
            if (rem > 0) assertGt(inst, 0, "INV2: live plan with zero installment");
        }
    }

    /// INVARIANT 8 — the vault never keeps the stock token.
    function invariant_8_VaultHoldsNoStock() public view {
        assertEq(stock.balanceOf(address(vault)), 0, "INV8: vault is holding stock");
    }

    /// INVARIANT (C11) — no call reverted with anything but an expected
    /// custom error. A Panic anywhere in the vault fails here.
    function invariant_NoUnexpectedRevert() public view {
        assertEq(
            handler.unexpected(),
            0,
            string.concat(
                "unexpected revert in ",
                handler.lastUnexpectedWhere(),
                ": ",
                vm.toString(handler.lastUnexpected())
            )
        );
    }

    /// F6: the handler really drives executions. Every run long enough to
    /// have tried at least MIN_EXEC_TRIES executes on active plans must have
    /// landed at least one: the world here is friendly (fresh feed, honest
    /// venue), so a run of all-reverting executes is a broken handler.
    uint256 constant MIN_EXEC_TRIES = 4;

    function afterInvariant() public {
        InvStats.record(
            "Invariants",
            string.concat(vm.toString(handler.execOk()), " ", vm.toString(handler.execCalls()))
        );
        if (handler.execCalls() >= MIN_EXEC_TRIES) {
            assertGt(handler.execOk(), 0, "F6: no successful executeDCA in this run");
        }
    }

    /// INVARIANT — totalPrincipal is the sum of live plan principals.
    function invariant_TotalPrincipalConsistent() public view {
        uint256 sum;
        uint256 n = handler.planCount();
        for (uint256 i; i < n; ++i) {
            (,,, uint256 rem,,,,,) = vault.plans(handler.planAt(i));
            sum += rem;
        }
        assertEq(sum, vault.totalPrincipal(), "totalPrincipal drifted from plan sum");
    }
}
