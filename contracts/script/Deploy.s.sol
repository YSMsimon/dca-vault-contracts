// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle} from "../src/adapters/ChainlinkOracle.sol";
import {MorphoAdapter, IERC4626} from "../src/adapters/MorphoAdapter.sol";
import {AerodromeSwapAdapter} from "../src/adapters/AerodromeSwapAdapter.sol";

/// @notice Base mainnet deploy. Every address is verified — see
///         packages/config/addresses.base.json.
/// @dev    LAUNCH POSTURE, deliberate and documented:
///           feeBps      = 0      take nothing from anyone
///           tvlCap      = $5,000 contract-enforced. A UI cap is not a cap.
///                         FIRST COME, FIRST SERVED: it bounds outstanding
///                         principal, nothing reserves room for anyone, and a
///                         single depositor can legitimately fill it.
///           admin       = multisig, NOT the deployer EOA. The handover is
///                         two-step, and this script only STARTS it
///                         (transferAdmin on the vault and on the oracle); the
///                         multisig must then call acceptAdmin() on BOTH.
///                         Until it does, the deployer still holds both roles.
///           routes      = all four the site offers (NVDAc, GOOGLc, AAPLc,
///                         METAc), listed in this broadcast. The site, the
///                         docs and packages/config all name four; listing
///                         one here would leave three plans that revert.
///           deposits    = paused from the vault's constructor, and LEFT
///                         PAUSED by this script. The order is: the pause is
///                         recorded (setDepositsPaused(true)), then the admin
///                         handover starts, then finishSetup(), the script's
///                         last call, closes the instant setup window for
///                         good. Because the pause was recorded during setup,
///                         finishSetup does not open deposits, whoever sends
///                         it: the multisig does, with
///                         setDepositsPaused(false), once it has accepted
///                         admin, the source is verified, a keeper is
///                         allowlisted and the launch is cleared. A deploy
///                         that opened deposits itself would take money
///                         while the deployer EOA was still admin.
///         Raise the cap only after a month of the author's own money, then
///         public review and a bug bounty. There is no audit, and no pretending
///         otherwise.
contract Deploy is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MORPHO_VAULT = 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61; // Gauntlet USDC Prime
    address constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address constant NVDAC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;
    address constant NVDAC_FEED = 0x04689a41629776563E6822F76f2e57D148d28513;
    address constant GOOGLC = 0xb2000000000000000000002D0BA3164cc74f58B7;
    address constant GOOGLC_POOL = 0xB1987CAD1682841b4b641d50E520777eC5Ab5542;
    address constant GOOGLC_FEED = 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2;
    address constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    address constant AAPLC_POOL = 0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0;
    address constant AAPLC_FEED = 0x787f13dEa48Db0897CbCDD985de77809D837F988;
    address constant METAC = 0xb2000000000000000000008bC8786B856E61707C;
    address constant METAC_POOL = 0xEAF57753BC382E0324a1D43F72E7027705a2273E;
    address constant METAC_FEED = 0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D;
    // Chainlink's "L2 Sequencer Uptime Status Feed" for Base. Immutable in the
    // oracle: no price counts as fresh while the sequencer is down, or for an
    // hour after it restarts.
    address constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    uint256 constant LAUNCH_TVL_CAP = 5_000e6;

    function run() external {
        address multisig = vm.envAddress("ADMIN_MULTISIG");
        vm.startBroadcast();
        // The broadcaster, read from the cheatcode rather than `msg.sender`:
        // the two agree under `forge script`, but not when a test calls
        // run() (ForkDeploy.t.sol does, against Base mainnet), and the vault
        // address below is predicted from THIS account's nonce.
        (, address deployer,) = vm.readCallers();

        ChainlinkOracle oracle = new ChainlinkOracle(SEQUENCER_UPTIME_FEED, true);
        // First listing of a token is instant; CHANGING it later is queued
        // behind the oracle's 48h delay. setFeed also checks decimals() == 8.
        oracle.setFeed(NVDAC, NVDAC_FEED);
        oracle.setFeed(GOOGLC, GOOGLC_FEED);
        oracle.setFeed(AAPLC, AAPLC_FEED);
        oracle.setFeed(METAC, METAC_FEED);

        // Adapters are bound to the vault address, so predict it: the vault is
        // the deployer's next contract after these three.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        MorphoAdapter yieldA = new MorphoAdapter(IERC20(USDC), IERC4626(MORPHO_VAULT), predicted);
        AerodromeSwapAdapter swapA = new AerodromeSwapAdapter(IERC20(USDC), predicted);

        DcaVault vault = new DcaVault(IERC20(USDC), yieldA, swapA, oracle, LAUNCH_TVL_CAP);
        require(
            address(vault) == predicted, "address prediction wrong - adapters are bound to nothing"
        );

        // Initial configuration window: instant ONLY before finishSetup(), so
        // the launch routes are listed in this same broadcast. Deposits are
        // paused throughout, so nobody can land a plan between these calls.
        // After finishSetup, every route change waits ADMIN_DELAY (48h).
        // The ids are the order packages/config lists them in: 1 to 4.
        _list(vault, 1, NVDAC, NVDAC_POOL, NVDAC_FEED);
        _list(vault, 2, GOOGLC, GOOGLC_POOL, GOOGLC_FEED);
        _list(vault, 3, AAPLC, AAPLC_POOL, AAPLC_FEED);
        _list(vault, 4, METAC, METAC_POOL, METAC_FEED);

        // Record the pause BEFORE the handover starts. A pause set during
        // setup survives finishSetup, which is the one way to close the setup
        // window without opening the vault. It goes first because the two
        // calls after the handover are sent by the deployer: if the multisig
        // accepted early, or the broadcast stalled there and was resumed
        // after an accept, they would revert, and a finishSetup later sent by
        // the multisig would then OPEN deposits. With the pause already
        // recorded, whoever calls finishSetup, deposits stay shut.
        vault.setDepositsPaused(true);

        // feeBps stays 0. Admin goes to the multisig in two steps: the
        // multisig must acceptAdmin() on both contracts, and until it does the
        // deployer still holds both roles.
        vault.setFeeRecipient(multisig);
        vault.transferAdmin(multisig);
        oracle.transferAdmin(multisig);
        // LAST: close the setup window. Nothing instant is left after it, and
        // nobody can deposit until the multisig says so.
        vault.finishSetup();
        vm.stopBroadcast();

        console.log("oracle       ", address(oracle));
        console.log("yieldAdapter ", address(yieldA));
        console.log("swapAdapter  ", address(swapA));
        console.log("vault        ", address(vault));
        console.log("tvlCap (USDC)", LAUNCH_TVL_CAP / 1e6);
        console.log("pending admin (vault + oracle), must acceptAdmin():", multisig);
        console.log("deposits: PAUSED. The multisig opens them with setDepositsPaused(false).");
    }

    function _list(DcaVault vault, uint32 id, address token, address pool, address feed) private {
        vault.initRoute(
            id, DcaVault.Route({token: token, pool: pool, feed: feed, dexKind: 0, enabled: true})
        );
    }
}
