// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransfer} from "../libs/SafeTransfer.sol";

/// @dev Aerodrome Slipstream is a Uniswap-v3 fork: same swap signature, same
///      callback name, same slot0 layout.
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

    IERC20 public immutable usdc;
    address public immutable vault;

    error OnlyVault();
    error BadCallback();
    error Slippage(uint256 got, uint256 minOut);
    error WrongPool();
    error AmountTooLarge();
    error WrongInput(uint256 paid, uint256 expected);

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
