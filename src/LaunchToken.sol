// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken (Scoop, SCOOP)
/// @notice The SCOOP launch token: a fixed-supply ERC-20 with plain transfers.
/// @dev The whole supply, 1,000,000,000 tokens at 18 decimals, is minted once to the deployer
///      (the launch factory) in the constructor. There is no mint, owner, pause, blocklist, fee or
///      upgrade function. The factory splits the supply between the swarm, the pool and the
///      requester after deployment; nothing in this repository is allocated any of it.
contract LaunchToken is ERC20 {
    /// @notice Total supply in minor units: 10^9 tokens * 10^18.
    uint256 public constant SUPPLY = 1_000_000_000e18;

    constructor() ERC20("Scoop", "SCOOP") {
        _mint(msg.sender, SUPPLY);
    }
}
