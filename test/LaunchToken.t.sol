// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndFixedSupplyMintedToDeployer() public view {
        assertEq(token.name(), "IMD Index");
        assertEq(token.symbol(), "IMDEX");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 * 1e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), 10 ** 27);
    }

    function test_transferMovesExactlyTheAmount() public {
        assertTrue(token.transfer(address(0xCAFE), 123e18));
        assertEq(token.balanceOf(address(0xCAFE)), 123e18);
        assertEq(token.balanceOf(address(this)), 10 ** 27 - 123e18);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_transferFromNeedsAllowance() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        token.transferFrom(address(this), address(0xBEEF), 1);

        token.approve(address(0xBEEF), 5);
        vm.prank(address(0xBEEF));
        token.transferFrom(address(this), address(0xBEEF), 5);
        assertEq(token.balanceOf(address(0xBEEF)), 5);
    }

    function test_transferBeyondBalanceReverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        token.transfer(address(this), 1);
    }

    function test_noMintOrAdminEntryPointExists() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "pause()",
            "setFee(uint256)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], address(this), 1));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function testFuzz_transfersConserveSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(this)), token.totalSupply());
    }
}
