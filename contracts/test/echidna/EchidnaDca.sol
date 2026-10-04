// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DcaVault} from "../../src/DcaVault.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {
    MockERC20,
    MockStock,
    MockYieldAdapter,
    MockPriceOracle,
    MockSwapAdapter
} from "../../src/mocks/Mocks.sol";

/// @dev A plan owner. Echidna's senders cannot own plans themselves because
///      the harness has to know who owns what.
contract User {
    function create(DcaVault v, MockERC20 u, uint256 dep, uint256 inst, uint64 iv)
        external
        returns (uint256)
    {
        u.approve(address(v), type(uint256).max);
        return v.createPlan(1, dep, inst, iv);
    }

    function exec(DcaVault v, uint256 id) external {
        v.executeDCA(id);
    }

    function exit(DcaVault v, uint256 id) external {
        v.exitPlan(id);
    }
}

/// @notice Echidna property harness from the 2026-09-28 hard test.
/// @dev    Not a forge test (no `test` functions; forge ignores it). Run from
///         the repo root:
///
///             echidna . --contract EchidnaDca --config contracts/test/echidna/echidna.yaml
///
///         Against the unfixed code `echidna_no_panic_at_all` fell in two calls —
///         `accrue(1)` then a one-shot `create` — the C4 Panic. It now also
///         checks C11's rule (no revert outside the expected set), the fee
///         bucket, and the new one-shot and loss paths directly.
contract EchidnaDca {
    MockERC20 usdc;
    MockStock stock;
    MockYieldAdapter y;
    MockPriceOracle oracle;
    MockSwapAdapter swapper;
    DcaVault vault;
    User[4] users;
    uint256[] ids;
    mapping(uint256 => User) ownerOf;
    mapping(uint256 => uint256) nextAt;

    bool loss;
    uint256 panicCount;
    uint256 panicMultiCount;
    uint256 unexpectedCount;
    uint256 earlyExec;
    uint256 exitWhileLiquidFailed;
    uint256 crossHarm;
    uint256 pendingSurvivedInstant;
    uint256 earlyBounds;

    constructor() {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stock = new MockStock("NVDAc", "NVDAc");
        y = new MockYieldAdapter(usdc);
        oracle = new MockPriceOracle();
        swapper = new MockSwapAdapter(usdc, stock, oracle);
        oracle.setPrice(address(stock), 227_56000000);
        vault = new DcaVault(IERC20(address(usdc)), y, swapper, oracle, 1_000_000e6);
        y.bindVault(address(vault));
        vault.initRoute(
            1, DcaVault.Route(address(stock), address(swapper), address(oracle), 0, true)
        );
        vault.finishSetup();
        vault.setFee(500);
        for (uint256 i; i < 4; ++i) users[i] = new User();
    }

    function _panic(bytes memory err) internal pure returns (bool) {
        return err.length == 36 && bytes4(err) == bytes4(0x4e487b71);
    }

    /// C11: the only acceptable refusals.
    function _expected(bytes memory err) internal pure returns (bool) {
        if (err.length < 4) return false;
        bytes4 s = bytes4(err);
        return s == DcaVault.NotYetDue.selector || s == DcaVault.PlanInactive.selector
            || s == DcaVault.CapExceeded.selector || s == DcaVault.BadParams.selector
            || s == DcaVault.InsufficientAdapterLiquidity.selector
            || s == DcaVault.PoolDiverged.selector
            || keccak256(err) == keccak256(abi.encodeWithSignature("Error(string)", "SLIPPAGE"));
    }

    function _record(bytes memory err, bool multi) internal {
        if (_panic(err)) {
            panicCount++;
            if (multi) panicMultiCount++;
        }
        if (!_expected(err)) unexpectedCount++;
    }

    function _create(uint8 who, uint256 dep, uint256 inst, uint64 interval) internal {
        User u = users[who % 4];
        usdc.mint(address(u), dep);
        try u.create(vault, usdc, dep, inst, interval) returns (uint256 id) {
            ids.push(id);
            ownerOf[id] = u;
            (,,,,, uint64 ne,,,) = vault.plans(id);
            nextAt[id] = ne;
        } catch (bytes memory err) {
            _record(err, inst < dep);
        }
    }

    function create(uint8 who, uint256 dep, uint8 months, uint32 iv) public {
        dep = 1 + dep % 200_000e6;
        uint256 m = 3 + months % 58;
        uint256 inst = dep / m;
        if (inst == 0) inst = dep;
        _create(who, dep, inst, uint64(1 days + uint256(iv) % 90 days));
    }

    /// C4's shape directly: installment == deposit.
    function createOneShot(uint8 who, uint256 dep) public {
        dep = 1e6 + dep % 200_000e6;
        _create(who, dep, dep, 30 days);
    }

    function exec(uint256 k) public {
        if (ids.length == 0) return;
        uint256 id = ids[k % ids.length];
        uint256 other = ids[(k + 1) % ids.length];
        (,,, uint256 otherRem, uint256 otherSh,,,,) = vault.plans(other);
        try ownerOf[id].exec(vault, id) {
            if (block.timestamp < nextAt[id]) earlyExec++;
            (,,,,, uint64 ne,,,) = vault.plans(id);
            nextAt[id] = ne;
            if (other != id) {
                (,,, uint256 r2, uint256 s2,,,,) = vault.plans(other);
                if (r2 != otherRem || s2 != otherSh) crossHarm++;
            }
        } catch (bytes memory err) {
            _record(err, true);
        }
    }

    function exit(uint256 k) public {
        if (ids.length == 0) return;
        uint256 id = ids[k % ids.length];
        (,,,, uint256 sh,,,, bool act) = vault.plans(id);
        if (!act) return;
        bool liquid = y.availableLiquidity() >= y.assetsOf(sh);
        try ownerOf[id].exit(vault, id) {}
        catch (bytes memory err) {
            _record(err, true);
            if (liquid) exitWhileLiquidFailed++;
        }
    }

    function accrue(uint16 bps) public {
        y.accrueTo(y.sharePriceWad() * (10_000 + uint256(bps) % 500) / 10_000);
    }

    function lose(uint16 bps) public {
        loss = true;
        y.setSharePrice(y.sharePriceWad() * (10_000 - 1 - uint256(bps) % 1000) / 10_000);
    }

    function haircut(uint16 b) public {
        swapper.setHaircutBps(uint256(b) % 800);
    }

    function claim() public {
        vault.claimFees();
    }

    /// Round 3 (F2): the harness is the admin. An instant (non-loosening)
    /// change must leave no loosening queued behind it.
    function bounds(uint16 s, uint16 d) public {
        s = s % 201;
        d = d % 2001;
        bool instant = s <= vault.maxSlippageBps() && d <= vault.maxDeviationBps();
        vault.setBounds(s, d);
        (,, uint64 eta) = vault.pendingBounds();
        if (instant && eta != 0) pendingSurvivedInstant++;
    }

    function activateBounds() public {
        (uint16 ps, uint16 pd, uint64 eta) = vault.pendingBounds();
        try vault.activateBounds() {
            if (block.timestamp < eta) earlyBounds++;
            if (vault.maxSlippageBps() != ps || vault.maxDeviationBps() != pd) earlyBounds++;
        } catch {}
    }

    // ---------------------------------------------------------- properties
    function echidna_instant_bounds_drop_queue() public view returns (bool) {
        return pendingSurvivedInstant == 0 && earlyBounds == 0;
    }

    /// Round 3 (F4): the harness closed setup in its constructor, and the
    /// window never reopens.
    function echidna_setup_stays_closed() public view returns (bool) {
        return vault.setupFinished();
    }

    function echidna_shares_sum() public view returns (bool) {
        uint256 sum;
        for (uint256 i; i < ids.length; ++i) {
            (,,,, uint256 sh,,,,) = vault.plans(ids[i]);
            sum += sh;
        }
        return sum == vault.totalManagedShares();
    }

    function echidna_principal_sum() public view returns (bool) {
        uint256 sum;
        for (uint256 i; i < ids.length; ++i) {
            (,,, uint256 r,,,,,) = vault.plans(ids[i]);
            sum += r;
        }
        return sum == vault.totalPrincipal() && vault.totalPrincipal() <= vault.tvlCap();
    }

    function echidna_no_early_exec() public view returns (bool) {
        return earlyExec == 0;
    }

    function echidna_no_cross_harm() public view returns (bool) {
        return crossHarm == 0;
    }

    function echidna_exit_when_liquid() public view returns (bool) {
        return exitWhileLiquidFailed == 0;
    }

    function echidna_no_panic_multi_create() public view returns (bool) {
        return panicMultiCount == 0;
    }

    function echidna_no_panic_at_all() public view returns (bool) {
        return panicCount == 0;
    }

    function echidna_no_unexpected_revert() public view returns (bool) {
        return unexpectedCount == 0;
    }

    /// The vault holds no stock ever, and no USDC except fees not yet claimed.
    function echidna_vault_holds_only_unclaimed_fees() public view returns (bool) {
        return usdc.balanceOf(address(vault)) == vault.feesAccrued()
            && stock.balanceOf(address(vault)) == 0;
    }
}
