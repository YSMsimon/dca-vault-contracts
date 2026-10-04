// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISwapAdapter} from "./interfaces/ISwapAdapter.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeTransfer} from "./libs/SafeTransfer.sol";

/// @title  DcaVault
/// @notice Scheduled purchases of tokenized equities, funded by a single USDC
///         deposit whose un-invested remainder earns lending yield — and that
///         yield is spent on the same stock, not paid out as cash.
///
/// @dev    WHAT THIS CONTRACT HOLDS: USDC, and adapter shares. Never the stock
///         token. Every purchase is sent straight to the plan owner, so a B20
///         pause switch or transfer blocklist reverts the whole execution
///         atomically instead of stranding anything, and the vault never needs
///         to be an eligible holder of a transfer-restricted asset.
///
///         TRUST MODEL, stated plainly (docs/threat-model.md has the long form):
///         - Your stock is in your own wallet. Nothing to trust.
///         - Your un-invested cash sits in a POOLED lending position, tracked by
///           the per-plan share ledger below. That ledger is the custody model.
///         - Every fill is bounded against the CHAINLINK reference, not the
///           pool: it receives at least `(1 - maxSlippageBps)` of what the
///           feed says the USDC is worth. Whoever picks the block — keeper,
///           owner, or a stranger after `grace` — can cost the plan at most
///           that, and nothing else.
///         - The admin cannot move funds or touch `exitPlan`. Re-pointing a
///           route is impossible (a route's token and pool are fixed forever);
///           enabling one, changing its feed, or LOOSENING the fill bounds
///           waits ADMIN_DELAY (48h) in public view, and a queued change that
///           is not activated within ACTIVATION_WINDOW (7 days) of its eta
///           expires. Disabling a route and tightening the bounds are instant.
///         - Deposits are paused from the constructor. `finishSetup` closes
///           the instant setup window (`initRoute`, instant loosening), once,
///           and opens deposits in the same step, unless the admin paused
///           them during setup (the mainnet deploy does): then they stay shut
///           until `setDepositsPaused(false)`.
contract DcaVault {
    using SafeTransfer for address;
    // --------------------------------------------------------------- errors
    error NotOwner();
    error NotYetDue();
    error PlanInactive();
    error TooEarlyForPublicCall();
    error StaleOracle();
    error PoolDiverged(uint256 refPrice, uint256 poolPrice);
    error InsufficientAdapterLiquidity(uint256 requested, uint256 available);
    error RouteDisabled();
    error CapExceeded();
    error BadParams();
    error Paused();
    error Reentrant();
    error NotPendingAdmin();
    error SetupClosed();
    error RouteImmutable();
    error FeedMismatch();
    error NothingQueued();
    error TimelockActive(uint64 eta);
    error LedgerOverdraw(uint256 burned, uint256 held);
    error SlippageExceeded(uint256 out, uint256 minOut);
    error QueueExpired(uint64 deadline);
    error BadTokenDecimals(uint256 decimals);
    error SetupOpen();

    // --------------------------------------------------------------- types
    struct Route {
        address token; // EXACT issuer address. A vanity prefix is not authentication.
        address pool;
        /// The feed AT ADMISSION: checked against `oracle.feedOf(token)` when
        /// the route is initialised or activated, and never read after that.
        /// The oracle can rotate a token's feed behind its own delay without
        /// touching this record, so it can go stale. Anything that wants the
        /// feed a fill is priced off RIGHT NOW reads `oracle.feedOf(token)`.
        address feed;
        uint8 dexKind;
        bool enabled;
    }

    /// @dev Flat rather than `{Route route; uint64 eta}` so the public getter
    ///      returns every field.
    struct PendingRoute {
        address token;
        address pool;
        address feed;
        uint8 dexKind;
        bool enabled;
        uint64 eta;
    }

    /// A LOOSENING of the fill bounds, waiting out ADMIN_DELAY.
    struct PendingBounds {
        uint16 maxSlippageBps;
        uint16 maxDeviationBps;
        uint64 eta;
    }

    struct Plan {
        address owner;
        uint32 routeId;
        uint256 installment; // USDC per period
        uint256 remainingPrincipal; // USDC still owed to the owner
        uint256 yieldShares; // THIS plan's claim on the pooled position
        uint64 nextExecution;
        uint64 interval;
        uint32 completedPeriods;
        bool active;
    }

    // ------------------------------------------------------------ constants
    /// Route and feed changes wait this long in public view.
    uint64 public constant ADMIN_DELAY = 48 hours;
    /// A queued change may be activated only in [eta, eta + ACTIVATION_WINDOW].
    /// After that it has expired and must be queued again, with fresh notice.
    /// Without this, a change queued once and left visibly dormant could be
    /// switched on a year later in the same block as whatever it enables.
    uint64 public constant ACTIVATION_WINDOW = 7 days;
    /// Every stock the vault prices is 8 decimals (B20, verified on Base). The
    /// `minOut` math and the swap adapter's pool price both assume it.
    uint8 public constant STOCK_DECIMALS = 8;
    /// Before a stranger may call executeDCA on a due plan.
    uint64 public constant grace = 12 hours;
    /// 1 USDC. A 1-wei installment would let one plan hold the TVL cap forever.
    uint256 public constant MIN_INSTALLMENT = 1e6;
    uint256 public constant MAX_PERIODS = 120;
    uint64 public constant MIN_INTERVAL = 1 days;
    uint64 public constant MAX_INTERVAL = 366 days;
    /// Hard ceilings on the admin's knobs, so the bound users rely on is a
    /// number in the bytecode rather than a promise.
    uint16 public constant MAX_SLIPPAGE_BPS = 200;
    uint16 public constant MAX_DEVIATION_BPS = 2000;
    uint16 public constant MAX_FEE_BPS = 1000;
    /// Gas for the `decimals()` probe in `_checkRoute`. An ERC-20 answers in
    /// under 3k; the cap is there because an unrunnable token burns all of it.
    uint256 internal constant DECIMALS_GAS = 50_000;
    /// @dev The code of a Coinbase B20 stock token on Base: one `0xef` byte,
    ///      backed by a precompile. The only token whose `decimals()` may be
    ///      unreadable here, because forge's and anvil's EVMs cannot run it.
    bytes32 internal constant B20_STUB_CODEHASH = keccak256(hex"ef");

    // --------------------------------------------------------------- state
    IERC20 public immutable usdc;
    IYieldAdapter public immutable adapter;
    ISwapAdapter public immutable swapper;
    IPriceOracle public immutable oracle;

    address public admin;
    address public pendingAdmin;
    address public feeRecipient;
    uint16 public feeBps; // on ACCRUED YIELD only. 0 at launch.
    /// THE bound on every fill, against the Chainlink reference. Covers the
    /// pool's premium over the feed AND the trade's own impact.
    uint16 public maxSlippageBps = 100;
    /// Circuit breaker: reference vs pool spot. Catches a dislocated pool
    /// before the swap is even attempted.
    uint16 public maxDeviationBps = 500;
    /// Contract-enforced cap on OUTSTANDING principal (deposits not yet spent
    /// or withdrawn), not on cumulative deposits. A UI cap is not a cap.
    uint256 public tvlCap;
    uint256 public totalPrincipal;
    /// TRUE FROM CONSTRUCTION. Deposits cannot open before `finishSetup`, so
    /// no plan can exist while the instant setup verbs are still live.
    bool public depositsPaused;
    /// The setup window: `initRoute` and instant LOOSENING of the bounds work
    /// only while this is false. `finishSetup` sets it, once, for good.
    bool public setupFinished;
    /// @dev Set when the admin pauses deposits during setup, so that
    ///      `finishSetup` keeps them paused instead of silently opening them.
    bool internal _pausedInSetup;
    /// Fees owed to `feeRecipient`, held here until `claimFees`. Accruing
    /// rather than pushing means a blocklisted recipient can never block an
    /// exit or an execution.
    uint256 public feesAccrued;

    uint256 public totalManagedShares; // never derived from a balance delta
    mapping(uint32 => Route) public routes;
    mapping(uint32 => PendingRoute) public pendingRoutes;
    PendingBounds public pendingBounds;
    mapping(uint256 => Plan) public plans;
    uint256 public nextPlanId = 1;

    /// @notice Keepers may execute a due plan without waiting out `grace`.
    /// @dev    This is not a privilege over the money. The vault computes
    ///         `minOut` itself from the Chainlink reference and its own
    ///         slippage bound, so an allowlisted keeper picking the block can
    ///         extract no more than the owner could. `grace` exists to stop
    ///         ANYONE holding that option from block zero, not to delay the
    ///         one bot whose whole job is to be on time.
    mapping(address => bool) public keepers;

    uint256 private _lock = 1;

    // --------------------------------------------------------------- events
    // The first six are decoded by the indexer and the web app. Their
    // signatures are a contract with those readers: do not change them.
    event PlanCreated(uint256 indexed id, address indexed owner, uint32 routeId, uint256 deposit);
    event DCAExecuted(
        uint256 indexed id, uint256 slice, uint256 accrued, uint256 stockOut, uint256 fee
    );
    event PlanExited(uint256 indexed id, uint256 paidOut, uint256 shortfall);
    event PlanCompleted(uint256 indexed id, uint32 periods);
    event RouteSet(uint32 indexed routeId, address token, address pool, bool enabled);
    event KeeperSet(address indexed keeper, bool allowed);

    event RouteQueued(
        uint32 indexed routeId, address token, address pool, address feed, bool enabled, uint64 eta
    );
    event RouteCancelled(uint32 indexed routeId);
    event AdminTransferStarted(address indexed current, address indexed pending);
    event AdminTransferred(address indexed previous, address indexed current);
    event FeeSet(uint16 bps);
    event FeeRecipientSet(address indexed recipient);
    event BoundsSet(uint16 maxSlippageBps, uint16 maxDeviationBps);
    event BoundsQueued(uint16 maxSlippageBps, uint16 maxDeviationBps, uint64 eta);
    event BoundsCancelled();
    event TvlCapSet(uint256 cap);
    event DepositsPausedSet(bool paused);
    event FeesClaimed(address indexed recipient, uint256 amount);
    /// Principal a plan could not get back from the lending leg — a loss the
    /// plan absorbed rather than a revert.
    event PlanShortfall(uint256 indexed id, uint256 shortfall);
    /// The setup window closed. Deposits opened with it unless they were
    /// paused during setup: the DepositsPausedSet emitted next says which.
    event SetupFinished();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2;
        _;
        _lock = 1;
    }
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotOwner();
        _;
    }

    constructor(IERC20 _usdc, IYieldAdapter _a, ISwapAdapter _s, IPriceOracle _o, uint256 _tvlCap) {
        usdc = _usdc;
        adapter = _a;
        swapper = _s;
        oracle = _o;
        admin = msg.sender;
        feeRecipient = msg.sender;
        tvlCap = _tvlCap;
        // Paused until `finishSetup`. With deposits open from block zero, a
        // stranger's createPlan could land between two `initRoute`s of a
        // multi-transaction deploy and shut the setup window on the rest.
        depositsPaused = true;
        emit AdminTransferred(address(0), msg.sender);
        emit TvlCapSet(_tvlCap);
        emit DepositsPausedSet(true);
    }

    // ----------------------------------------------------------- admin
    /// @notice Two-step handover: the new admin must accept, so a typo cannot
    ///         strand the role.
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

    /// @notice Initial configuration, instant, and ONLY before `finishSetup`.
    ///         The deploy script uses this to list the launch routes in the
    ///         same broadcast that creates the vault.
    /// @dev    Instant is safe here because there is nothing to protect yet:
    ///         deposits are paused from the constructor and cannot be opened
    ///         until `finishSetup`, so no plan and no deposit can exist while
    ///         this works. The window used to close on the first `createPlan`,
    ///         which let anyone close it in the middle of a deploy. Now it is
    ///         closed explicitly, by the admin, once. Everything a user can see
    ///         before depositing is what the timelock then protects.
    function initRoute(uint32 id, Route calldata r) external onlyAdmin {
        if (setupFinished) revert SetupClosed();
        _checkRoute(id, r);
        routes[id] = r;
        emit RouteSet(id, r.token, r.pool, r.enabled);
    }

    /// @notice Propose a route, or re-enable one. Takes effect via
    ///         `activateRoute` no sooner than ADMIN_DELAY from now.
    /// @dev    A route id's token and pool can never change once set — a new
    ///         venue is a new route id — so the only things a queued change can
    ///         do to an existing route are flip `enabled` and follow a feed the
    ///         oracle has itself rotated behind its own delay.
    function queueRoute(uint32 id, Route calldata r) external onlyAdmin {
        _checkRoute(id, r);
        uint64 eta = uint64(block.timestamp) + ADMIN_DELAY;
        pendingRoutes[id] = PendingRoute({
            token: r.token,
            pool: r.pool,
            feed: r.feed,
            dexKind: r.dexKind,
            enabled: r.enabled,
            eta: eta
        });
        emit RouteQueued(id, r.token, r.pool, r.feed, r.enabled, eta);
    }

    function activateRoute(uint32 id) external onlyAdmin {
        PendingRoute memory q = pendingRoutes[id];
        _checkWindow(q.eta);
        Route memory r = Route({
            token: q.token, pool: q.pool, feed: q.feed, dexKind: q.dexKind, enabled: q.enabled
        });
        // Re-checked: the oracle's feed may have moved in the last 48h.
        _checkRoute(id, r);
        delete pendingRoutes[id];
        routes[id] = r;
        emit RouteSet(id, r.token, r.pool, r.enabled);
    }

    /// @notice Ends the setup window. Once, for good: after this, routes are
    ///         enabled only through the queue and a loosening of the bounds
    ///         waits ADMIN_DELAY. It also opens deposits, unless the admin
    ///         paused them during setup (the mainnet deploy does): then they
    ///         stay shut until `setDepositsPaused(false)`. Every deploy script
    ///         makes it its last vault call.
    function finishSetup() external onlyAdmin {
        if (setupFinished) revert SetupClosed();
        setupFinished = true;
        // Opens deposits, unless the admin paused them on purpose during
        // setup: that pause is kept, and lifted later with setDepositsPaused.
        bool keep = _pausedInSetup;
        depositsPaused = keep;
        emit SetupFinished();
        emit DepositsPausedSet(keep);
    }

    function cancelRoute(uint32 id) external onlyAdmin {
        if (pendingRoutes[id].eta == 0) revert NothingQueued();
        delete pendingRoutes[id];
        emit RouteCancelled(id);
    }

    /// @notice Instant. A compromised admin can stop the protocol, not
    ///         redirect it.
    /// @dev    Also drops anything queued for this route. A disable is an
    ///         incident response; a re-enable queued BEFORE the incident must
    ///         not be able to undo it without fresh notice.
    function disableRoute(uint32 id) external onlyAdmin {
        Route storage r = routes[id];
        r.enabled = false;
        emit RouteSet(id, r.token, r.pool, false);
        if (pendingRoutes[id].eta != 0) {
            delete pendingRoutes[id];
            emit RouteCancelled(id);
        }
    }

    /// @dev A queued entry is live only in [eta, eta + ACTIVATION_WINDOW].
    function _checkWindow(uint64 eta) internal view {
        if (eta == 0) revert NothingQueued();
        if (block.timestamp < eta) revert TimelockActive(eta);
        uint64 deadline = eta + ACTIVATION_WINDOW;
        if (block.timestamp > deadline) revert QueueExpired(deadline);
    }

    function _checkRoute(uint32 id, Route memory r) internal view {
        if (r.token == address(0) || r.pool == address(0)) revert BadParams();
        Route storage cur = routes[id];
        if (cur.token != address(0) && (cur.token != r.token || cur.pool != r.pool)) {
            revert RouteImmutable();
        }
        if (r.feed == address(0) || oracle.feedOf(r.token) != r.feed) revert FeedMismatch();
        // An 18-decimal stock would be priced 1e10 off by `_minOut` and by
        // the pool-price bridge. Refuse it here, by name, WHEN THIS EVM CAN
        // ASK:
        //   - no code at all: refused (reads as 0).
        //   - `decimals()` answers: the answer must be 8.
        //   - `decimals()` cannot be read here: accepted ONLY for the B20
        //     stub (code is the single byte `0xef`). On Base that stub is
        //     backed by a precompile forge's and anvil's EVMs cannot run, so
        //     the call fails in simulation and the mainnet deploy used to die
        //     in `forge script`. Any other unreadable token is refused: with
        //     a pushed pool, a wrong-decimals token would otherwise fill at a
        //     wrong price inside the slippage bound (round-4 re-test).
        // Bounded gas (the stub burns all it is given) and a bounded copy
        // (at most one word of return data, so no return-data bomb).
        if (r.token.code.length == 0) revert BadTokenDecimals(0);
        address t = r.token;
        bytes4 sel = IERC20.decimals.selector;
        bool ok;
        uint256 d;
        assembly ("memory-safe") {
            mstore(0x00, sel)
            ok := staticcall(DECIMALS_GAS, t, 0x00, 0x04, 0x00, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 0x20)))
            d := mload(0x00)
        }
        if (ok) {
            if (d != STOCK_DECIMALS) revert BadTokenDecimals(d);
        } else if (t.codehash != B20_STUB_CODEHASH) {
            // Unreadable is only excused for the B20 stub. Any other token
            // that will not say it is 8 decimals is refused: the pool-price
            // backstop only holds while the pool is honestly priced.
            revert BadTokenDecimals(0);
        }
    }

    function setFee(uint16 bps) external onlyAdmin {
        if (bps > MAX_FEE_BPS) revert BadParams();
        feeBps = bps;
        emit FeeSet(bps);
    }

    function setFeeRecipient(address r) external onlyAdmin {
        if (r == address(0)) revert BadParams();
        feeRecipient = r;
        emit FeeRecipientSet(r);
    }

    /// @notice TIGHTENING (neither bound goes up) is instant: it can only
    ///         make fills safer or make executions wait. LOOSENING either
    ///         bound is queued behind ADMIN_DELAY, like a route change,
    ///         because a wider slippage bound is exactly what a sandwich
    ///         needs. Before `finishSetup` no deposit can exist, so, like
    ///         `initRoute`, it is instant then.
    /// @dev    A queued loosening replaces any earlier one and is applied
    ///         with `activateBounds` inside its activation window.
    ///
    ///         An instant change DROPS any queued loosening. A tightening is
    ///         an incident response, and a loosening queued before the
    ///         incident must not be able to undo it at its eta without fresh
    ///         notice — the same rule `disableRoute` applies to a queued
    ///         re-enable.
    function setBounds(uint16 slippage, uint16 deviation) external onlyAdmin {
        if (slippage > MAX_SLIPPAGE_BPS || deviation > MAX_DEVIATION_BPS) revert BadParams();
        if (!setupFinished || (slippage <= maxSlippageBps && deviation <= maxDeviationBps)) {
            _applyBounds(slippage, deviation);
            if (pendingBounds.eta != 0) {
                delete pendingBounds;
                emit BoundsCancelled();
            }
            return;
        }
        uint64 eta = uint64(block.timestamp) + ADMIN_DELAY;
        pendingBounds =
            PendingBounds({maxSlippageBps: slippage, maxDeviationBps: deviation, eta: eta});
        emit BoundsQueued(slippage, deviation, eta);
    }

    function activateBounds() external onlyAdmin {
        PendingBounds memory q = pendingBounds;
        _checkWindow(q.eta);
        delete pendingBounds;
        _applyBounds(q.maxSlippageBps, q.maxDeviationBps);
    }

    function cancelBounds() external onlyAdmin {
        if (pendingBounds.eta == 0) revert NothingQueued();
        delete pendingBounds;
        emit BoundsCancelled();
    }

    function _applyBounds(uint16 slippage, uint16 deviation) internal {
        maxSlippageBps = slippage;
        maxDeviationBps = deviation;
        emit BoundsSet(slippage, deviation);
    }

    function setTvlCap(uint256 c) external onlyAdmin {
        tvlCap = c;
        emit TvlCapSet(c);
    }

    /// @dev Deposits cannot be opened while the setup window is: that is
    ///      what keeps `initRoute` and instant loosening away from any plan.
    function setDepositsPaused(bool p) external onlyAdmin {
        if (!p && !setupFinished) revert SetupOpen();
        if (!setupFinished) _pausedInSetup = true;
        depositsPaused = p;
        emit DepositsPausedSet(p);
    }

    function setKeeper(address k, bool allowed) external onlyAdmin {
        keepers[k] = allowed;
        emit KeeperSet(k, allowed);
    }

    /// @notice Pays accrued fees to the current recipient. Anyone may call it;
    ///         the destination is not theirs to choose.
    function claimFees() external nonReentrant {
        uint256 amount = feesAccrued;
        if (amount == 0) return;
        feesAccrued = 0;
        address to = feeRecipient;
        address(usdc).safeTransfer(to, amount);
        emit FeesClaimed(to, amount);
    }

    // ----------------------------------------------------------- create
    function createPlan(uint32 routeId, uint256 deposit, uint256 installment, uint64 interval)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (depositsPaused) revert Paused();
        Route memory r = routes[routeId];
        if (!r.enabled) revert RouteDisabled();
        // ceil(deposit / installment) <= MAX_PERIODS, written so it cannot overflow.
        if (
            installment < MIN_INSTALLMENT || installment > deposit
                || (deposit - 1) / installment >= MAX_PERIODS || interval < MIN_INTERVAL
                || interval > MAX_INTERVAL
        ) {
            revert BadParams();
        }
        // Outstanding principal, not cumulative deposits. Written so a cap
        // lowered below the current total cannot underflow.
        if (totalPrincipal > tvlCap || deposit > tvlCap - totalPrincipal) revert CapExceeded();

        address(usdc).safeTransferFrom(msg.sender, address(this), deposit);
        totalPrincipal += deposit;

        id = nextPlanId++;
        plans[id] = Plan({
            owner: msg.sender,
            routeId: routeId,
            installment: installment,
            remainingPrincipal: deposit,
            yieldShares: 0,
            nextExecution: uint64(block.timestamp),
            interval: interval,
            completedPeriods: 0,
            active: true
        });
        emit PlanCreated(id, msg.sender, routeId, deposit);

        _supply(id, deposit);
        // Period 1 fires immediately — unless the feed is stale (no print for
        // 24h, which is most of a weekend), in which case the plan is created
        // already due and is bought at the next fresh print. Reverting instead
        // would make the deposit button fail every weekend for no protective
        // gain. For the first 24h after the last print the feed still reads
        // fresh, and this buy runs against that print.
        if (oracle.isFresh(r.token)) _execute(id);
    }

    // ----------------------------------------------------------- execute
    /// @dev Owner first, then the keeper allowlist (via admin), then anyone once
    ///      the grace window has passed.
    function executeDCA(uint256 id) external nonReentrant {
        Plan storage p = plans[id];
        if (!p.active) revert PlanInactive();
        if (block.timestamp < p.nextExecution) revert NotYetDue();
        if (
            msg.sender != p.owner && !keepers[msg.sender]
                && block.timestamp < uint256(p.nextExecution) + grace
        ) {
            revert TooEarlyForPublicCall();
        }
        _execute(id);
    }

    /// @dev Two paths, and neither can Panic.
    ///
    ///      A normal slice withdraws `installment + accrued` and debits the
    ///      shares the adapter says it burned.
    ///
    ///      The FINAL slice — or any slice the plan's shares can no longer
    ///      cover, after a loss — redeems EVERY share the plan holds and spends
    ///      whatever comes back. Withdrawing an exact asset amount rounds the
    ///      share burn UP, so after any loss or rounding drift the last exact
    ///      withdraw asks for more shares than the plan has; that used to be a
    ///      0x11 Panic on every retry, forever. Redeeming the whole position
    ///      cannot overdraw, and what did not come back is a shortfall the
    ///      plan absorbs and reports, never a revert.
    function _execute(uint256 id) internal {
        Plan storage p = plans[id];
        Route memory r = routes[p.routeId];
        if (!r.enabled) revert RouteDisabled();

        (uint256 principalOut, uint256 got) = _draw(p);
        uint256 accruedOut = got > principalOut ? got - principalOut : 0;
        uint256 shortfall = got < principalOut ? principalOut - got : 0;
        uint256 fee = accruedOut * feeBps / 10_000;

        // EFFECTS BEFORE INTERACTIONS. nonReentrant already blocks direct
        // re-entry, but the swap is the one call reaching an admitted venue,
        // so the plan is fully advanced before it runs.
        p.remainingPrincipal -= principalOut;
        totalPrincipal -= principalOut;
        p.completedPeriods += 1;
        _advance(p);
        if (fee > 0) feesAccrued += fee;

        uint256 spend = got - fee;
        uint256 out = spend > 0 ? _buy(r, spend, p.owner) : 0;
        emit DCAExecuted(id, principalOut - shortfall, accruedOut, out, fee);
        if (shortfall > 0) emit PlanShortfall(id, shortfall);

        if (p.remainingPrincipal == 0) {
            p.active = false;
            emit PlanCompleted(id, p.completedPeriods);
        }
    }

    /// @dev Takes this period's USDC out of the lending leg and debits the
    ///      plan's shares. Returns the principal to debit and what arrived.
    function _draw(Plan storage p) internal returns (uint256 principalOut, uint256 got) {
        uint256 rem = p.remainingPrincipal;
        uint256 shares = p.yieldShares;
        uint256 value = adapter.assetsOf(shares);
        uint256 slice = p.installment < rem ? p.installment : rem;
        // SATURATING. A literal `value - rem` is a Panic on one wei of
        // ordinary ERC-4626 rounding.
        uint256 want = slice + (value > rem ? value - rem : 0);
        uint256 avail = adapter.availableLiquidity();

        if (slice == rem || want >= value) {
            if (value > avail) revert InsufficientAdapterLiquidity(value, avail);
            principalOut = rem;
            p.yieldShares = 0;
            totalManagedShares -= shares;
            got = shares > 0 ? adapter.redeem(shares) : 0;
        } else {
            if (want > avail) revert InsufficientAdapterLiquidity(want, avail);
            principalOut = slice;
            uint256 burned;
            (got, burned) = adapter.withdraw(want);
            // ALWAYS the adapter's own number, and never more than this plan
            // holds — the difference would be someone else's money.
            if (burned > shares) revert LedgerOverdraw(burned, shares);
            p.yieldShares = shares - burned;
            totalManagedShares -= burned;
        }
    }

    function _buy(Route memory r, uint256 spend, address to) internal returns (uint256 out) {
        uint256 minOut = _minOut(r, spend);
        address(usdc).safeApprove(address(swapper), spend);
        out = swapper.swapExactIn(r.pool, r.token, spend, minOut, to);
        // The adapter enforces this too; the vault does not take its word.
        if (out < minOut) revert SlippageExceeded(out, minOut);
    }

    /// @dev ONE step to the first slot strictly in the future. A bare
    ///      `+= interval` leaves an overdue plan still satisfying its own
    ///      precondition, so anyone could loop executeDCA within one block.
    ///      The cast is checked: with interval <= MAX_INTERVAL it cannot fail
    ///      for a few billion years, and a silent wrap into the past is the
    ///      bug that used to let every installment fire in one block.
    function _advance(Plan storage p) internal {
        uint256 next = p.nextExecution;
        if (block.timestamp >= next) {
            uint256 missed = (block.timestamp - next) / p.interval + 1;
            next += p.interval * missed;
        } else {
            next += p.interval;
        }
        if (next > type(uint64).max) revert BadParams();
        p.nextExecution = uint64(next);
    }

    /// @dev THE BOUND. `minOut` is what the Chainlink reference says `amountIn`
    ///      buys, less `maxSlippageBps`. The pool's own price is not in the
    ///      formula at all, so pushing the pool before an execution buys the
    ///      pusher nothing past this one number.
    ///
    ///      The bound covers the pool's premium over the feed AND the trade's
    ///      impact. Measured on live Base (2026-09-21) GOOGLc traded 38bp over
    ///      its feed and a $1,000 fill moves the pool ~0.03bp, so 100bp leaves
    ///      real headroom without handing a sandwich the old 5%.
    ///
    ///      A stale feed is a REVERT, weekday or weekend, and the plan waits
    ///      for the next fresh print. Stale means more than 24h since the
    ///      last print, so for the first day of a freeze a buy still executes
    ///      against that print (docs/threat-model.md, *Stale feeds*).
    function _minOut(Route memory r, uint256 amountInUsdc) internal view returns (uint256) {
        if (!oracle.isFresh(r.token)) revert StaleOracle();
        (uint256 refPx,) = oracle.latestPrice(r.token);
        if (refPx == 0) revert StaleOracle();

        // CIRCUIT BREAKER: reference vs venue. Refuses a pool that is away
        // from the feed when the call starts. It reads the pool's SPOT price,
        // so it is NOT an independent check on the feed: a caller who moves
        // the pool inside the band in the same transaction passes it. It does
        // not price the fill; the line below does, against the feed.
        uint256 poolPx = swapper.poolPrice(r.pool, r.token);
        if (poolPx == 0) revert PoolDiverged(refPx, poolPx);
        uint256 diff = refPx > poolPx ? refPx - poolPx : poolPx - refPx;
        if (diff * 10_000 / refPx > maxDeviationBps) revert PoolDiverged(refPx, poolPx);

        // USDC 6dp -> stock 8dp, price 8dp. One division, so the bps haircut
        // does not compound a rounding loss.
        return (amountInUsdc * 1e10 * (10_000 - maxSlippageBps)) / (refPx * 10_000);
    }

    function _supply(uint256 id, uint256 assets) internal {
        address(usdc).safeApprove(address(adapter), assets);
        uint256 shares = adapter.supply(assets);
        plans[id].yieldShares += shares;
        totalManagedShares += shares;
    }

    // ----------------------------------------------------------- exit
    /// @dev NEVER reverts because the adapter is worth less than principal. A
    ///      rule written to protect principal must not be what locks it in an
    ///      immutable contract. Not pausable, not timelocked, not upgradeable.
    ///
    ///      It DOES revert while the lending market cannot pay the whole
    ///      position (100% utilisation). There is no partial exit; the owner
    ///      waits for liquidity, and meanwhile the position keeps earning.
    function exitPlan(uint256 id) external nonReentrant {
        Plan storage p = plans[id];
        if (msg.sender != p.owner) revert NotOwner();
        if (!p.active) revert PlanInactive();

        uint256 shares = p.yieldShares;
        uint256 value = adapter.assetsOf(shares);
        uint256 avail = adapter.availableLiquidity();
        if (value > avail) revert InsufficientAdapterLiquidity(value, avail);

        p.yieldShares = 0;
        totalManagedShares -= shares;
        uint256 got = shares > 0 ? adapter.redeem(shares) : 0;

        uint256 principal = p.remainingPrincipal;
        uint256 accrued = got > principal ? got - principal : 0;
        uint256 shortfall = got < principal ? principal - got : 0;
        uint256 fee = accrued * feeBps / 10_000;

        p.remainingPrincipal = 0;
        totalPrincipal -= principal;
        p.active = false;

        if (fee > 0) feesAccrued += fee;
        address(usdc).safeTransfer(p.owner, got - fee);
        emit PlanExited(id, got - fee, shortfall);
    }

    // ----------------------------------------------------------- views
    function planYield(uint256 id) external view returns (uint256) {
        Plan memory p = plans[id];
        uint256 total = adapter.assetsOf(p.yieldShares);
        return total > p.remainingPrincipal ? total - p.remainingPrincipal : 0;
    }
}
