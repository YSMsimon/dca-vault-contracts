// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransfer} from "../libs/SafeTransfer.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

interface IAToken {
    function scaledBalanceOf(address user) external view returns (uint256);
    function balanceOf(address user) external view returns (uint256);
}

/// @notice Aave V3 yield adapter — the second lending protocol. NOT DEPLOYED:
///         no script in this repository deploys it. The mainnet deploy
///         (Deploy.s.sol) uses MorphoAdapter, and a vault's adapter is
///         immutable. This one is tested against a Base mainnet fork
///         (ForkAdapters.t.sol, ForkHard.t.sol, ForkAdv.t.sol).
/// @dev    Aave REBASES. An aToken balance is `scaled × liquidityIndex` and
///         there is no share token, no `convertToAssets`, nothing an ERC-4626
///         adapter would reach for. The vault's ledger is share-denominated and
///         cannot be anything else, because a pooled balance is never one
///         plan's claim (see IYieldAdapter, which omits `balanceOf()` so that
///         mistake will not compile).
///
///         So the share is Aave's own `scaledBalanceOf`: assets ÷ index, which
///         stays constant while the index grows. Interest shows up as the index
///         moving, never as a share count changing. MockRebasingAdapter proves
///         the same shape against a hostile pool before this one meets a real
///         network.
///
///         WHY A SECOND ADAPTER AT ALL: shipping one to production makes a
///         single vault the single point of failure for every user's idle
///         capital. A second one is meant to exist before the TVL cap is
///         raised.
contract AaveAdapter is IYieldAdapter {
    using SafeTransfer for address;

    /// Aave's fixed-point unit. 1e27, not 1e18.
    uint256 private constant RAY = 1e27;

    IERC20 public immutable usdc;
    IAavePool public immutable pool;
    IAToken public immutable aToken;
    address public immutable vault; // DcaVault

    error OnlyVault();
    error NothingSupplied();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(IERC20 _usdc, IAavePool _pool, IAToken _aToken, address _vault) {
        usdc = _usdc;
        pool = _pool;
        aToken = _aToken;
        vault = _vault;
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

    /// @dev `getReserveNormalizedIncome` is the index including interest accrued
    ///      since the last state-changing touch of the reserve. Reading the
    ///      stored index instead would price a plan's exit at the last time
    ///      somebody else happened to interact with Aave.
    function assetsOf(uint256 shares) public view returns (uint256) {
        return shares * pool.getReserveNormalizedIncome(address(usdc)) / RAY;
    }

    /// @notice What Aave could actually return right now.
    /// @dev    The underlying sitting in the aToken contract IS the free
    ///         liquidity: everything else has been borrowed. Aave short-fills
    ///         nothing — it reverts — so the vault has to ask before it asks.
    function availableLiquidity() external view returns (uint256) {
        return usdc.balanceOf(address(aToken));
    }

    function supply(uint256 assets) external onlyVault returns (uint256 shares) {
        address(usdc).safeTransferFrom(msg.sender, address(this), assets);
        address(usdc).safeApprove(address(pool), assets);

        // MEASURED, not derived. Aave decides what a supply is worth in scaled
        // units, and a re-derivation here would disagree with it by a rounding
        // step on every installment — the same bug the Morpho adapter's
        // withdraw path documents, in the other direction.
        uint256 before = aToken.scaledBalanceOf(address(this));
        pool.supply(address(usdc), assets, address(this), 0);
        shares = aToken.scaledBalanceOf(address(this)) - before;
        if (shares == 0) revert NothingSupplied();
    }

    function withdraw(uint256 assets)
        external
        onlyVault
        returns (uint256 actualAssets, uint256 sharesBurned)
    {
        uint256 beforeScaled = aToken.scaledBalanceOf(address(this));
        actualAssets = pool.withdraw(address(usdc), assets, address(this));
        sharesBurned = beforeScaled - aToken.scaledBalanceOf(address(this));
        address(usdc).safeTransfer(msg.sender, actualAssets);
    }

    function redeem(uint256 shares) external onlyVault returns (uint256 assets) {
        uint256 beforeScaled = aToken.scaledBalanceOf(address(this));

        // type(uint256).max is Aave's "all of it", and it is the only way to
        // exit without leaving dust: asking for assetsOf(shares) rounds, and
        // the remainder is scaled units the ledger has already paid out.
        uint256 want = shares >= beforeScaled ? type(uint256).max : assetsOf(shares);
        assets = pool.withdraw(address(usdc), want, address(this));

        uint256 burned = beforeScaled - aToken.scaledBalanceOf(address(this));
        // The ledger debits by what it asked to burn. If Aave burned more than
        // that, the difference came out of somebody else's plan.
        require(burned <= shares, "burned more than asked");
        address(usdc).safeTransfer(msg.sender, assets);
    }
}
