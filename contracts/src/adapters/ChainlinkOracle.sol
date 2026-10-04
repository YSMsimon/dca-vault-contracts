// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function decimals() external view returns (uint8);
}

/// @notice Coinbase B20 equity feeds on Base.
/// @dev    All B20 feeds are 8 decimals, update on a 0.5% deviation or a 24h
///         heartbeat, and are **24/5 by design** — deliberately frozen from
///         Friday close to Monday open. `isFresh` stays TRUE for HEARTBEAT
///         (24h) after the last print, so for the first day of a freeze the
///         vault can still buy against that print. After that it is false,
///         the vault refuses to buy (`StaleOracle`), and the plan waits.
///
///         ADMIN POWERS, stated plainly. The feed a token prices off is what
///         bounds every fill, so swapping it is the same power as swapping the
///         pool. It is therefore:
///           - FIRST listing of a token: instant (`setFeed`). A token with no
///             feed has no route pricing off it — the vault refuses to admit a
///             route whose feed does not match this registry — so there is
///             nothing live for an instant listing to redirect.
///           - CHANGING a listed token's feed: queued (`queueFeed`), and only
///             takes effect after ADMIN_DELAY (48h), in public view, and only
///             within ACTIVATION_WINDOW (7 days) after that. A queued change
///             left dormant expires; it cannot be switched on months later in
///             the same block as a sandwich. Only a LISTED token can have a
///             change queued — first listings go through `setFeed`.
///         The admin is handed over in two steps (`transferAdmin` then
///         `acceptAdmin`) so a typo cannot brick it.
contract ChainlinkOracle is IPriceOracle {
    uint256 public constant HEARTBEAT = 86_400;
    uint64 public constant ADMIN_DELAY = 48 hours;
    uint64 public constant ACTIVATION_WINDOW = 7 days;
    uint8 public constant FEED_DECIMALS = 8;
    /// $100,000,000 a share, 8 decimals: far above any listed equity and far
    /// below anything that can overflow the vault's arithmetic. An answer
    /// above it is garbage, and is treated exactly like a negative one.
    uint256 public constant MAX_PRICE = 1e16;
    /// Bytes of `latestRoundData` return data ever copied: its five words.
    uint256 internal constant ROUND_DATA_SIZE = 160;
    /// @dev Gas given to a feed's latestRoundData. A real Chainlink proxy
    ///      uses under 20k; a feed that needs more reads as not fresh
    ///      instead of burning the caller's transaction.
    uint256 internal constant FEED_GAS = 100_000;

    struct PendingFeed {
        address feed;
        uint64 eta;
    }

    address public admin;
    address public pendingAdmin;
    mapping(address => address) public feedOf; // stock token => aggregator proxy
    mapping(address => PendingFeed) public pendingFeedOf;

    error NoFeed();
    error BadPrice();
    error NotAdmin();
    error NotPendingAdmin();
    error BadFeed();
    error BadDecimals(uint8 decimals);
    error FeedAlreadySet();
    error NothingQueued();
    error TimelockActive(uint64 eta);
    error QueueExpired(uint64 deadline);

    event FeedSet(address indexed token, address indexed feed);
    event FeedQueued(address indexed token, address indexed feed, uint64 eta);
    event FeedCancelled(address indexed token);
    event AdminTransferStarted(address indexed current, address indexed pending);
    event AdminTransferred(address indexed previous, address indexed current);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
        emit AdminTransferred(address(0), msg.sender);
    }

    // ------------------------------------------------------------- admin
    function transferAdmin(address next) external onlyAdmin {
        pendingAdmin = next;
        emit AdminTransferStarted(admin, next);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin || msg.sender == address(0)) revert NotPendingAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }

    /// @notice List a token for the first time. Instant, because nothing can
    ///         be priced off a token until it has a feed.
    function setFeed(address token, address feed) external onlyAdmin {
        if (feedOf[token] != address(0)) revert FeedAlreadySet();
        _checkFeed(feed);
        feedOf[token] = feed;
        emit FeedSet(token, feed);
    }

    /// @notice Propose a new feed for an already-listed token.
    /// @dev    An unlisted token has nothing to change: it is listed with
    ///         `setFeed`. Queueing one used to succeed and sit there as a
    ///         dormant entry that meant nothing until a later `setFeed`.
    function queueFeed(address token, address feed) external onlyAdmin {
        if (feedOf[token] == address(0)) revert NoFeed();
        _checkFeed(feed);
        uint64 eta = uint64(block.timestamp) + ADMIN_DELAY;
        pendingFeedOf[token] = PendingFeed({feed: feed, eta: eta});
        emit FeedQueued(token, feed, eta);
    }

    function activateFeed(address token) external onlyAdmin {
        PendingFeed memory q = pendingFeedOf[token];
        if (q.eta == 0) revert NothingQueued();
        if (block.timestamp < q.eta) revert TimelockActive(q.eta);
        uint64 deadline = q.eta + ACTIVATION_WINDOW;
        if (block.timestamp > deadline) revert QueueExpired(deadline);
        _checkFeed(q.feed);
        delete pendingFeedOf[token];
        feedOf[token] = q.feed;
        emit FeedSet(token, q.feed);
    }

    function cancelFeed(address token) external onlyAdmin {
        if (pendingFeedOf[token].eta == 0) revert NothingQueued();
        delete pendingFeedOf[token];
        emit FeedCancelled(token);
    }

    /// @dev Every B20 feed is 8 decimals and the vault's math assumes it. A
    ///      feed with any other scale would misprice every fill by powers of 10.
    function _checkFeed(address feed) internal view {
        if (feed == address(0) || feed.code.length == 0) revert BadFeed();
        uint8 d = IAggregatorV3(feed).decimals();
        if (d != FEED_DECIMALS) revert BadDecimals(d);
    }

    // ------------------------------------------------------------- reads
    /// @dev Rejects everything `_read` rejects: a feed that reverts or answers
    ///      short, a round id that is not a uint80, a non-positive answer or
    ///      one above MAX_PRICE, a round that never updated (`updatedAt == 0`)
    ///      and a timestamp from the future. Staleness is NOT rejected here —
    ///      that is `isFresh`'s job, and the vault asks it first.
    function latestPrice(address token) external view returns (uint256 price, uint256 updatedAt) {
        address f = feedOf[token];
        if (f == address(0)) revert NoFeed();
        bool ok;
        (ok, price, updatedAt) = _read(f);
        if (!ok) revert BadPrice();
    }

    /// @dev True for HEARTBEAT (24h) after the feed's last print and false
    ///      after that. So on a weekend it is still true for the first 24h
    ///      after Friday's close, and false from then until Monday's first
    ///      print. False for ANY answer `latestPrice` would reject: the two
    ///      share `_read`, so `isFresh` true means `latestPrice` answers.
    ///      They used to decode differently, and a feed with an out-of-range
    ///      round id read as fresh here and then reverted there, inside
    ///      `createPlan`'s first buy.
    ///
    ///      NEVER REVERTS: a feed that reverts (deprecated, paused,
    ///      access-controlled), answers garbage, or returns a megabyte reads as
    ///      not fresh. `createPlan` asks this before its first buy, so a
    ///      revert here would block deposits, not just executions.
    function isFresh(address token) external view returns (bool) {
        address f = feedOf[token];
        if (f == address(0)) return false;
        (bool ok,, uint256 ts) = _read(f);
        return ok && block.timestamp - ts <= HEARTBEAT;
    }

    /// @dev ONE reader for both views. Low-level and in assembly so that at
    ///      most ROUND_DATA_SIZE bytes are ever copied, however much the feed
    ///      returns (a return-data bomb used to run `isFresh` out of gas in
    ///      the copy), and so that malformed data is a `false`, never a revert.
    ///      Each word is range-checked the way a typed decode would, and more:
    ///        roundId, answeredInRound  fit in uint80
    ///        answer                    in (0, MAX_PRICE]
    ///        updatedAt                 nonzero and not in the future
    ///      `startedAt` is not read.
    function _read(address f) internal view returns (bool ok, uint256 price, uint256 ts) {
        bytes4 sel = IAggregatorV3.latestRoundData.selector;
        uint256 roundId;
        int256 answer;
        uint256 answeredIn;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sel)
            ok := staticcall(FEED_GAS, f, p, 0x04, p, ROUND_DATA_SIZE)
            ok := and(ok, iszero(lt(returndatasize(), ROUND_DATA_SIZE)))
            if ok {
                roundId := mload(p)
                answer := mload(add(p, 0x20))
                ts := mload(add(p, 0x60))
                answeredIn := mload(add(p, 0x80))
            }
        }
        if (!ok) return (false, 0, 0);
        if (roundId > type(uint80).max || answeredIn > type(uint80).max) return (false, 0, 0);
        if (answer <= 0 || uint256(answer) > MAX_PRICE) return (false, 0, 0);
        if (ts == 0 || ts > block.timestamp) return (false, 0, 0);
        return (true, uint256(answer), ts);
    }
}
