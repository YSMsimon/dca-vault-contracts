// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice USDC -> stock token, on one pre-admitted venue.
/// @dev    `minOut` is computed BY THE VAULT from the Chainlink reference and
///         the protocol-capped slippage bound. It is never supplied by the caller —
///         a keeper able to widen its own bound could push the pool to the edge,
///         call executeDCA, and unwind, deterministically, every period.
interface ISwapAdapter {
    /// @param recipient stock tokens go STRAIGHT to the plan owner. The vault
    ///        never holds the stock token: several B20 assets carry transfer
    ///        policies, blocklists and an issuer pause switch, and a blocked
    ///        transfer then reverts the whole execution atomically rather than
    ///        stranding anything.
    function swapExactIn(
        address pool,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external returns (uint256 amountOut);

    /// @notice Spot price from the pool, for the divergence cross-check only.
    function poolPrice(address pool, address tokenOut) external view returns (uint256);
}
