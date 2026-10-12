// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract DeployTest is Test {
    function test_deploy_wiresTokenAndOwner() public {
        address owner = makeAddr("owner");
        Deploy script = new Deploy();

        Deploy.Deployment memory d = script.deploy(Deploy.Config({owner: owner}));

        assertEq(address(d.frontPage.scoop()), address(d.token));
        assertEq(d.frontPage.owner(), owner);
        assertEq(d.frontPage.price(), 2_000_000e18);
        // The token minted to whoever deployed it (the script), not to the front page or the owner.
        assertEq(d.token.balanceOf(address(script)), 1_000_000_000e18);
        assertEq(d.token.balanceOf(address(d.frontPage)), 0);
        assertEq(d.token.balanceOf(owner), 0);
    }
}
