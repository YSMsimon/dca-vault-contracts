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
