// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    MockERC20,
    MockStock,
    MockYieldAdapter,
    MockPriceOracle,
    MockSwapAdapter
} from "./Mocks.sol";

/// @notice The mocks, with their hostile switches behind an owner.
/// @dev    Base Sepolia carries none of this protocol's dependencies — no
///         NVDAc, so no pool, no feed and no swap leg, and Morpho there is bare
///         core contracts with no usable USDC market. What can be tested
///         against the real protocols is tested on a mainnet fork instead. So
///         the testnet deploy runs on mocks, and its job is not integration:
///         it is a demo a stranger can clone and anyone can try without
///         risking money.
///
///         Which changes what the mocks have to be. Locally, `setPaused`,
///         `setSharePrice` and `setPrice` are ungated ON PURPOSE — a test needs
///         to reach into the worst state cheaply. On a public chain the same
///         openness is a griefing surface with no cost to the griefer:
///         `setPaused(true)` freezes every buy for everyone, `setSharePrice(0)`
///         evaporates every plan's idle capital, and `setFresh(false)` makes
///         every execution revert. One passer-by ends the demo, and the person
///         who finds it broken is the next visitor.
///
///         So the switches are owner-gated here. The faucet (`DemoUSDC.drip`)
///         stays open to anyone, because that is the front door, but it is
///         rate-limited per address AND by a global daily budget, and raw
///         `mint` is not a second, unlimited door. The yield adapter's money
///         functions answer only to the vault it was deployed for.
abstract contract DemoOwned {
    address public owner;

    error NotOwner();

    event OwnerChanged(address indexed from, address indexed to);

    constructor(address o) {
        owner = o;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev No two-step handoff. This is a testnet demo, and the failure it
    ///      protects against is a stranger, not a fat-fingered transfer.
    function setOwner(address o) external onlyOwner {
        emit OwnerChanged(owner, o);
        owner = o;
    }
}

/// @notice Testnet dollars, with a faucet a visitor can use without leaving the page.
/// @dev    TWO limits on the faucet. The per-address cooldown is UX. The
///         GLOBAL DAILY BUDGET is what bounds supply: a per-address limit is
///         no limit against a contract that deploys 253 children in one
///         transaction, each dripping once — measured in the round-2 re-test,
///         that filled the old $250k demo cap in one transaction. The budget
///         caps every address together at DAILY_BUDGET per UTC day, and the
///         Sepolia deploy sets the vault's cap far above it (Deploy.sepolia
///         asserts at least a year of budget), so filling the cap would take
///         years of every drip going to one person. The cost of the budget is
///         that a Sybil can empty one day's faucet; visitors then wait for the
///         next UTC day, and `dripReadyAt` says when.
/// @dev    `mint` is limited to the owner and ONE minter — the demo yield
///         adapter, whose `accrueTo` mints through it so interest is real
///         assets rather than a number that went up. It used to be public, and
///         a public mint with no cooldown let one visitor fill the whole
///         vault's TVL cap in a single transaction and lock every later visitor
///         out of the demo. Visitors get dollars through `drip`, which is
///         rate-limited, and that is the only public way in.
contract DemoUSDC is MockERC20, DemoOwned {
    uint256 public constant DRIP = 1_000e6;
    uint256 public constant COOLDOWN = 4 hours;
    /// Every address together, per UTC day. 100 visitors' worth.
    uint256 public constant DAILY_BUDGET = 100_000e6;

    /// The demo yield adapter. Settable, because it is deployed after this.
    address public minter;

    mapping(address => uint256) public lastDrip;
    /// `block.timestamp / 1 days` of the window `drippedToday` counts.
    uint256 public budgetDay;
    uint256 public drippedToday;

    error DripTooSoon(uint256 readyAt);
    error FaucetDry(uint256 refillsAt);
    error NotMinter();

    event Dripped(address indexed to, uint256 amount);
    event MinterSet(address indexed minter);

    constructor(address o) MockERC20("Demo USD Coin", "USDC", 6) DemoOwned(o) {}

    function setMinter(address m) external onlyOwner {
        minter = m;
        emit MinterSet(m);
    }

    function mint(address to, uint256 amt) public override {
        if (msg.sender != owner && msg.sender != minter) revert NotMinter();
        _mint(to, amt);
    }

    /// @notice $1,000 of testnet USDC, once every four hours per address,
    ///         while today's global budget lasts.
    function drip() external {
        uint256 ready = lastDrip[msg.sender] + COOLDOWN;
        if (lastDrip[msg.sender] != 0 && block.timestamp < ready) revert DripTooSoon(ready);
        uint256 day = block.timestamp / 1 days;
        uint256 used = day == budgetDay ? drippedToday : 0;
        if (used + DRIP > DAILY_BUDGET) revert FaucetDry((day + 1) * 1 days);
        budgetDay = day;
        drippedToday = used + DRIP;
        lastDrip[msg.sender] = block.timestamp;
        _mint(msg.sender, DRIP);
        emit Dripped(msg.sender, DRIP);
    }

    /// @notice What is left of today's global budget.
    function faucetRemainingToday() public view returns (uint256) {
        uint256 used = block.timestamp / 1 days == budgetDay ? drippedToday : 0;
        return used >= DAILY_BUDGET ? 0 : DAILY_BUDGET - used;
    }

    /// @notice When the faucet will pour again for `who`. Zero means now.
    /// @dev    The later of the address's cooldown and, if today's budget is
    ///         spent, the start of the next UTC day.
    function dripReadyAt(address who) external view returns (uint256) {
        uint256 last = lastDrip[who];
        uint256 ready = last == 0 || block.timestamp >= last + COOLDOWN ? 0 : last + COOLDOWN;
        if (faucetRemainingToday() < DRIP) {
            uint256 refill = (block.timestamp / 1 days + 1) * 1 days;
            if (refill > ready) ready = refill;
        }
        return ready;
    }
}

/// @notice The hostile stock, with the pause switch and blocklist behind the owner.
/// @dev    `mint` is deliberately NOT gated: MockSwapAdapter mints the stock it
///         sells, so gating it would break every buy. A visitor minting
///         themselves free demo shares changes nothing the vault accounts for —
///         the vault ledgers what it bought, not what an address holds.
contract DemoStock is MockStock, DemoOwned {
    constructor(string memory n, string memory sym, address o) MockStock(n, sym) DemoOwned(o) {}

    function setPaused(bool p) external override onlyOwner {
        paused = p;
    }

    function setBlocked(address a, bool b) external override onlyOwner {
        blocked[a] = b;
    }
}

/// @notice The lending mock, with the loss switch behind the owner and the
///         money behind the vault.
/// @dev    `supply`/`redeem`/`withdraw` are `onlyVault` (VaultBound), and the
///         vault is fixed HERE, at construction, to the address the deploy
///         script predicts — the same pattern as MorphoAdapter. There is no
///         re-binding: `bindVault` always reverts.
contract DemoYieldAdapter is MockYieldAdapter, DemoOwned {
    error AlreadyBound();

    constructor(MockERC20 _usdc, address o, address _vault) MockYieldAdapter(_usdc) DemoOwned(o) {
        if (_vault == address(0)) revert OnlyVault();
        vault = _vault;
        emit VaultSet(_vault);
    }

    function bindVault(address) external pure override {
        revert AlreadyBound();
    }

    function setSharePrice(uint256 wad) external override onlyOwner {
        sharePriceWad = wad;
    }

    /// @dev The keeper calls this on a schedule so the demo actually earns.
    ///      Ungated it is an infinite USDC mint into the adapter, which is a
    ///      donation attack with no attacker cost.
    function accrueTo(uint256 wad) external override onlyOwner {
        sharePriceWad = wad;
        uint256 owed = assetsOf(totalShares);
        uint256 have = usdc.balanceOf(address(this));
        if (owed > have) usdc.mint(address(this), owed - have);
    }

    function setLiquidityCap(uint256 c) external override onlyOwner {
        liquidityCap = c;
    }
}

/// @notice The oracle, with the price and the freshness flag behind the owner.
contract DemoPriceOracle is MockPriceOracle, DemoOwned {
    constructor(address o) DemoOwned(o) {}

    function setPrice(address t, uint256 p) external override onlyOwner {
        price[t] = p;
        updatedAt[t] = block.timestamp;
    }

    function setFresh(bool f) external override onlyOwner {
        fresh = f;
    }
}

/// @notice The swapper, with the impact haircut behind the owner.
contract DemoSwapAdapter is MockSwapAdapter, DemoOwned {
    constructor(MockERC20 _usdc, MockStock _stock, MockPriceOracle _o, address o)
        MockSwapAdapter(_usdc, _stock, _o)
        DemoOwned(o)
    {}

    function setHaircutBps(uint256 b) external override onlyOwner {
        haircutBps = b;
    }
}
