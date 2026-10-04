// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @dev Minimal ERC20. `decimals` is a constructor arg because the decimal pair
///      that matters here is 8 (B20 stock) against 6 (USDC) — verified on Base,
///      NOT the 18/6 everyone assumes.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) public virtual {
        _mint(to, amt);
    }

    function _mint(address to, uint256 amt) internal {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external virtual returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external virtual returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        _move(f, to, amt);
        return true;
    }

    function _move(address f, address t, uint256 amt) internal virtual {
        balanceOf[f] -= amt;
        balanceOf[t] += amt;
    }
}

/// @notice A deliberately HOSTILE stock token, modelled on B20.
/// @dev    8 decimals, an issuer pause switch, and a transfer blocklist — B20 has
///         all three. Testing against a friendly mock tests a token that does not
///         exist.
contract MockStock is MockERC20 {
    bool public paused;
    mapping(address => bool) public blocked;

    /// @dev Named, because a local deploy needs four of these and a symbol is
    ///      what the UI renders. Defaults are what the single-route tests used.
    constructor(string memory n, string memory sym) MockERC20(n, sym, 8) {}

    function setPaused(bool p) external virtual {
        paused = p;
    }

    function setBlocked(address a, bool b) external virtual {
        blocked[a] = b;
    }

    function _move(address f, address t, uint256 amt) internal override {
        require(!paused, "STOCK_PAUSED");
        require(!blocked[f] && !blocked[t], "STOCK_BLOCKED");
        super._move(f, t, amt);
    }
}

/// @notice The money gate every yield mock shares with the real adapters:
///         only the bound vault may supply, redeem or withdraw.
/// @dev    MorphoAdapter and AaveAdapter have always been `onlyVault`. The
///         mocks were not, and DemoYieldAdapter inherited that — on Base
///         Sepolia any passer-by could `withdraw` every visitor's pooled demo
///         USDC, after which every exit panicked on the mock's share count.
///         The test knobs (share price, liquidity cap, accrual) stay open
///         here; only the functions that move the pooled position are gated.
///
///         Unbound (`vault == 0`) the gate is SHUT, not open. The deployer
///         binds it with `bindVault`; unit tests re-bind one adapter to the
///         several vaults some of them build. DemoYieldAdapter binds at
///         construction to the vault its deploy script predicts and can never
///         be re-bound.
abstract contract VaultBound {
    address public vault;
    address public immutable binder;

    error OnlyVault();
    error NotBinder();

    event VaultSet(address indexed vault);

    constructor() {
        binder = msg.sender;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function bindVault(address v) external virtual {
        if (msg.sender != binder) revert NotBinder();
        vault = v;
        emit VaultSet(v);
    }
}

/// @notice Share-based yield adapter with a settable share price.
/// @dev    `setSharePrice` can go DOWN. A lending adapter that cannot lose value
///         is not a model of a lending market, and the loss path is the one that
///         decides whether exitPlan traps user funds.
contract MockYieldAdapter is IYieldAdapter, VaultBound {
    MockERC20 public immutable usdc;
    uint256 public sharePriceWad = 1e18; // assets per share
    uint256 public totalShares;
    uint256 public liquidityCap = type(uint256).max;

    constructor(MockERC20 _usdc) {
        usdc = _usdc;
    }

    /// @notice Raw share-price set — CAN make the adapter insolvent on purpose,
    ///         which is what the loss-path tests need.
    function setSharePrice(uint256 wad) external virtual {
        sharePriceWad = wad;
    }

    /// @notice Solvent accrual: move the share price AND mint the real assets,
    ///         the way a lending market actually earns. Interest is assets that
    ///         exist, not a number that went up.
    function accrueTo(uint256 wad) external virtual {
        sharePriceWad = wad;
        uint256 owed = assetsOf(totalShares);
        uint256 have = usdc.balanceOf(address(this));
        if (owed > have) usdc.mint(address(this), owed - have);
    }

    function setLiquidityCap(uint256 c) external virtual {
        liquidityCap = c;
    }

    /// @dev Donate straight into the pooled position — the attack that bricks any
    ///      adapter whose accounting is derived from a raw balance.
    function donate(uint256 amt) external {
        usdc.transferFrom(msg.sender, address(this), amt);
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

    function assetsOf(uint256 shares) public view returns (uint256) {
        return shares * sharePriceWad / 1e18;
    }

    function availableLiquidity() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        return bal < liquidityCap ? bal : liquidityCap;
    }

    function supply(uint256 assets) external onlyVault returns (uint256 shares) {
        usdc.transferFrom(msg.sender, address(this), assets);
        shares = assets * 1e18 / sharePriceWad; // rounds DOWN, like ERC-4626
        totalShares += shares;
    }

    function redeem(uint256 shares) external onlyVault returns (uint256 assets) {
        assets = assetsOf(shares);
        require(assets <= availableLiquidity(), "ADAPTER_ILLIQUID");
        totalShares -= shares;
        usdc.transfer(msg.sender, assets);
    }

    function withdraw(uint256 assets) external onlyVault returns (uint256, uint256 sharesBurned) {
        require(assets <= availableLiquidity(), "ADAPTER_ILLIQUID");
        // rounds UP against the caller, exactly like previewWithdraw
        sharesBurned = (assets * 1e18 + sharePriceWad - 1) / sharePriceWad;
        totalShares -= sharesBurned;
        usdc.transfer(msg.sender, assets);
        return (assets, sharesBurned);
    }
}

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public price; // 8 decimals
    mapping(address => uint256) public updatedAt;
    bool public fresh = true;

    function setPrice(address t, uint256 p) external virtual {
        price[t] = p;
        updatedAt[t] = block.timestamp;
    }

    function setFresh(bool f) external virtual {
        fresh = f;
    }

    function latestPrice(address t) external view returns (uint256, uint256) {
        return (price[t], updatedAt[t]);
    }

    function isFresh(address) external view returns (bool) {
        return fresh;
    }

    /// @dev The mock IS the feed for every token it prices, so a route's
    ///      `feed` is this contract's own address.
    function feedOf(address) external view virtual returns (address) {
        return address(this);
    }
}

/// @notice Swap at oracle price, with a settable haircut to simulate impact.
contract MockSwapAdapter is ISwapAdapter {
    MockERC20 public immutable usdc;
    MockStock public immutable stock; // the default route, for the single-route tests
    MockPriceOracle public immutable oracle;
    uint256 public haircutBps;

    constructor(MockERC20 _usdc, MockStock _stock, MockPriceOracle _o) {
        usdc = _usdc;
        stock = _stock;
        oracle = _o;
    }

    function setHaircutBps(uint256 b) external virtual {
        haircutBps = b;
    }

    function poolPrice(address, address t) public view returns (uint256) {
        (uint256 p,) = oracle.latestPrice(t);
        return p * (10_000 + haircutBps) / 10_000;
    }

    function swapExactIn(
        address,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external returns (uint256 amountOut) {
        usdc.transferFrom(msg.sender, address(this), amountIn);
        uint256 px = poolPrice(address(0), tokenOut); // 8dp
        // USDC 6dp -> stock 8dp
        amountOut = amountIn * 1e8 * 1e8 / (px * 1e6);
        require(amountOut >= minOut, "SLIPPAGE");
        MockStock(tokenOut).mint(recipient, amountOut);
    }
}
