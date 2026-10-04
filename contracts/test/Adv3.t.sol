// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DcaVault} from "../src/DcaVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ChainlinkOracle, IAggregatorV3} from "../src/adapters/ChainlinkOracle.sol";
import {
    MockERC20, MockStock, MockYieldAdapter, MockPriceOracle, MockSwapAdapter
} from "../src/mocks/Mocks.sol";
import {FakeFeed} from "./utils/HostileVenues.sol";

/// @notice The round-2 re-test's Adv3, in its original shape, flipped (D4).
/// @dev    It used to pass by showing `isFresh` — documented "never reverts" —
///         bubbling a reverting feed, which blocked `createPlan` (deposits) as
///         well as executions. It now asserts the safe behaviour. The fuller
///         D4 test is Round2.t.sol:test_D4_ARevertingFeedDoesNotBlockDeposits.
contract Adv3Test is Test {
    function test_RevertingFeedNoLongerBlocksDeposits() public {
        vm.warp(1_780_000_000);
        MockERC20 usdc = new MockERC20("U", "U", 6);
        MockStock s = new MockStock("S", "S");
        MockYieldAdapter y = new MockYieldAdapter(usdc);
        MockPriceOracle po = new MockPriceOracle();
        MockSwapAdapter sw = new MockSwapAdapter(usdc, s, po);
        ChainlinkOracle cl = new ChainlinkOracle();
        FakeFeed f = new FakeFeed();
        f.set(227e8, block.timestamp, true);
        po.setPrice(address(s), 227e8);
        cl.setFeed(address(s), address(f));
        DcaVault v = new DcaVault(IERC20(address(usdc)), y, sw, cl, 1e12);
        y.bindVault(address(v));
        v.initRoute(1, DcaVault.Route(address(s), address(sw), address(f), 0, true));
        v.finishSetup();
        usdc.mint(address(this), 1e9);
        usdc.approve(address(v), 1e9);
        vm.mockCallRevert(
            address(f), abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), "DEPRECATED"
        );
        assertFalse(cl.isFresh(address(s)), "a reverting feed must read as not fresh");
        uint256 id = v.createPlan(1, 1e9, 1e8, 1 days);
        (,,, uint256 rem,,,,, bool active) = v.plans(id);
        assertEq(rem, 1e9, "no first buy against a dead feed");
        assertTrue(active);
    }
}
