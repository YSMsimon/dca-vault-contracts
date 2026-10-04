// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {
    MockERC20,
    MockStock,
    MockYieldAdapter,
    MockPriceOracle,
    MockSwapAdapter
} from "../src/mocks/Mocks.sol";

/// @notice Anvil deploy — the first time the contracts, the keeper and the UI
///         run as one system rather than three that each pass their own tests.
/// @dev    The mocks are the HOSTILE ones the unit tests use: 8-decimal stock
///         with a pause switch and a blocklist, and a yield adapter whose share
///         price can fall. Wiring the UI to a friendly mock would prove nothing
///         about the UI, because the states it has to render are the bad ones.
///
///         Addresses land in deployments/local.json, which the web app and the
///         keeper both read. Anvil's nonces are deterministic, so that file is
///         reproducible and is committed.
contract DeployLocal is Script {
    // Anvil's well-known accounts. Public test keys, no secret here.
    address constant DEV0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant DEV1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant KEEPER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // anvil #2

    uint256 constant TVL_CAP = 1_000_000e6; // local only — mainnet launches at $5k
    uint256 constant FAUCET = 250_000e6;

    struct Listing {
        string name;
        string symbol;
        uint256 price8; // 8 decimals, like the Chainlink B20 feeds
    }

    function run() external {
        // Mocks, an open faucet and a one-step owner: this script is for a
        // local chain and nothing else. Run with a real key and a real RPC
        // it would deploy ten contracts and pay for them.
        require(block.chainid == 31337, "Deploy.local: local chain only");
        vm.startBroadcast();
        // The broadcaster, from the cheatcode rather than `msg.sender`: the two
        // agree under `forge script` but not when a test calls run().
        (, address deployer,) = vm.readCallers();

        MockERC20 usdc = new MockERC20("Mock USD Coin", "USDC", 6);
        MockPriceOracle oracle = new MockPriceOracle();

        // Four routes, priced to match packages/config/addresses.base.json so the
        // local numbers are recognisable rather than invented.
        Listing[4] memory listings = [
            Listing("Mock NVIDIA", "NVDAc", 227_56000000),
            Listing("Mock Alphabet", "GOOGLc", 355_10000000),
            Listing("Mock Apple", "AAPLc", 339_34000000),
            Listing("Mock Meta", "METAc", 740_27000000)
        ];

        MockStock[4] memory stocks;
        for (uint256 i = 0; i < 4; i++) {
            stocks[i] = new MockStock(listings[i].name, listings[i].symbol);
            oracle.setPrice(address(stocks[i]), listings[i].price8);
        }

        // The adapters are bound to the vault address, so predict it: after this
        // point the deployer creates the yield adapter, the swap adapter, then
        // the vault.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        MockYieldAdapter yieldA = new MockYieldAdapter(usdc);
        MockSwapAdapter swapA = new MockSwapAdapter(usdc, stocks[0], oracle);

        DcaVault vault = new DcaVault(IERC20(address(usdc)), yieldA, swapA, oracle, TVL_CAP);
        require(address(vault) == predicted, "address prediction wrong");
        // The mock's money functions are vault-only, like the real adapters.
        // Bound after the fact here (the mock has no constructor slot for it);
        // the Sepolia demo adapter is bound at construction instead.
        yieldA.bindVault(address(vault));

        // initRoute, not queueRoute: the setup window is open (deposits are
        // paused from the constructor), so the launch routes go live in this
        // broadcast instead of 48h from now. finishSetup() below shuts the
        // window for good. See DcaVault.initRoute.
        for (uint32 i = 0; i < 4; i++) {
            vault.initRoute(
                i + 1,
                DcaVault.Route({
                    token: address(stocks[i]),
                    pool: address(swapA), // the mock ignores the pool arg
                    feed: address(oracle), // the mock oracle is its own feed
                    dexKind: 0,
                    enabled: true
                })
            );
        }

        vault.setKeeper(KEEPER, true);
        // LAST vault call: closes the setup window and opens deposits.
        vault.finishSetup();

        // Faucet, so the UI has something to spend without a mint step.
        usdc.mint(DEV0, FAUCET);
        usdc.mint(DEV1, FAUCET);

        vm.stopBroadcast();

        _write(
            address(usdc),
            address(oracle),
            address(yieldA),
            address(swapA),
            address(vault),
            stocks,
            listings
        );
    }

    function _write(
        address usdc,
        address oracle,
        address yieldA,
        address swapA,
        address vault,
        MockStock[4] memory stocks,
        Listing[4] memory listings
    ) internal {
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
            vm.toString(vault),
            '",\n  "usdc": "',
            vm.toString(usdc),
            '",\n  "oracle": "',
            vm.toString(oracle),
            '",\n  "yieldAdapter": "',
            vm.toString(yieldA),
            '",\n  "swapAdapter": "',
            vm.toString(swapA),
            '",\n  "keeper": "',
            vm.toString(KEEPER),
            // A FLOOR, not the exact deploy block: inside a script this is the
            // head at simulation time, and the contracts land a block or two
            // later. Starting a log scan early is only wasteful, never wrong,
            // and on a fresh Anvil the gap is a couple of blocks. A Base
            // deploy script must record the real receipt block instead.
            '",\n  "deployBlock": ',
            vm.toString(block.number),
            ',\n  "usdcDecimals": 6,\n  "stockDecimals": 8,\n  "routes": [',
            routes,
            "]\n}\n"
        );
        vm.writeFile("./contracts/deployments/local.json", json);

        console.log("vault        ", vault);
        console.log("usdc         ", usdc);
        console.log("yieldAdapter ", yieldA);
        console.log("swapAdapter  ", swapA);
        console.log("oracle       ", oracle);
        console.log("-> deployments/local.json");
    }
}
