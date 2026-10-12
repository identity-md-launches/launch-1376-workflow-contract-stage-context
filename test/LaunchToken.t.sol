// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    LaunchToken internal token;
    address internal deployer;

    function setUp() public {
        deployer = address(this);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Scoop");
        assertEq(token.symbol(), "SCOOP");
        assertEq(token.decimals(), 18);
    }

    function test_mintsExactlyOneBillionToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.SUPPLY(), SUPPLY);
    }

    function test_transferMovesExactAmount() public {
        address alice = makeAddr("alice");
        uint256 amount = 123_456e18;

        assertTrue(token.transfer(alice, amount));

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromWithAllowance() public {
        address alice = makeAddr("alice");
        address spender = makeAddr("spender");
        token.transfer(alice, 10e18);

        vm.prank(alice);
        token.approve(spender, 4e18);

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, deployer, 4e18));
        assertEq(token.balanceOf(alice), 6e18);
        assertEq(token.allowance(alice, spender), 0);
    }

    function test_revert_transferMoreThanBalance() public {
        address alice = makeAddr("alice");
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(deployer, 1);
    }

    function test_noMintOrAdminFunctions() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], deployer, uint256(1)));
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
        }
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
