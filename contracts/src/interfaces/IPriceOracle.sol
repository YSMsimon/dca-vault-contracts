// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Reference price for a route's stock token, quoted in USDC terms.
/// @dev    The reference is a Chainlink B20 equity feed, NOT a TWAP of the pool
///         being swapped in: a pool cannot police itself, and it is cheapest to
///         manipulate exactly when its book is thinnest.
///
///         Coinbase B20 feeds are 8 decimals, 24/5, and update on a 0.5%
///         deviation or a 24h heartbeat. The 24/5 window is load-bearing: the
///         feed is KNOWINGLY frozen from Friday close to Monday open. A stale
///         feed makes an execution revert `StaleOracle` and the plan waits for
///         the next fresh update. What counts as stale is the implementation's
///         to say. ChainlinkOracle's rule: more than one heartbeat (24h) since
///         the last print, the L2 sequencer down or just restarted, and, when
///         it is deployed with the weekend rule, all of Saturday 00:00 to
///         Monday 01:00 UTC. So on a freeze that is NOT a weekend the vault
///         can still buy against the last print for its first 24h. See
///         docs/threat-model.md, *Stale feeds*.
interface IPriceOracle {
    /// @return price     stock price, 8 decimals
    /// @return updatedAt feed timestamp
    function latestPrice(address token) external view returns (uint256 price, uint256 updatedAt);

    /// @notice Whether the price may be bought against right now: the feed
    ///         updated within its heartbeat, and nothing else the
    ///         implementation checks says otherwise.
    function isFresh(address token) external view returns (bool);

    /// @notice The aggregator this oracle reads for `token`, or zero.
    /// @dev    The vault checks a route's `feed` against this when the route is
    ///         admitted, so the registry cannot claim one feed while the price
    ///         comes from another.
    function feedOf(address token) external view returns (address);
}
