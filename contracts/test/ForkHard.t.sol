// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle, IAggregatorV3} from "../src/adapters/ChainlinkOracle.sol";
import {MorphoAdapter, IERC4626} from "../src/adapters/MorphoAdapter.sol";
import {AaveAdapter, IAavePool, IAToken} from "../src/adapters/AaveAdapter.sol";
import {MockERC20, MockStock, MockPriceOracle, MockSwapAdapter} from "../src/mocks/Mocks.sol";

/// @notice The hard test's fork probes (2026-09-28), against the REAL lending
///         legs on a pinned Base mainnet fork, turned into assertions.
/// @dev    Honest record: against the unfixed code these probes did NOT reproduce C3/C4
///         on the real legs (0 Panics over 14 one-shot sizes on each adapter,
///         and both final slices executed), because Morpho's and Aave's
///         rounding at this block happened to land the right way; the mocks'
///         did not, and the directed tests in Hardening.t.sol are the proof of
///         the bug. What these assert is the other half: the NEW final-slice
///         path (redeem everything, spend what comes back) works against the
///         real share prices. The swap leg stays a mock priced off the real
///         NVDA feed (B20 tokens are precompiles a fork cannot execute; see
///         Fork.t.sol).
///
///         The feed does not print on a fork, so after a warp it would be
///         stale and the vault would — correctly — refuse to buy. `_feedPrints`
///         re-serves the real last answer with a current timestamp, which is
///         what the live feed does every day the market is open.
contract ForkHardTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MORPHO = 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61;
    address constant FEED = 0x04689a41629776563E6822F76f2e57D148d28513;
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    uint256 constant FORK_BLOCK = 51_628_000;

    ChainlinkOracle oracle;
    MockStock stock;
    MockPriceOracle poolOracle;
    MockSwapAdapter swapper;
    DcaVault vm4626;
    DcaVault vAave;
    MorphoAdapter morpho;
    AaveAdapter aave;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.skip(keccak256(bytes(rpc)) == keccak256("off") || bytes(rpc).length == 0);
        vm.createSelectFork(rpc, FORK_BLOCK);
        _feedPrints();

        oracle = new ChainlinkOracle(address(0), false);
        stock = new MockStock("Fork NVDAc", "NVDAc");
        oracle.setFeed(address(stock), FEED);
        poolOracle = new MockPriceOracle();
        swapper = new MockSwapAdapter(MockERC20(USDC), stock, poolOracle);
        (uint256 live,) = oracle.latestPrice(address(stock));
        poolOracle.setPrice(address(stock), live);

        address p1 = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        morpho = new MorphoAdapter(IERC20(USDC), IERC4626(MORPHO), p1);
        vm4626 = new DcaVault(IERC20(USDC), morpho, swapper, oracle, 10_000_000e6);
        address p2 = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        aave = new AaveAdapter(IERC20(USDC), IAavePool(AAVE_POOL), IAToken(AUSDC), p2);
        vAave = new DcaVault(IERC20(USDC), aave, swapper, oracle, 10_000_000e6);
        DcaVault.Route memory r = DcaVault.Route(address(stock), address(swapper), FEED, 0, true);
        vm4626.initRoute(1, r);
        vAave.initRoute(1, r);
        vm4626.finishSetup();
        vAave.finishSetup();
        for (uint256 i; i < 2; ++i) {
            address a = i == 0 ? alice : bob;
            deal(USDC, a, 10_000_000e6);
            vm.deal(a, 1 ether);
            vm.startPrank(a);
            IERC20(USDC).approve(address(vm4626), type(uint256).max);
            IERC20(USDC).approve(address(vAave), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// The real feed's last answer, stamped now.
    function _feedPrints() internal {
        (uint80 id, int256 answer, uint256 started,, uint80 inRound) =
            IAggregatorV3(FEED).latestRoundData();
        vm.mockCall(
            FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(id, answer, started, block.timestamp, inRound)
        );
    }

    /// C4 — one-shot plans against the REAL lending legs, over a spread of
    /// sizes. Every one creates and completes; none reverts.
    function test_Fork_OneShotPlansNeverRevert_Morpho_and_Aave() public {
        uint256 n;
        for (uint256 d = 1e6; d <= 2_000_000e6; d = d * 3 + 7) {
            n++;
            vm.startPrank(alice);
            uint256 a = vm4626.createPlan(1, d, d, 30 days);
            uint256 b = vAave.createPlan(1, d, d, 30 days);
            vm.stopPrank();
            (,,,,,,,, bool actA) = vm4626.plans(a);
            (,,,,,,,, bool actB) = vAave.plans(b);
            assertFalse(actA || actB, "a one-shot plan did not complete");
        }
        assertEq(vm4626.totalPrincipal(), 0);
        assertEq(vAave.totalPrincipal(), 0);
        emit log_named_uint("sizes tried per adapter", n);
    }

    /// C3 — the final installment, one day after the first, with almost no
    /// interest in between, on both real share prices. It completes.
    function test_Fork_FinalInstallmentWithLittleInterestCompletes() public {
        for (uint256 k; k < 2; ++k) {
            DcaVault v = k == 0 ? vm4626 : vAave;
            vm.prank(bob); // pool liquidity from another plan
            v.createPlan(1, 100_000e6, 1_000e6, 30 days);
            vm.prank(alice);
            uint256 id = v.createPlan(1, 1_999_999_999, 1_000_000_000, 1 days);
            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 43_200);
            _feedPrints();
            vm.prank(alice);
            v.executeDCA(id);
            (,,, uint256 rem, uint256 sh,,,, bool active) = v.plans(id);
            assertFalse(active, "final installment did not complete");
            assertEq(rem + sh, 0);
        }
    }

    /// Aave's redeem can burn fewer scaled units than the ledger debits. That
    /// dust stays in the adapter owned by no plan — the protocol's, never a
    /// user's shortfall. The adapter must always hold at least the ledger.
    function test_Fork_AaveLedgerNeverExceedsWhatTheAdapterHolds() public {
        vm.prank(bob);
        vAave.createPlan(1, 100_000e6, 1_000e6, 30 days);
        for (uint256 i; i < 20; ++i) {
            vm.prank(alice);
            // Odd amounts, with the odd part in the last period, which has
            // to be at least 1 USDC itself: a tail of 1.345678 USDC and up.
            uint256 id = vAave.createPlan(1, 13_345_678 + i * 2_000_003, 2_000_000, 30 days);
            vm.warp(block.timestamp + 3 days);
            vm.roll(block.number + 3 * 43_200);
            _feedPrints();
            vm.prank(alice);
            vAave.exitPlan(id);
        }
        uint256 held = IAToken(AUSDC).scaledBalanceOf(address(aave));
        uint256 ledger = vAave.totalManagedShares();
        assertGe(held, ledger, "the ledger claims more than the adapter holds");
        emit log_named_uint("orphaned scaled units (protocol-owned dust)", held - ledger);
    }
}
