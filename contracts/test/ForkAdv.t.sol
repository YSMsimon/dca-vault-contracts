// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IYieldAdapter} from "../src/interfaces/IYieldAdapter.sol";
import {ChainlinkOracle, IAggregatorV3} from "../src/adapters/ChainlinkOracle.sol";
import {MorphoAdapter, IERC4626} from "../src/adapters/MorphoAdapter.sol";
import {AaveAdapter, IAavePool, IAToken} from "../src/adapters/AaveAdapter.sol";
import {MockERC20, MockStock, MockPriceOracle, MockSwapAdapter} from "../src/mocks/Mocks.sol";

/// @notice Real Morpho (Gauntlet USDC Prime) and real Aave V3 legs under the
///         hardened _draw: fuzzed multi-plan schedules with interleaved
///         execute/exit. From the round-2 re-test, kept.
/// @dev    Pinned to the same block as ForkHard and ForkAdapters, so the RPC
///         cache is shared and every fuzz run after the first is local. Like
///         the other Fork suites it creates its own fork and skips when
///         BASE_RPC_URL=off. Runs follow the profile (FOUNDRY_FUZZ_RUNS).
contract ForkAdvTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MORPHO = 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61;
    address constant FEED = 0x04689a41629776563E6822F76f2e57D148d28513;
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    uint256 constant FORK_BLOCK = 51_628_000;

    ChainlinkOracle oracle;
    MockStock stock;
    MockSwapAdapter swapper;
    DcaVault[2] vs;
    IYieldAdapter[2] ads;
    address[3] us = [address(0xA1), address(0xB2), address(0xC3)];

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.skip(keccak256(bytes(rpc)) == keccak256("off") || bytes(rpc).length == 0);
        vm.createSelectFork(rpc, FORK_BLOCK);
        _feedPrints();
        oracle = new ChainlinkOracle();
        stock = new MockStock("Fork NVDAc", "NVDAc");
        oracle.setFeed(address(stock), FEED);
        MockPriceOracle po = new MockPriceOracle();
        swapper = new MockSwapAdapter(MockERC20(USDC), stock, po);
        (uint256 live,) = oracle.latestPrice(address(stock));
        po.setPrice(address(stock), live);
        address p1 = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MorphoAdapter m = new MorphoAdapter(IERC20(USDC), IERC4626(MORPHO), p1);
        vs[0] = new DcaVault(IERC20(USDC), m, swapper, oracle, 100_000_000e6);
        address p2 = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        AaveAdapter a = new AaveAdapter(IERC20(USDC), IAavePool(AAVE_POOL), IAToken(AUSDC), p2);
        vs[1] = new DcaVault(IERC20(USDC), a, swapper, oracle, 100_000_000e6);
        ads[0] = m;
        ads[1] = a;
        DcaVault.Route memory r = DcaVault.Route(address(stock), address(swapper), FEED, 0, true);
        vs[0].initRoute(1, r);
        vs[1].initRoute(1, r);
        vs[0].finishSetup();
        vs[1].finishSetup();
        for (uint256 i; i < 3; ++i) {
            deal(USDC, us[i], 100_000_000e6);
            vm.startPrank(us[i]);
            IERC20(USDC).approve(address(vs[0]), type(uint256).max);
            IERC20(USDC).approve(address(vs[1]), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _feedPrints() internal {
        (uint80 id, int256 answer, uint256 started,, uint80 inRound) = IAggregatorV3(FEED).latestRoundData();
        vm.mockCall(
            FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(id, answer, started, block.timestamp, inRound)
        );
    }

    function _held(uint256 k) internal view returns (uint256) {
        return k == 0
            ? IERC4626(MORPHO).balanceOf(address(ads[0]))
            : IAToken(AUSDC).scaledBalanceOf(address(ads[1]));
    }

    uint256[3] ids;
    uint256 maxShort;

    function _op(uint256 k, uint256 j, bool doExit) internal {
        DcaVault v = vs[k];
        (address o,,, uint256 rem, uint256 sh,,,, bool act) = v.plans(ids[j]);
        if (!act) return;
        uint256[3] memory otherSh;
        for (uint256 q; q < 3; ++q) (,,,, otherSh[q],,,,) = v.plans(ids[q]);
        uint256 u0 = IERC20(USDC).balanceOf(o) + IERC20(USDC).balanceOf(address(swapper));
        vm.prank(o);
        if (doExit) v.exitPlan(ids[j]);
        else v.executeDCA(ids[j]);
        uint256 got = IERC20(USDC).balanceOf(o) + IERC20(USDC).balanceOf(address(swapper)) - u0;
        (,,,, uint256 sh2,,,,) = v.plans(ids[j]);
        uint256 burned = sh - sh2;
        // a plan never receives more than its burned shares are worth (+1 wei rounding of the view)
        assertLe(got, ads[k].assetsOf(burned) + 1, "overdraw");
        if (sh2 == 0 && got < rem) {
            if (rem - got > maxShort) maxShort = rem - got;
        }
        for (uint256 q; q < 3; ++q) {
            if (q == j) continue;
            (,,,, uint256 s,,,,) = v.plans(ids[q]);
            assertEq(s, otherSh[q], "isolation");
        }
        assertGe(_held(k), v.totalManagedShares(), "ledger > held");
    }

    function testFuzz_ForkMultiPlan(uint256 seed, uint256 d0, uint256 d1, uint256 d2) public {
        uint256[3] memory d = [bound(d0, 1e6, 3_000_000e6), bound(d1, 1e6, 300_000e6), bound(d2, 1e6, 50_000e6)];
        for (uint256 k; k < 2; ++k) {
            for (uint256 j; j < 3; ++j) {
                uint256 n = 1 + (uint256(keccak256(abi.encode(seed, j))) % 6);
                uint256 inst = (d[j] + n - 1) / n;
                if (inst < 1e6) inst = 1e6;
                vm.prank(us[j]);
                ids[j] = vs[k].createPlan(1, d[j], inst, 1 days);
            }
            for (uint256 step; step < 10; ++step) {
                uint256 r = uint256(keccak256(abi.encode(seed, k, step)));
                vm.warp(block.timestamp + 1 days + (r % 3 days));
                vm.roll(block.number + 43_200);
                _feedPrints();
                for (uint256 j; j < 3; ++j) _op(k, (j + r) % 3, (r >> (8 + j)) % 13 == 0);
            }
            for (uint256 j; j < 3; ++j) {
                (,,,,,,,, bool act) = vs[k].plans(ids[j]);
                assertFalse(act, "plan did not finish in 10 steps");
            }
            assertEq(vs[k].totalPrincipal(), 0);
            assertEq(vs[k].totalManagedShares(), 0);
        }
        console.log("max final shortfall (wei)", maxShort);
    }
}
