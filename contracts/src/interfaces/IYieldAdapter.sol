// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Share-denominated lending adapter.
/// @dev    Every call is share-denominated ON PURPOSE. There is deliberately NO
///         argument-less `balanceOf()`: the vault holds ONE pooled position per
///         adapter shared by every plan, so a pooled balance is never any single
///         plan's claim. An earlier draft of this interface exposed `balanceOf()`
///         and two design notes then specified `balanceOf() - remainingPrincipal`
///         as the yield base — under which the first user to exit drains the
///         accrued interest of everyone else. That bug is invisible in any
///         single-plan test. Omitting the function makes it uncompilable.
interface IYieldAdapter {
    /// @param  assets USDC to supply
    /// @return shares minted to the vault for THIS supply
    function supply(uint256 assets) external returns (uint256 shares);

    /// @notice Burn an exact share count. Preferred for exits — never leaves dust
    ///         shares whose value the ledger has already paid out.
    function redeem(uint256 shares) external returns (uint256 assets);

    /// @notice Withdraw an exact asset amount.
    /// @return actualAssets received, and sharesBurned as the adapter ACTUALLY
    ///         burned them. Callers MUST debit their ledger by `sharesBurned` and
    ///         never by a re-derived `convertToShares` — ERC-4626 rounds
    ///         `previewWithdraw` UP against the caller, so a re-derivation leaves
    ///         the plan's surviving shares worth less than it is owed, compounding
    ///         over every installment.
    function withdraw(uint256 assets) external returns (uint256 actualAssets, uint256 sharesBurned);

    /// @notice Current asset value of a share count.
    function assetsOf(uint256 shares) external view returns (uint256);

    /// @notice Assets this adapter could actually return right now.
    /// @dev    MetaMorpho REVERTS rather than short-filling when its withdraw
    ///         queue cannot satisfy a request, so the vault asks this first.
    ///         MorphoAdapter answers with MetaMorpho's own `maxWithdraw()`,
    ///         which v1.x computes against its withdraw queue.
    ///         Morpho Vaults V2 hardcodes `maxWithdraw()` to 0, so an adapter
    ///         for a V2 vault would have to walk the queue itself.
    function availableLiquidity() external view returns (uint256);

    function asset() external view returns (address);
}
