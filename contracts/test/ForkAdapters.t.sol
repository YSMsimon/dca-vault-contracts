// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle, IAggregatorV3} from "../src/adapters/ChainlinkOracle.sol";
import {MorphoAdapter, IERC4626} from "../src/adapters/MorphoAdapter.sol";
import {AaveAdapter, IAavePool, IAToken} from "../src/adapters/AaveAdapter.sol";
import {MockERC20, MockStock, MockPriceOracle, MockSwapAdapter} from "../src/mocks/Mocks.sol";

/// @dev Only the test needs these. MorphoAdapter deliberately does not expose
///      convertToShares — offering it would invite exactly the re-derivation
///      that test_Morpho_WithdrawReturnsSharesActuallyBurned exists to forbid.
interface IMetaMorphoView {
    function convertToShares(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
}

/// @notice The adapters themselves, against the protocols they wrap.
/// @dev    Fork.t.sol asserts the EXTERNAL WORLD is what the design assumed —
///         the feed responds, the Morpho vault exists, the pool is Slipstream.
///         It does not execute a single line of MorphoAdapter or
///         ChainlinkOracle. Until this file existed, every passing test in this
///         repo — the unit suite, 16,384 invariant calls, the whole local
///         end-to-end — ran against MockYieldAdapter. The contracts that will
///         actually hold the money had never been run against Morpho.
///
///         The swap leg stays mocked ON PURPOSE and not for convenience: B20
///         tokens are native precompiles behind a one-byte 0xef stub, so a fork
///         cannot execute them. That leg needs one real mainnet transaction and
///         is tracked as such. Everything else here is real: real USDC, real
///         Gauntlet USDC Prime, real Chainlink NVDA feed.
///
///         Run: BASE_RPC_URL=<an archive Base RPC> forge test --match-path 'contracts/test/ForkAdapters.t.sol'
contract ForkAdaptersTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MORPHO = 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61; // Gauntlet USDC Prime
    address constant FEED = 0x04689a41629776563E6822F76f2e57D148d28513; // Coinbase NVDA
    // Aave V3 on Base — the second lending protocol. aUSDC read off the pool's
    // own getReserveData rather than pasted from a docs page.
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    uint256 constant USDC1 = 1e6;

    ChainlinkOracle oracle;
    MorphoAdapter adapter;
    AaveAdapter aave;
    MockStock stock;
    MockPriceOracle poolOracle;
    MockSwapAdapter swapper;
    DcaVault vault;

    address alice = address(0xA11CE);

    /// @dev PINNED, unlike Fork.t.sol. That file asserts the external world still
    ///      looks the way the design assumed, so it wants live state. This file
    ///      tests OUR code against a known state, where reproducibility matters
    ///      more than freshness — and pinning is also what makes foundry's RPC
    ///      cache work at all: an unpinned fork takes a new latest block every
    ///      run, so nothing is ever a cache hit and each run re-fetches every
    ///      slot MetaMorpho's supply queue touches.
    uint256 constant FORK_BLOCK = 51_628_000;

    function setUp() public {
        // Default to the public endpoint so a fresh clone with a network
        // connection runs these, instead of silently skipping and reporting a
        // green suite that never touched Base. Opting out is EXPLICIT:
        // BASE_RPC_URL=off. Absence is not intent.
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.skip(keccak256(bytes(rpc)) == keccak256("off") || bytes(rpc).length == 0);
        vm.createSelectFork(rpc, FORK_BLOCK);

        oracle = new ChainlinkOracle(address(0), false);

        // The stock leg is a mintable stand-in (see the note above), but it is
        // priced off the REAL NVDA feed, so the reference price and every
        // divergence bound in the vault are live numbers.
        stock = new MockStock("Fork NVDAc", "NVDAc");
        oracle.setFeed(address(stock), FEED);

        // Adapters are bound to the vault, so predict it. +4 because four
        // contracts are deployed before it: both adapters, the pool oracle and
        // the swapper. Adding a deployment here without moving this number is
        // the "prediction" revert.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
        adapter = new MorphoAdapter(IERC20(USDC), IERC4626(MORPHO), predicted);
        aave = new AaveAdapter(IERC20(USDC), IAavePool(AAVE_POOL), IAToken(AUSDC), predicted);
        poolOracle = new MockPriceOracle();
        swapper = new MockSwapAdapter(MockERC20(USDC), stock, poolOracle);

        vault = new DcaVault(IERC20(USDC), adapter, swapper, oracle, 1_000_000 * USDC1);
        require(address(vault) == predicted, "prediction");

        // Price the mock pool at the live feed, so the swap clears at the real
        // NVDA price and the vault's divergence check is exercised for real.
        (uint256 live,) = oracle.latestPrice(address(stock));
        poolOracle.setPrice(address(stock), live);

        vault.initRoute(
            1,
            DcaVault.Route({
                token: address(stock), pool: address(swapper), feed: FEED, dexKind: 0, enabled: true
            })
        );
        vault.finishSetup();

        deal(USDC, alice, 100_000 * USDC1);
        // Foundry 1.8.3 enforces an EOA's ETH balance on pranked calls, so a
        // user funded only in USDC reverts with [0] gas and empty revert data —
        // which reads exactly like a contract bug and is not one.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        IERC20(USDC).approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------- MorphoAdapter, directly
    /// @dev Everything the vault's per-plan ledger is built on: shares in must
    ///      value back to roughly assets in, rounding DOWN and never up.
    // ── Aave V3, the second adapter ──────────────────────────────────────
    //
    // Aave REBASES: an aToken balance is `scaled x index` and there is no share
    // token. MockRebasingAdapter proves the vault's ledger survives that shape;
    // these prove this adapter speaks to the real thing.

    function test_Aave_SupplyMintsScaledSharesThatDoNotMove() public {
        uint256 amt = 10_000 * USDC1;
        deal(USDC, address(vault), amt);

        vm.prank(address(vault));
        IERC20(USDC).approve(address(aave), amt);
        vm.prank(address(vault));
        uint256 shares = aave.supply(amt);

        assertGt(shares, 0, "no scaled balance minted");
        // Aave's index only ever rises, so scaled units buy MORE than a dollar
        // each. A share count equal to the deposit would mean index == RAY,
        // i.e. a reserve that has never earned anything.
        assertLt(shares, amt, "scaled balance should be below assets at index > 1");

        uint256 back = aave.assetsOf(shares);
        assertLe(back, amt, "assetsOf exceeds what was supplied");
        assertGe(back, amt - 2, "lost more than 2 wei to rounding");
        emit log_named_uint("scaled shares for $10,000", shares);
        emit log_named_decimal_uint("assetsOf(shares)", back, 6);
    }

    function test_Aave_InterestArrivesWithoutMintingShares() public {
        uint256 amt = 10_000 * USDC1;
        deal(USDC, address(vault), amt);
        vm.prank(address(vault));
        IERC20(USDC).approve(address(aave), amt);
        vm.prank(address(vault));
        uint256 shares = aave.supply(amt);

        uint256 before = aave.assetsOf(shares);
        vm.warp(block.timestamp + 30 days);

        // The share count is untouched; only the index moved. A ledger storing
        // an asset amount would have to be rewritten on every block.
        assertEq(IAToken(AUSDC).scaledBalanceOf(address(aave)), shares, "a rebase minted shares");
        uint256 after_ = aave.assetsOf(shares);
        assertGt(after_, before, "30 days on Aave earned nothing");
        emit log_named_decimal_uint("real 30d Aave interest on $10,000", after_ - before, 6);
    }

    function test_Aave_WithdrawReturnsSharesActuallyBurned() public {
        uint256 amt = 10_000 * USDC1;
        deal(USDC, address(vault), amt);
        vm.prank(address(vault));
        IERC20(USDC).approve(address(aave), amt);
        vm.prank(address(vault));
        aave.supply(amt);

        uint256 scaledBefore = IAToken(AUSDC).scaledBalanceOf(address(aave));
        vm.prank(address(vault));
        (uint256 got, uint256 burned) = aave.withdraw(1_000 * USDC1);

        assertEq(got, 1_000 * USDC1, "Aave short-filled a request it should meet");
        assertEq(
            scaledBefore - IAToken(AUSDC).scaledBalanceOf(address(aave)),
            burned,
            "reported burn disagrees with the aToken"
        );
        emit log_named_uint("scaled burned for $1,000", burned);
    }

    function test_Aave_OnlyVaultMayMoveMoney() public {
        deal(USDC, alice, 1_000 * USDC1);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(aave), type(uint256).max);
        vm.expectRevert(AaveAdapter.OnlyVault.selector);
        aave.supply(1_000 * USDC1);
        vm.expectRevert(AaveAdapter.OnlyVault.selector);
        aave.withdraw(1);
        vm.stopPrank();
    }

    function test_Aave_AvailableLiquidityIsTheUnborrowedUnderlying() public {
        // Everything not sitting in the aToken contract has been borrowed.
        // Aave reverts rather than short-filling, so the vault has to ask first.
        uint256 free = aave.availableLiquidity();
        assertEq(free, IERC20(USDC).balanceOf(AUSDC), "not reading the aToken's own balance");
        assertGt(free, 100_000 * USDC1, "Aave Base USDC under $100k free - wrong aToken?");
        emit log_named_decimal_uint("Aave free USDC liquidity", free, 6);
    }

    function test_Morpho_SupplyThenAssetsOfRoundsOurWay() public {
        uint256 amt = 10_000 * USDC1;
        deal(USDC, address(vault), amt);

        vm.prank(address(vault));
        IERC20(USDC).approve(address(adapter), amt);
        vm.prank(address(vault));
        uint256 shares = adapter.supply(amt);

        assertGt(shares, 0, "no shares minted");
        uint256 back = adapter.assetsOf(shares);
        assertLe(back, amt, "assetsOf exceeds what was supplied - rounding favours the user");
        assertGe(back, amt - 2, "lost more than 2 wei to rounding");
        emit log_named_uint("shares for $10,000", shares);
        emit log_named_decimal_uint("assetsOf(shares)", back, 6);
    }

    /// @dev THE test this whole file exists for.
    ///
    ///      MorphoAdapter.withdraw returns sharesBurned as the 4626 vault
    ///      actually burned them, and its comment says a re-derivation must
    ///      never be substituted because previewWithdraw rounds UP against us.
    ///      Measured on the live Gauntlet vault, that is exactly true and the
    ///      magnitude is **one share-wei per withdrawal**:
    ///
    ///        convertToShares(1_000e6) = ...050555   <- a naive ledger debit
    ///        previewWithdraw(1_000e6) = ...050556   <- what is really burned
    ///
    ///      One wei sounds ignorable until it is a debit that happens on every
    ///      installment of every plan forever, always in the same direction,
    ///      and always leaving the plan's surviving shares worth less than it
    ///      is owed. This test fails if the adapter ever starts re-deriving.
    function test_Morpho_WithdrawReturnsSharesActuallyBurned() public {
        uint256 amt = 10_000 * USDC1;
        deal(USDC, address(vault), amt);
        vm.prank(address(vault));
        IERC20(USDC).approve(address(adapter), amt);
        vm.prank(address(vault));
        uint256 shares = adapter.supply(amt);

        uint256 assetsBefore = adapter.assetsOf(shares);
        uint256 want = 1_000 * USDC1;

        // What a naive implementation would debit, and what the vault will
        // really burn. Both read BEFORE the withdraw, at the same rate.
        uint256 naive = IMetaMorphoView(MORPHO).convertToShares(want);
        uint256 preview = IMetaMorphoView(MORPHO).previewWithdraw(want);

        vm.prank(address(vault));
        (uint256 got, uint256 burned) = adapter.withdraw(want);

        assertEq(got, want, "withdraw gave a different amount than asked");
        assertEq(burned, preview, "adapter did not return the shares the vault burned");
        assertGe(burned, naive, "previewWithdraw no longer rounds up - re-read the adapter");
        assertLe(burned - naive, 8, "gap is bigger than rounding - the rate moved");

        // The property the vault's per-plan ledger actually rests on: debit
        // `burned` and what survives still covers exactly what is still owed.
        assertEq(
            adapter.assetsOf(shares - burned),
            assetsBefore - want,
            "remaining shares do not cover the remaining principal"
        );
        // And we were not handed assets more cheaply than the shares were worth.
        assertGe(adapter.assetsOf(burned), want, "burned shares were worth less than we took out");

        emit log_named_uint("naive convertToShares  ", naive);
        emit log_named_uint("shares actually burned ", burned);
        emit log_named_uint("per-withdrawal shortfall a re-derivation would cause", burned - naive);
    }

    function test_Morpho_AvailableLiquidityIsOurOwnPosition() public {
        // Before supplying anything, the adapter can withdraw nothing — the
        // $400M+ sitting in the vault is not ours.
        assertEq(adapter.availableLiquidity(), 0, "liquidity before supplying is not ours");

        uint256 amt = 5_000 * USDC1;
        deal(USDC, address(vault), amt);
        vm.prank(address(vault));
        IERC20(USDC).approve(address(adapter), amt);
        vm.prank(address(vault));
        adapter.supply(amt);

        uint256 liq = adapter.availableLiquidity();
        assertGt(liq, 0, "supplied but cannot withdraw");
        assertLe(liq, amt, "maxWithdraw exceeds what we put in");
        emit log_named_decimal_uint("availableLiquidity", liq, 6);
    }

    function test_Morpho_OnlyVaultMayMoveMoney() public {
        deal(USDC, alice, 1_000 * USDC1);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(adapter), type(uint256).max);
        vm.expectRevert(MorphoAdapter.OnlyVault.selector);
        adapter.supply(1_000 * USDC1);
        vm.expectRevert(MorphoAdapter.OnlyVault.selector);
        adapter.redeem(1);
        vm.expectRevert(MorphoAdapter.OnlyVault.selector);
        adapter.withdraw(1);
        vm.stopPrank();
    }

    // ------------------------------------------------ ChainlinkOracle, directly
    function test_Oracle_LivePriceAndFreshness() public view {
        (uint256 px, uint256 ts) = oracle.latestPrice(address(stock));
        assertGt(px, 50e8);
        assertLt(px, 2000e8);
        assertLe(ts, block.timestamp, "feed timestamp is in the future");
        // 24/5 by design, so freshness is whatever the calendar says right now —
        // asserting `true` here would fail every weekend and teach a future
        // reader to delete the test rather than trust it.
        assertEq(oracle.isFresh(address(stock)), block.timestamp - ts <= oracle.HEARTBEAT());
    }

    function test_Oracle_StaleAfterHeartbeat() public {
        (, uint256 ts) = oracle.latestPrice(address(stock));
        vm.warp(ts + oracle.HEARTBEAT() + 1);
        assertFalse(oracle.isFresh(address(stock)), "still fresh past the heartbeat");
    }

    function test_Oracle_UnknownTokenHasNoFeed() public {
        vm.expectRevert(ChainlinkOracle.NoFeed.selector);
        oracle.latestPrice(address(0xBEEF));
        assertFalse(oracle.isFresh(address(0xBEEF)), "isFresh should be false, not revert");
    }

    // -------------------------------------------- the vault on a REAL yield leg
    /// @dev The vault refuses to buy against a stale feed (C5), and a fork's
    ///      feed never prints: after a warp it is stale by construction, and
    ///      the pinned block itself may fall on a weekend. This re-serves the
    ///      real last answer stamped NOW, which is what the live feed does on
    ///      every market day. Only the vault tests use it; the oracle tests
    ///      above read the feed untouched.
    function _feedPrints() internal {
        (uint80 id, int256 answer, uint256 started,, uint80 inRound) =
            IAggregatorV3(FEED).latestRoundData();
        vm.mockCall(
            FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(id, answer, started, block.timestamp, inRound)
        );
    }

    /// @dev The whole mechanism with Morpho underneath instead of a mock: create
    ///      a plan, let real interest accrue, and check the second buy spends
    ///      principal PLUS what the live lending market actually paid.
    function test_Vault_RealMorphoInterestBuysStock() public {
        _feedPrints();
        vm.prank(alice);
        uint256 id = vault.createPlan(1, 10_000 * USDC1, 1_000 * USDC1, 30 days);

        uint256 afterFirst = stock.balanceOf(alice);
        assertGt(afterFirst, 0, "period 1 did not buy");

        (,,, uint256 principal,,,,,) = vault.plans(id);
        assertEq(principal, 9_000 * USDC1, "principal after one slice");
        assertEq(vault.planYield(id), 0, "yield before any time has passed");

        // Real interest, from the real vault, over real elapsed time.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 30 * 43_200); // ~2s blocks on Base
        uint256 accrued = vault.planYield(id);
        assertGt(accrued, 0, "Gauntlet USDC Prime paid nothing over 30 days");
        emit log_named_decimal_uint("real 30d interest on $9,000", accrued, 6);

        _feedPrints();
        vm.prank(alice);
        vault.executeDCA(id);

        uint256 bought = stock.balanceOf(alice) - afterFirst;
        assertGt(bought, afterFirst, "second buy was not larger than the first");
        emit log_named_decimal_uint("period 1 bought", afterFirst, 8);
        emit log_named_decimal_uint("period 2 bought", bought, 8);
    }

    /// @dev Exit has to return principal against a live share price, including
    ///      the rounding remainder that a mock can be written to never produce.
    function test_Vault_ExitAgainstLiveSharePrice() public {
        _feedPrints();
        vm.prank(alice);
        uint256 id = vault.createPlan(1, 10_000 * USDC1, 1_000 * USDC1, 30 days);

        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 7 * 43_200);

        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.exitPlan(id);
        uint256 paid = IERC20(USDC).balanceOf(alice) - before;

        assertGe(paid, 9_000 * USDC1 - 2, "exit returned less than principal");
        assertEq(vault.totalPrincipal(), 0, "principal not cleared");
        emit log_named_decimal_uint("paid out on exit", paid, 6);

        (,,,,,,,, bool active) = vault.plans(id);
        assertFalse(active, "plan still active after exit");
    }
}
