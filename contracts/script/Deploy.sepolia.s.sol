// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {
    DemoUSDC,
    DemoStock,
    DemoYieldAdapter,
    DemoPriceOracle,
    DemoSwapAdapter
} from "../src/mocks/DemoMocks.sol";

/// @notice Base Sepolia deploy — the public demo, and only the public demo.
/// @dev    THIS IS NOT AN INTEGRATION TEST, and pretending otherwise would be
///         the dishonest thing here. Base Sepolia carries none of this
///         protocol's dependencies: there is no NVDAc, so no Aerodrome pool, no
///         Chainlink feed and no swap leg, and Morpho on Sepolia is bare core
///         contracts with no usable USDC market. A "Sepolia integration" can
///         only re-run the mocks the unit tests already pass against. The
///         failures that can actually kill this design exist only on mainnet.
///         The mainnet fork suites (contracts/test/Fork*.t.sol) cover the ones
///         a fork can reach: the real feeds, the real lending markets'
///         liquidity and rounding, the real pool's price. They CANNOT cover
///         the buy itself: B20 stock tokens are precompiles a fork cannot
///         execute, so no test here has moved a real B20 token.
///
///         What this deploy is for is the other half: a demo a stranger can
///         clone and anyone can try. A live URL, a faucet, and a plan you can
///         create with your own wallet and watch execute. That needs a chain
///         anyone can reach and money nobody can lose.
///
///         So: the demo mocks, whose hostile switches are owner-gated (see
///         DemoMocks) because an ungated `setPaused` on a public chain is one
///         passer-by away from a dead demo.
///
///         ENV:
///           DEMO_KEEPER   address the keeper bot signs as
///           DEMO_OWNER    optional — defaults to the deployer
contract DeploySepolia is Script {
    /// FAR above what the faucet can pour. The faucet's global budget
    /// (DemoUSDC.DAILY_BUDGET, $100k/day) is what bounds how fast demo dollars
    /// exist; at $100M the cap is ~1,000 days of every drip going to one
    /// Sybil, so it never binds a visitor. It used to be $250k, which 253
    /// one-drip contracts filled in a single transaction. `run` asserts the
    /// ratio so a later edit to either number cannot quietly undo it.
    uint256 constant TVL_CAP = 100_000_000e6;
    uint256 constant MIN_CAP_DAYS_OF_BUDGET = 365;
    uint256 constant CHAIN_ID = 84532;

    struct Listing {
        string name;
        string symbol;
        uint256 price8; // 8 decimals, like the Chainlink B20 feeds
    }

    /// @dev One struct rather than eight arguments: solc runs out of stack
    ///      slots writing the JSON otherwise, and --via-ir for a deploy script
    ///      is a heavy price for a formatting function.
    struct Deployed {
        address vault;
        address usdc;
        address oracle;
        address yieldAdapter;
        address swapAdapter;
        address keeper;
    }

    function run() external {
        require(block.chainid == CHAIN_ID, "not base sepolia");

        address keeper = vm.envAddress("DEMO_KEEPER");

        vm.startBroadcast();
        // The broadcaster, from the cheatcode rather than `msg.sender`: the two
        // agree under `forge script` but not when a test calls run(), and the
        // vault address below is predicted from THIS account's nonce.
        (, address deployer,) = vm.readCallers();
        address owner = vm.envOr("DEMO_OWNER", deployer);

        // Everything is created OWNED BY THE DEPLOYER, configured, and only
        // then handed to DEMO_OWNER at the end. Constructing with `owner`
        // directly meant every setup call below (setPrice, mint) reverted
        // NotOwner whenever DEMO_OWNER was not the deployer.
        DemoUSDC usdc = new DemoUSDC(deployer);
        DemoPriceOracle oracle = new DemoPriceOracle(deployer);

        // Priced to match packages/config/addresses.base.json so the demo's
        // numbers are recognisable rather than invented. They do not move on
        // their own — the keeper nudges them, and the UI says the prices are
        // demo prices, because a testnet chart that looks live is a lie.
        Listing[4] memory listings = [
            Listing("Demo NVIDIA", "NVDAc", 227_56000000),
            Listing("Demo Alphabet", "GOOGLc", 355_10000000),
            Listing("Demo Apple", "AAPLc", 339_34000000),
            Listing("Demo Meta", "METAc", 740_27000000)
        ];

        DemoStock[4] memory stocks;
        for (uint256 i = 0; i < 4; i++) {
            stocks[i] = new DemoStock(listings[i].name, listings[i].symbol, deployer);
            oracle.setPrice(address(stocks[i]), listings[i].price8);
        }

        // The adapters are bound to the vault address, so predict it: after
        // this point the deployer creates the yield adapter, the swap adapter,
        // then the vault.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        // Bound to the predicted vault for life: its supply/redeem/withdraw
        // answer to nobody else. It used to inherit the mock's open ones, and
        // anyone could withdraw every visitor's pooled USDC.
        DemoYieldAdapter yieldA = new DemoYieldAdapter(usdc, deployer, predicted);
        DemoSwapAdapter swapA = new DemoSwapAdapter(usdc, stocks[0], oracle, deployer);

        DcaVault vault = new DcaVault(IERC20(address(usdc)), yieldA, swapA, oracle, TVL_CAP);
        require(
            address(vault) == predicted, "address prediction wrong - adapters are bound to nothing"
        );
        require(yieldA.vault() == address(vault), "yield adapter not bound to the vault");
        require(
            TVL_CAP >= usdc.DAILY_BUDGET() * MIN_CAP_DAYS_OF_BUDGET,
            "cap within reach of the faucet - a Sybil can fill it"
        );

        // Initial configuration window: instant only before finishSetup().
        // Deposits are paused until then, so no visitor's createPlan can land
        // between these transactions and close the window on the rest.
        for (uint32 i = 0; i < 4; i++) {
            vault.initRoute(
                i + 1,
                DcaVault.Route({
                    token: address(stocks[i]),
                    pool: address(swapA), // the mock ignores the pool arg
                    feed: address(oracle),
                    dexKind: 0,
                    enabled: true
                })
            );
        }

        vault.setKeeper(keeper, true);

        // The yield adapter mints interest through DemoUSDC, and is the only
        // contract besides the owner allowed to. Visitors use drip().
        usdc.setMinter(address(yieldA));

        // Seed the adapter so the very first exit has something to redeem
        // against even before anyone supplies. Costs nothing; these are demo
        // dollars.
        usdc.mint(address(yieldA), 10_000e6);

        if (owner != deployer) {
            usdc.setOwner(owner);
            oracle.setOwner(owner);
            yieldA.setOwner(owner);
            swapA.setOwner(owner);
            for (uint256 i = 0; i < 4; i++) {
                stocks[i].setOwner(owner);
            }
            // The vault too. It used to stay with the deployer: admin and
            // fee recipient both. Two-step, so DEMO_OWNER must acceptAdmin();
            // until it does the deployer still holds the role.
            vault.setFeeRecipient(owner);
            vault.transferAdmin(owner);
        }

        // LAST: close the setup window and open deposits.
        vault.finishSetup();

        vm.stopBroadcast();

        _write(
            Deployed({
                vault: address(vault),
                usdc: address(usdc),
                oracle: address(oracle),
                yieldAdapter: address(yieldA),
                swapAdapter: address(swapA),
                keeper: keeper
            }),
            stocks,
            listings
        );
    }

    function _write(Deployed memory d, DemoStock[4] memory stocks, Listing[4] memory listings)
        internal
    {
        string memory routes = "";
        for (uint256 i = 0; i < 4; i++) {
            routes = string.concat(
                routes,
                i == 0 ? "" : ",",
                '{"routeId":',
                vm.toString(i + 1),
                ',"symbol":"',
                listings[i].symbol,
                '","name":"',
                listings[i].name,
                '","token":"',
                vm.toString(address(stocks[i])),
                '","price8":"',
                vm.toString(listings[i].price8),
                '"}'
            );
        }

        string memory json = string.concat(
            '{\n  "chainId": ',
            vm.toString(block.chainid),
            ',\n  "vault": "',
            vm.toString(d.vault),
            '",\n  "usdc": "',
            vm.toString(d.usdc),
            '",\n  "oracle": "',
            vm.toString(d.oracle),
            '",\n  "yieldAdapter": "',
            vm.toString(d.yieldAdapter),
            '",\n  "swapAdapter": "',
            vm.toString(d.swapAdapter),
            '",\n  "keeper": "',
            vm.toString(d.keeper),
            // A FLOOR, and on a live chain a worse one than on Anvil: this is
            // the head at SIMULATION time and the transactions land later,
            // sometimes much later if the mempool is busy. After a real
            // deploy, replace it with the block of the vault's creation
            // receipt, which is the number a log scan should start from.
            '",\n  "deployBlock": ',
            vm.toString(block.number),
            ',\n  "faucet": true,\n  "demo": true',
            ',\n  "usdcDecimals": 6,\n  "stockDecimals": 8,\n  "routes": [',
            routes,
            "]\n}\n"
        );
        vm.writeFile("./contracts/deployments/baseSepolia.json", json);

        console.log("vault        ", d.vault);
        console.log("usdc         ", d.usdc);
        console.log("yieldAdapter ", d.yieldAdapter);
        console.log("swapAdapter  ", d.swapAdapter);
        console.log("oracle       ", d.oracle);
        console.log("keeper       ", d.keeper);
        console.log("deployBlock (FLOOR, fix from receipt)", block.number);
        console.log("-> deployments/baseSepolia.json");
    }
}
