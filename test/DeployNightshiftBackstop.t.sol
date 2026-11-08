// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NightshiftBackstop} from "../src/NightshiftBackstop.sol";
import {DeployNightshiftBackstop} from "../script/DeployNightshiftBackstop.s.sol";

contract DeployNightshiftBackstopTest is Test {
    function test_defaultConfigDeploysOnEmptyChain() public {
        DeployNightshiftBackstop script = new DeployNightshiftBackstop();
        DeployNightshiftBackstop.Config memory c = script.defaultConfig();
        assertEq(c.owner, 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5);
        NightshiftBackstop b = script.deploy(c);
        assertEq(b.owner(), c.owner);
        assertTrue(b.owner() != address(script) && b.owner() != tx.origin);
        assertEq(b.treasury(), c.owner);
        assertEq(b.token(), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(b.quote(), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(b.minOfferSize(), 1_000e18);
        assertEq(b.shieldPerOfferCap(), 10_000e6);
        assertEq(b.minBidderHolding(), 1e18);
        assertEq(b.priceSource(), address(0));
        assertFalse(b.paused());
        // Unset price source: offers refuse until the owner configures it.
        vm.expectRevert(NightshiftBackstop.PriceSourceNotConfigured.selector);
        b.quoteLot(10e18);
        assertLe(address(b).code.length, 24_576);
    }
}
