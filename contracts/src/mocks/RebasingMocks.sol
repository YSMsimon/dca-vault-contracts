// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {MockERC20, VaultBound} from "./Mocks.sol";

/// @notice A lending pool with NO shares — the balance itself grows.
/// @dev    This is the shape Aave V3 actually has. An aToken balance is
///         `scaled * liquidityIndex`, and what the holder sees is a number that
///         goes up on its own; there is no `convertToAssets`, no share token,
///         nothing for a ledger to hold on to.
///
///         MockYieldAdapter is ERC-4626-shaped and therefore proves nothing
///         about that case: it hands out shares, so the vault's per-plan ledger
///         has something real to store. This one does not, and exists to prove
///         the IYieldAdapter abstraction survives a backend that never heard of
///         a share.
contract MockRebasingPool {
    MockERC20 public immutable usdc;

    /// Ray, like Aave. 1e27, not 1e18 — the precision matters when a scaled
    /// balance is divided by it on every single supply.
    uint256 public constant RAY = 1e27;
    uint256 public index = RAY;

    mapping(address => uint256) public scaledBalanceOf;
    uint256 public totalScaled;
    uint256 public liquidityCap = type(uint256).max;

    constructor(MockERC20 _usdc) {
        usdc = _usdc;
    }

    /// @notice What the holder appears to own right now.
    function balanceOf(address who) public view returns (uint256) {
        return scaledBalanceOf[who] * index / RAY;
    }

    /// @notice Solvent accrual: raise the index AND mint the assets to back it.
    /// @dev    Multiplies the CURRENT index rather than setting it, so calling
    ///         this twice compounds the way time does. Setting absolutely meant
    ///         a second call at a lower figure silently took money away.
    function accrue(uint256 growthWad) external {
        index = index * growthWad / 1e18;
        uint256 owed = totalScaled * index / RAY;
        uint256 have = usdc.balanceOf(address(this));
        if (owed > have) usdc.mint(address(this), owed - have);
    }

    /// @notice A loss. The index falls and no assets are minted.
    function slash(uint256 shrinkWad) external {
        index = index * shrinkWad / 1e18;
    }

    function setLiquidityCap(uint256 c) external {
        liquidityCap = c;
    }

    function supply(uint256 assets) external {
        usdc.transferFrom(msg.sender, address(this), assets);
        uint256 scaled = assets * RAY / index;
        scaledBalanceOf[msg.sender] += scaled;
        totalScaled += scaled;
    }

    /// @notice Aave semantics: you ask in ASSETS and it short-fills at the cap.
    function withdraw(uint256 assets) external returns (uint256 sent) {
        uint256 avail = usdc.balanceOf(address(this));
        if (avail > liquidityCap) avail = liquidityCap;
        sent = assets < avail ? assets : avail;

        uint256 scaled = sent * RAY / index;
        // Round the scaled debit UP so a withdraw can never leave the caller
        // holding scaled units it has already been paid for.
        if (scaled * index / RAY < sent) scaled += 1;
        if (scaled > scaledBalanceOf[msg.sender]) scaled = scaledBalanceOf[msg.sender];

        scaledBalanceOf[msg.sender] -= scaled;
        totalScaled -= scaled;
        usdc.transfer(msg.sender, sent);
    }

    function available() external view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        return bal < liquidityCap ? bal : liquidityCap;
    }
}

/// @notice IYieldAdapter over a pool that has no shares.
/// @dev    THE ABSTRACTION PROOF. The vault's ledger is share-denominated and
///         cannot be anything else — a pooled balance is never one plan's claim
///         ([[IYieldAdapter]] says why at length). So the share has to be
///         manufactured here, and the only honest way is the pool's own scaled
///         unit: `assets * RAY / index`, which is constant while the index
///         grows. That is exactly what Aave's `scaledBalanceOf` is, which is
///         why this mock is a true stand-in for AaveAdapter rather than a
///         convenient fiction.
///
///         The hostile part: the pool short-fills, the index can fall, and
///         nothing here is allowed to read a raw balance.
contract MockRebasingAdapter is IYieldAdapter, VaultBound {
    MockERC20 public immutable usdc;
    MockRebasingPool public immutable pool;

    constructor(MockERC20 _usdc, MockRebasingPool _pool) {
        usdc = _usdc;
        pool = _pool;
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

    function assetsOf(uint256 shares) public view returns (uint256) {
        return shares * pool.index() / pool.RAY();
    }

    function availableLiquidity() external view returns (uint256) {
        return pool.available();
    }

    function supply(uint256 assets) external onlyVault returns (uint256 shares) {
        usdc.transferFrom(msg.sender, address(this), assets);
        usdc.approve(address(pool), assets);

        // Measured, not derived. The pool decides how much scaled balance a
        // supply is worth, and asking it afterwards is the only thing that
        // stays true if it ever rounds differently than this contract would.
        uint256 before = pool.scaledBalanceOf(address(this));
        pool.supply(assets);
        shares = pool.scaledBalanceOf(address(this)) - before;
    }

    function withdraw(uint256 assets)
        external
        onlyVault
        returns (uint256 actualAssets, uint256 sharesBurned)
    {
        uint256 beforeScaled = pool.scaledBalanceOf(address(this));
        actualAssets = pool.withdraw(assets);
        sharesBurned = beforeScaled - pool.scaledBalanceOf(address(this));
        usdc.transfer(msg.sender, actualAssets);
    }

    function redeem(uint256 shares) external onlyVault returns (uint256 assets) {
        uint256 want = assetsOf(shares);
        uint256 beforeScaled = pool.scaledBalanceOf(address(this));
        assets = pool.withdraw(want);
        // The caller asked to burn an exact share count; if the pool short-fills
        // it burned fewer, and the ledger has to hear the truth. Exits use this
        // path, so an optimistic answer here is an overpayment.
        uint256 burned = beforeScaled - pool.scaledBalanceOf(address(this));
        require(burned <= shares, "burned more than asked");
        usdc.transfer(msg.sender, assets);
    }
}
