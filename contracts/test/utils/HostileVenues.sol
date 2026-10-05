// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DcaVault} from "../../src/DcaVault.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {SafeTransfer} from "../../src/libs/SafeTransfer.sol";
import {MockERC20, MockStock, MockPriceOracle} from "../../src/mocks/Mocks.sol";

/// @notice Constant-product pool that is ALSO the swap adapter; `poolPrice`
///         is its spot. From the 2026-09-28 hard test (Repros.t.sol).
contract CpammSwap is ISwapAdapter {
    MockERC20 public usdc;
    MockStock public stock;
    uint256 public ru; // USDC reserve, 6dp
    uint256 public rs; // stock reserve, 8dp

    constructor(MockERC20 u, MockStock s, uint256 _ru, uint256 _rs) {
        usdc = u;
        stock = s;
        ru = _ru;
        rs = _rs;
        u.mint(address(this), _ru);
        s.mint(address(this), _rs);
    }

    function poolPrice(address, address) public view returns (uint256) {
        return ru * 1e10 / rs;
    }

    function _buy(uint256 a, address to) internal returns (uint256 out) {
        out = rs * a / (ru + a);
        ru += a;
        rs -= out;
        stock.transfer(to, out);
    }

    function swapExactIn(address, address, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 out)
    {
        usdc.transferFrom(msg.sender, address(this), amountIn);
        out = _buy(amountIn, to);
        require(out >= minOut, "SLIPPAGE");
    }

    function buy(uint256 a) external returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), a);
        return _buy(a, msg.sender);
    }

    function sell(uint256 s) external returns (uint256 out) {
        stock.transferFrom(msg.sender, address(this), s);
        out = ru * s / (rs + s);
        rs += s;
        ru -= out;
        usdc.transfer(msg.sender, out);
    }
}

/// @notice Atomic push-execute-unwind, callable by anyone once grace has passed.
contract Sandwicher {
    function run(DcaVault v, CpammSwap p, MockERC20 u, MockStock s, uint256 id, uint256 push)
        external
    {
        u.approve(address(p), type(uint256).max);
        s.approve(address(p), type(uint256).max);
        uint256 got = p.buy(push);
        v.executeDCA(id);
        p.sell(got);
    }
}

/// @notice A Slipstream-shaped pool that lies. `mode`:
///         0 — collects exactly amountIn, sends nothing, REPORTS a huge output
///         1 — asks the callback for one wei more than amountIn
///         2 — honest: collects amountIn, sends `payout` of the stock
///         3 — never calls back, sends `payout`, reports a full fill
///         4 — calls back TWICE (to sweep stray USDC), sends `payout`
contract FakeClPool {
    address public token0;
    address public token1;
    uint8 public mode;
    uint256 public payout;

    constructor(address usdc, address tok, uint8 m, uint256 p) {
        token0 = usdc;
        token1 = tok;
        mode = m;
        payout = p;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (uint160(uint256(1) << 96) * 10, 0, 0, 0, 0, true);
    }

    /// It lies about its fills, not about its history: tick 0 for as long as
    /// anyone asks, which is the tick `slot0` reports. So the adapter's push
    /// check passes and each mode reaches the check it is here to break.
    function observe(uint32[] calldata ago)
        external
        pure
        returns (int56[] memory cum, uint160[] memory spl)
    {
        cum = new int56[](ago.length);
        spl = new uint160[](ago.length);
    }

    function swap(address recipient, bool, int256 amountSpecified, uint160, bytes calldata)
        external
        returns (int256, int256)
    {
        int256 ask = mode == 1 ? amountSpecified + 1 : amountSpecified;
        uint256 calls = mode == 3 ? 0 : mode == 4 ? 2 : 1;
        for (uint256 i; i < calls; ++i) {
            (bool ok, bytes memory err) = msg.sender.call(
                abi.encodeWithSignature(
                    "uniswapV3SwapCallback(int256,int256,bytes)", ask, int256(0), ""
                )
            );
            if (!ok) {
                assembly {
                    revert(add(err, 32), mload(err))
                }
            }
        }
        if (mode >= 2) MockStock(token1).mint(recipient, payout);
        return (amountSpecified, -int256(1e30)); // "you got a lot"
    }
}

/// @notice A Slipstream-shaped pool with a working price oracle: the two v3
///         behaviours AerodromeSwapAdapter's push check rests on.
///           - It writes at most one observation per block timestamp, BEFORE
///             the tick moves, from the tick it had.
///           - `observe` interpolates between observations, extrapolates from
///             the last one with the current tick, and reverts "OLD" for a
///             time before its first.
///         The price follows the tick (1.0001^tick, token1 per token0, raw
///         units), so `slot0`, the fill and the average tell one story.
///         `push` stands in for somebody else's swap: it moves the tick, and
///         costs the caller nothing, which is the attacker's best case.
/// @dev    Good for ticks within about +-100,000; the fixed-point power
///         below overflows far outside that.
contract TwapClPool {
    struct Obs {
        uint32 ts;
        int56 cum;
    }

    address public immutable token0;
    address public immutable token1;
    address internal immutable usdc;
    address internal immutable stock;
    int24 public tick;
    Obs[] internal obs;

    constructor(address usdc_, address stock_, bool usdcIsToken0, int24 tick_) {
        (token0, token1) = usdcIsToken0 ? (usdc_, stock_) : (stock_, usdc_);
        usdc = usdc_;
        stock = stock_;
        tick = tick_;
        obs.push(Obs(uint32(block.timestamp), 0));
    }

    /// Somebody's swap moved the price to `to`.
    function push(int24 to) external {
        Obs memory last = obs[obs.length - 1];
        uint32 nowTs = uint32(block.timestamp);
        if (last.ts != nowTs) {
            obs.push(Obs(nowTs, last.cum + int56(tick) * int56(uint56(nowTs - last.ts))));
        }
        tick = to;
    }

    function observationCount() external view returns (uint256) {
        return obs.length;
    }

    /// The raw observations, oldest first: when each was written, and the
    /// tick-seconds counted up to then. For a test that redoes the adapter's
    /// arithmetic by itself instead of trusting `observe` (Round6b.t.sol).
    function observation(uint256 i) external view returns (uint32 ts, int56 cum) {
        Obs memory o = obs[i];
        return (o.ts, o.cum);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        uint16 n = uint16(obs.length);
        return (uint160(_sqrt(_ratioWad() * 1e18) * (uint256(1) << 96) / 1e18), tick, n - 1, n, n, true);
    }

    function observe(uint32[] calldata ago)
        external
        view
        returns (int56[] memory cum, uint160[] memory spl)
    {
        cum = new int56[](ago.length);
        spl = new uint160[](ago.length);
        for (uint256 i; i < ago.length; ++i) {
            require(ago[i] <= block.timestamp, "OLD");
            cum[i] = _cumAt(uint32(block.timestamp) - ago[i]);
        }
    }

    function _cumAt(uint32 t) internal view returns (int56) {
        uint256 n = obs.length;
        Obs memory last = obs[n - 1];
        if (t >= last.ts) return last.cum + int56(tick) * int56(uint56(t - last.ts));
        require(t >= obs[0].ts, "OLD");
        for (uint256 i = n - 1; i > 0; --i) {
            Obs memory a = obs[i - 1];
            if (a.ts <= t) {
                Obs memory b = obs[i];
                return a.cum + (b.cum - a.cum) / int56(uint56(b.ts - a.ts)) * int56(uint56(t - a.ts));
            }
        }
        revert("OLD");
    }

    /// Exact USDC in, stock out, at the tick's price. The fill itself moves
    /// nothing: the trades these tests make are small against the pool.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(zeroForOne == (token0 == usdc) && amountSpecified > 0, "mock: exact USDC in only");
        uint256 r = _ratioWad();
        uint256 paid = uint256(amountSpecified);
        uint256 out = token0 == usdc ? paid * r / 1e18 : paid * 1e18 / r;
        MockStock(stock).mint(recipient, out);
        (amount0, amount1) =
            zeroForOne ? (amountSpecified, -int256(out)) : (-int256(out), amountSpecified);
        uint256 before = MockERC20(usdc).balanceOf(address(this));
        (bool ok, bytes memory err) = msg.sender.call(
            abi.encodeWithSignature(
                "uniswapV3SwapCallback(int256,int256,bytes)", amount0, amount1, data
            )
        );
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
        require(MockERC20(usdc).balanceOf(address(this)) >= before + paid, "IIA");
    }

    /// 1.0001^tick, 18 decimals: token1 per token0 in raw units.
    function _ratioWad() internal view returns (uint256 r) {
        int24 t = tick;
        uint256 n = uint256(int256(t < 0 ? -t : t));
        uint256 b = 1.0001e18;
        r = 1e18;
        while (n != 0) {
            if (n & 1 == 1) r = r * b / 1e18;
            n >>= 1;
            if (n != 0) b = b * b / 1e18;
        }
        if (t < 0) r = 1e36 / r;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 k = (x + 1) / 2;
        while (k < z) {
            z = k;
            k = (x / k + k) / 2;
        }
    }
}

/// @notice A pool-shaped thing whose `observe` answers whatever it was told
///         to, whatever it is asked: six chosen cumulatives (what the adapter
///         expects for its six offsets), an array of any other length, or a
///         revert. For the adapter's arithmetic, away from any real history.
///         It has no `swap`: a buy that gets past the push check dies there.
contract RawObservePool {
    address public token0;
    address public token1;
    int24 public tick;
    int56[] internal cum;
    bool public reverts;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function set(int24 spot, int56[] calldata cumulatives, bool reverts_) external {
        tick = spot;
        cum = cumulatives;
        reverts = reverts_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (uint160(uint256(1) << 96), tick, 0, 1, 1, true);
    }

    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory) {
        require(!reverts, "OLD");
        return (cum, new uint160[](cum.length));
    }
}

/// @notice A Chainlink aggregator whose every field is settable.
contract FakeFeed {
    int256 public answer = 1e8;
    uint256 public updatedAt;
    uint8 public decimals = 8;
    bool public live = true; // updatedAt tracks block.timestamp

    function set(int256 a, uint256 ts, bool follow) external {
        answer = a;
        updatedAt = ts;
        live = follow;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 ts = live ? block.timestamp : updatedAt;
        return (1, answer, ts, ts, 1);
    }
}

/// @notice USDC with a blocklist, like Circle's. A blocked address can
///         neither send nor receive.
contract BlockableUSDC is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("USD Coin", "USDC", 6) {}

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _move(address f, address t, uint256 amt) internal override {
        require(!blocked[f] && !blocked[t], "BLOCKLISTED");
        super._move(f, t, amt);
    }
}

/// @notice Exposes the library so a test can call it against any address.
contract SafeTransferHarness {
    using SafeTransfer for address;

    function transfer(address token, address to, uint256 amt) external {
        token.safeTransfer(to, amt);
    }

    function transferFrom(address token, address from, address to, uint256 amt) external {
        token.safeTransferFrom(from, to, amt);
    }

    function approve(address token, address spender, uint256 amt) external {
        token.safeApprove(spender, amt);
    }
}

/// @notice A price oracle whose `feedOf` answers a settable address, for the
///         route-vs-registry check.
contract RegistryOracle is MockPriceOracle {
    mapping(address => address) public feedFor;

    function setFeedFor(address token, address feed) external {
        feedFor[token] = feed;
    }

    function feedOf(address token) external view override returns (address) {
        return feedFor[token];
    }
}
