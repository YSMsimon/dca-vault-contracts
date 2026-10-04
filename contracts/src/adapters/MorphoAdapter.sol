// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransfer} from "../libs/SafeTransfer.sol";

interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @notice MetaMorpho (ERC-4626) yield adapter.
/// @dev    Pinned to Gauntlet USDC Prime on Base
///         (0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61). As of 2026-09-21:
///         $416M TVL, 4.42% net APY, and verified to hold ZERO allocation to
///         B20 stock-collateral markets.
///
///         That last point is the whole reason for pinning rather than chasing
///         yield. On the same date Steakhouse High Yield USDC v1.1 paid 5.30%
///         and held 3.2% in AAPLc/GOOGLc/METAc/NVDAc collateral markets: the
///         day NVDA gaps on earnings, utilisation spikes on exactly those
///         markets and that is the vault that cannot return the money — while
///         this protocol is trying to buy the asset that just gapped.
///
///         Only the vault may call the mutating functions: this adapter holds a
///         single pooled position whose shares the vault ledgers per plan.
contract MorphoAdapter is IYieldAdapter {
    using SafeTransfer for address;
    IERC20 public immutable usdc;
    IERC4626 public immutable vault4626;
    address public immutable vault; // DcaVault

    error OnlyVault();
    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(IERC20 _usdc, IERC4626 _v, address _vault) {
        usdc = _usdc;
        vault4626 = _v;
        vault = _vault;
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

    function assetsOf(uint256 shares) public view returns (uint256) {
        return vault4626.convertToAssets(shares);
    }

    /// @dev The pinned vault (Gauntlet USDC Prime) is MetaMorpho v1.0.
    ///      MetaMorpho V1.x implements maxWithdraw against the withdraw queue, so
    ///      it is a real liquidity probe here. Morpho Vaults V2 hardcodes it to 0
    ///      as a conservative legal value — if this is ever repointed at a V2
    ///      vault, this function MUST be replaced with a withdraw-queue walk.
    function availableLiquidity() public view returns (uint256) {
        return vault4626.maxWithdraw(address(this));
    }

    function supply(uint256 assets) external onlyVault returns (uint256 shares) {
        address(usdc).safeTransferFrom(msg.sender, address(this), assets);
        address(usdc).safeApprove(address(vault4626), assets);
        shares = vault4626.deposit(assets, address(this));
    }

    function redeem(uint256 shares) external onlyVault returns (uint256 assets) {
        assets = vault4626.redeem(shares, msg.sender, address(this));
    }

    /// @dev Returns sharesBurned AS THE VAULT ACTUALLY BURNED THEM. The caller
    ///      must debit its ledger by this number and never by a re-derived
    ///      convertToShares: previewWithdraw rounds UP against us, so a
    ///      re-derivation leaves the plan's surviving shares worth less than it
    ///      is owed, compounding over every installment.
    function withdraw(uint256 assets) external onlyVault returns (uint256, uint256 sharesBurned) {
        sharesBurned = vault4626.withdraw(assets, msg.sender, address(this));
        return (assets, sharesBurned);
    }
}
