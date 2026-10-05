// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransfer} from "../libs/SafeTransfer.sol";

/// @dev Aerodrome Slipstream is a Uniswap-v3 fork: same swap signature, same
///      callback name, same slot0 layout, same price oracle (`observe`).
interface ICLPool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice USDC -> B20 stock on a pre-admitted Aerodrome Slipstream pool.
/// @dev    Swaps against the pool directly with the v3 callback rather than
///         through a router: one fewer trusted address, and the pool is already
///         pinned per route in the registry.
///
///         The stock token goes STRAIGHT to the plan owner. The vault is never
///         a holder, which is what makes B20's transfer policies, blocklist and
///         issuer pause switch survivable — a blocked transfer reverts the whole
///         execution atomically instead of stranding anything.
contract AerodromeSwapAdapter is ISwapAdapter {
    using SafeTransfer for address;
    uint160 internal constant MIN_SQRT = 4295128740;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;
    /// Seconds of the pool's own price history the push check looks back
    /// over (`_assertNotPushed`).
    uint32 public constant TWAP_WINDOW = 300;
    /// That history is read as TWAP_WINDOW / TWAP_STEP consecutive averages
    /// of this many seconds each: five one-minute averages.
    uint32 public constant TWAP_STEP = 60;
    /// How far the pool's spot tick may sit from ANY of those averages. A
    /// tick is a factor of 1.0001, one basis point, so this is about 1%.
    int24 public constant MAX_TWAP_DRIFT = 100;

    IERC20 public immutable usdc;
    address public immutable vault;

    error OnlyVault();
    error BadCallback();
    error Slippage(uint256 got, uint256 minOut);
    error WrongPool();
    error AmountTooLarge();
    error WrongInput(uint256 paid, uint256 expected);
    /// The pool's spot is more than MAX_TWAP_DRIFT ticks from one of its
    /// own TWAP_STEP averages over the last TWAP_WINDOW seconds. `twapTick`
    /// is the average furthest from the spot.
    error PoolPushed(int24 spotTick, int24 twapTick);
    /// The pool has no observation TWAP_WINDOW old, answered the wrong
    /// number of cumulatives, or answered an average that is not a tick.
    error NoPriceHistory();

    // solc 0.8.26 has no `transient` for value types. Both are set just before
    // the pool is called and cleared INSIDE the callback, before it pays: the
    // callback is one-shot, and a swap whose callback never ran reverts.
    address private _activePool;
    uint256 private _expectedIn;

    constructor(IERC20 _usdc, address _vault) {
        usdc = _usdc;
        vault = _vault;
    }

    /// @dev What the POOL says it did is not evidence. A pool that reports a
    ///      huge output and sends nothing would otherwise pass any `minOut`, so
    ///      the output is MEASURED as the recipient's balance change, and the
    ///      input is pinned twice: the callback may collect exactly `amountIn`,
    ///      and the pool's reported input delta must equal it. A partial fill
    ///      (the price limit hit before `amountIn` was consumed) reverts instead
    ///      of leaving USDC stranded in this contract.
    function swapExactIn(
        address pool,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external returns (uint256 amountOut) {
        if (msg.sender != vault) revert OnlyVault();
        if (amountIn > uint256(type(int256).max)) revert AmountTooLarge();
        address(usdc).safeTransferFrom(msg.sender, address(this), amountIn);

        bool zeroForOne = _assertPair(pool, tokenOut);
        // Before the swap: after it, the spot is this trade's own doing.
        _assertNotPushed(pool);
        uint256 before = IERC20(tokenOut).balanceOf(recipient);
        _activePool = pool;
        _expectedIn = amountIn;
        (int256 a0, int256 a1) = ICLPool(pool)
            .swap(
                recipient,
                zeroForOne,
                int256(amountIn), // exact input
                zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1,
                abi.encode(pool)
            );
        // Still armed means the pool never collected: whatever it reports,
        // the USDC is sitting here, so the swap did not happen.
        if (_activePool != address(0)) revert BadCallback();

        int256 inDelta = zeroForOne ? a0 : a1;
        if (inDelta != int256(amountIn)) {
            revert WrongInput(inDelta > 0 ? uint256(inDelta) : 0, amountIn);
        }

        uint256 after_ = IERC20(tokenOut).balanceOf(recipient);
        amountOut = after_ > before ? after_ - before : 0;
        if (amountOut < minOut) revert Slippage(amountOut, minOut);
    }

    /// @dev The route pins the pool, but assert the pair anyway: a mis-entered
    ///      route must not silently buy some other asset on a schedule.
    function _assertPair(address pool, address tokenOut) internal view returns (bool zeroForOne) {
        address t0 = ICLPool(pool).token0();
        address t1 = ICLPool(pool).token1();
        if (t0 == address(usdc) && t1 == tokenOut) return true;
        if (t1 == address(usdc) && t0 == tokenOut) return false;
        revert WrongPool();
    }

    /// @dev THE PUSH CHECK. The vault's breaker compares the pool's SPOT
    ///      price with the feed, and spot is whatever the last swap left
    ///      behind: a caller can move it inside the band, execute a buy at
    ///      the moved price and unwind, all in one transaction. So the spot
    ///      must also agree with the pool's OWN recent history: with each of
    ///      its five TWAP_STEP (60 s) averages over the last TWAP_WINDOW
    ///      (300 s), to within MAX_TWAP_DRIFT ticks.
    ///
    ///      Why a push of more than MAX_TWAP_DRIFT in this transaction or
    ///      block cannot pass. A v3 pool
    ///      writes at most one observation per block, before the first swap
    ///      of that block that moves the tick, and from the tick it had
    ///      BEFORE that swap. `observe(.., 0)` answers with that observation,
    ///      or, when nothing has moved the tick in this block, extrapolates
    ///      from the last one. Either way a swap in this transaction or this
    ///      block is in none of the averages, so the push shows up whole as
    ///      drift.
    ///
    ///      WHAT IT DOES NOT STOP. Each average is a mean of TICKS, so what
    ///      moves it is tick-seconds, not time: a pool left 15,000 ticks off
    ///      for one 2-second block moves a 60 s average 500 ticks, the same
    ///      as a pool held 500 ticks off for the whole minute. A single
    ///      300 s average could be moved the same 500 ticks by ONE block at
    ///      75,000 ticks. Five separate averages can still be moved, in two
    ///      ways:
    ///        - fast: an off-market block inside EACH of the five minutes,
    ///          the first of them more than four minutes before the buy.
    ///          Each leaves the attacker's own capital in the pool across a
    ///          block boundary where anyone may trade against it. A push
    ///          left standing across the boundary between two minutes
    ///          counts in both, so three pushes can do it; the pool is
    ///          off-market for five blocks in all either way.
    ///        - slow: ONE push to the target, left standing for nearly the
    ///          whole window, which moves all five averages to it. One
    ///          round trip of pool fees, as before, and the capital is
    ///          exposed for minutes instead of seconds.
    ///      So this changes the shape of the attack and what it exposes the
    ///      attacker to. It is not a proof, and it is not a higher floor on
    ///      fees: an attacker with capital whom nobody trades against for
    ///      five minutes still passes. The bound on what passing is worth
    ///      is `minOut`, taken from the feed. The vault's breaker reads the
    ///      pushed spot and does not tighten it.
    ///
    ///      The band is on where the spot ENDS, not on how far it was moved:
    ///      after an honest move to one edge of the band, a push to the
    ///      other edge passes, which is a move of up to twice the band.
    ///
    ///      What it costs. A pool that honestly moves more than
    ///      MAX_TWAP_DRIFT reverts too, and the buy waits for a retry, up to
    ///      TWAP_WINDOW after the pool stops moving; a pool that keeps
    ///      trending is refused for as long as it does. A pool with no
    ///      observation
    ///      TWAP_WINDOW old cannot be bought from at all (`NoPriceHistory`):
    ///      a route's pool needs enough observation cardinality to always
    ///      cover the window.
    function _assertNotPushed(address pool) internal view {
        (int24 spot, int24 low, int24 high) = _ticks(pool);
        // In int256: the difference of two int24 cannot overflow there.
        // low <= high, so at most one of these is the larger drift.
        int256 above = int256(spot) - int256(low); // spot over the lowest mean
        int256 below = int256(high) - int256(spot); // spot under the highest
        if (above > MAX_TWAP_DRIFT || below > MAX_TWAP_DRIFT) {
            revert PoolPushed(spot, above >= below ? low : high);
        }
    }

    /// @dev The spot tick, and the lowest and the highest of the pool's
    ///      TWAP_STEP mean ticks over the last TWAP_WINDOW. The spot is
    ///      within MAX_TWAP_DRIFT of every mean exactly when it is within it
    ///      of these two.
    ///
    ///      Each mean is computed the way Uniswap's OracleLibrary.consult
    ///      computes it: the difference of two tick cumulatives over the
    ///      step, rounded toward NEGATIVE infinity. Solidity's division
    ///      truncates toward zero, which for a negative mean is one tick too
    ///      high, and the pools this adapter trades sit at negative ticks.
    ///
    ///      What reverts `NoPriceHistory`: `observe` reverting (a pool whose
    ///      oldest observation is younger than the window reverts "OLD"),
    ///      the wrong number of cumulatives, or a mean outside int24. What
    ///      does NOT: return data that does not decode as the two arrays
    ///      fails OUTSIDE the catch and reverts bare, and a `slot0` that
    ///      reverts bubbles up as it is. All of these revert the buy either
    ///      way, and only a contract that is not a v3 pool can produce them.
    function _ticks(address pool) internal view returns (int24 spot, int24 low, int24 high) {
        (, spot,,,,) = ICLPool(pool).slot0();
        uint256 steps = TWAP_WINDOW / TWAP_STEP;
        uint32[] memory ago = new uint32[](steps + 1);
        // ago = [300, 240, 180, 120, 60, 0]: oldest first, the last is now.
        for (uint256 i; i < steps; ++i) {
            ago[i] = TWAP_WINDOW - uint32(i) * TWAP_STEP;
        }
        try ICLPool(pool).observe(ago) returns (int56[] memory cum, uint160[] memory) {
            if (cum.length != steps + 1) revert NoPriceHistory();
            int256 step = int256(uint256(TWAP_STEP));
            int256 lo = type(int256).max;
            int256 hi = type(int256).min;
            for (uint256 i; i < steps; ++i) {
                // In int256, where neither the subtraction nor the rounding
                // step can overflow, whatever the pool answered.
                int256 delta = int256(cum[i + 1]) - int256(cum[i]);
                int256 mean = delta / step;
                if (delta < 0 && delta % step != 0) mean--;
                if (mean < lo) lo = mean;
                if (mean > hi) hi = mean;
            }
            // A real pool's ticks are within +-887272. A mean outside int24
            // is not a price, and the casts below would silently truncate it.
            if (lo < type(int24).min || hi > type(int24).max) revert NoPriceHistory();
            low = int24(lo);
            high = int24(hi);
        } catch {
            revert NoPriceHistory();
        }
    }

    /// @notice The pool's spot tick, and the lowest and highest of its five
    ///         one-minute mean ticks over the last TWAP_WINDOW seconds: the
    ///         numbers `swapExactIn` compares before it swaps. A buy goes
    ///         through only while `spot - low` and `high - spot` are both at
    ///         most MAX_TWAP_DRIFT.
    /// @dev    For a keeper or an interface that wants to ask first. It is
    ///         the same read the swap makes, and reverts exactly when the
    ///         swap's read would.
    function ticks(address pool) external view returns (int24 spot, int24 low, int24 high) {
        return _ticks(pool);
    }

    /// @dev Called back by the pool mid-swap to collect the input. ONE-SHOT:
    ///      the arming is cleared before paying, so a pool that calls back a
    ///      second time (to sweep stray USDC sitting in this contract) finds
    ///      `_activePool == 0` and reverts.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata)
        external
    {
        address pool = _activePool;
        uint256 expected = _expectedIn;
        if (pool == address(0) || msg.sender != pool) revert BadCallback();
        _activePool = address(0);
        _expectedIn = 0;
        uint256 owed = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        if (owed != expected) revert WrongInput(owed, expected);
        address(usdc).safeTransfer(msg.sender, owed);
    }

    /// @notice Spot price from the pool, 8dp, for the divergence cross-check only.
    /// @dev    Never the price the fill is bounded against — a pool cannot police
    ///         itself, and it is cheapest to manipulate when its book is thinnest.
    function poolPrice(address pool, address) external view returns (uint256) {
        (uint160 sqrtP,,,,,) = ICLPool(pool).slot0();
        if (sqrtP >= (uint256(1) << 128)) return 0; // sqrtP^2 would overflow
        bool usdcIsToken0 = ICLPool(pool).token0() == address(usdc);

        // sqrtP^2 / 2^192 = rawPrice (token1 raw units per token0 raw unit).
        // Carry it as Q128 to keep precision: ratioX128 = rawPrice * 2^128.
        uint256 ratioX128 = (uint256(sqrtP) * uint256(sqrtP)) >> 64;

        // Decimal bridge: USDC is 6dp, B20 stock is 8dp (VERIFIED on Base — not
        // the 18 everyone assumes), and this returns an 8dp USD price.
        //   stock is token0 : usd8 = rawPrice * 10^(8-6) * 1e8 = rawPrice * 1e10
        //   usdc  is token0 : usd8 = (1/rawPrice) * 1e10
        if (ratioX128 == 0) return 0;
        if (usdcIsToken0) return ((uint256(1) << 128) * 1e10) / ratioX128;
        return (ratioX128 * 1e10) >> 128;
    }
}
