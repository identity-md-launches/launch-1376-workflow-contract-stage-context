// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ScoopFrontPage} from "../src/ScoopFrontPage.sol";

/// @title Deploy
/// @notice Local and fork deployment helper. The production launch does NOT use this script: the
///         IMD ProjectFactory deploys both contracts from their built bytecode as described by the
///         launch manifest (`$token` and `$owner` fill the ScoopFrontPage constructor).
/// @dev `deploy` takes its configuration as an argument so tests can call it directly without any
///      environment variable. `run` is the only place the environment is read.
contract Deploy is Script {
    struct Config {
        /// @dev Address that will own ScoopFrontPage. Never the deployer by default.
        address owner;
    }

    struct Deployment {
        LaunchToken token;
        ScoopFrontPage frontPage;
    }

    /// @notice Deploy the token and the front page with an explicit config.
    function deploy(Config memory config) public returns (Deployment memory d) {
        d.token = new LaunchToken();
        d.frontPage = new ScoopFrontPage(address(d.token), config.owner);
    }

    /// @notice CLI entry point: `SCOOP_OWNER=0x... forge script script/Deploy.s.sol --broadcast ...`
    function run() external returns (Deployment memory d) {
        Config memory config = Config({owner: vm.envAddress("SCOOP_OWNER")});
        vm.startBroadcast();
        d = deploy(config);
        vm.stopBroadcast();
    }
}
