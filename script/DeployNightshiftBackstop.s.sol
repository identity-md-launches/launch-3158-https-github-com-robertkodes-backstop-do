// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {NightshiftBackstop} from "../src/NightshiftBackstop.sol";

/// @notice Reviewable deployment parameters for the Ethereum (chain id 1) launch. IMD's launch deploys the
/// contract through its factory with these same constructor arguments; this script is for rehearsal.
contract DeployNightshiftBackstop is Script {
    struct Config {
        address owner;
        address token;
        address quote;
        uint256 minOfferSize;
        uint256 shieldPerOfferCap;
        uint256 minBidderHolding;
    }

    /// @notice Launch owner ($owner of this launch).
    address internal constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    /// @notice IMD on Ethereum (LayerZero OFT, 18 decimals), code checked on chain 1.
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    /// @notice Circle USDC on Ethereum (6 decimals), code checked on chain 1.
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @notice 1,000 IMD: 0.01 % of IMD's 10,000,000 supply (BACKSTOP `min_offer_size`).
    uint256 internal constant MIN_OFFER_SIZE = 1_000e18;
    /// @notice 10,000 USDC (BACKSTOP `shield_per_offer_cap`).
    uint256 internal constant SHIELD_PER_OFFER_CAP = 10_000e6;
    /// @notice A bidder must hold at least 1 IMD.
    uint256 internal constant MIN_BIDDER_HOLDING = 1e18;

    function defaultConfig() public pure returns (Config memory) {
        return Config(OWNER, IMD, USDC, MIN_OFFER_SIZE, SHIELD_PER_OFFER_CAP, MIN_BIDDER_HOLDING);
    }

    function deploy(Config memory c) public returns (NightshiftBackstop) {
        return
            new NightshiftBackstop(c.owner, c.token, c.quote, c.minOfferSize, c.shieldPerOfferCap, c.minBidderHolding);
    }

    function run() external returns (NightshiftBackstop deployed) {
        Config memory c = defaultConfig();
        vm.startBroadcast();
        deployed = deploy(c);
        vm.stopBroadcast();
    }
}
