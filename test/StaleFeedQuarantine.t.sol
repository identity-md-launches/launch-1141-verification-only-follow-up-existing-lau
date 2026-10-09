// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {IndexVault} from "../src/IndexVault.sol";

/// @dev Reproduces audit finding 72f24c4d (launch 816 verification): a one-second heartbeat lapse
/// lets anyone quarantine a basket member, and the quarantine survives feed recovery until the
/// timelock releases it. The behaviour is the documented "tighten only" design and is unchanged;
/// the operational mitigation (README step 5/6: a heartbeat above the feed's own) is asserted.
contract StaleFeedQuarantineTest is Fixture {
    address private constant ANYONE = address(0xBAD);

    function setUp() public override {
        super.setUp();
        (address[] memory members, uint16[] memory weights) = _topFive();
        _activateBasket(members, weights);
        _deposit(ALICE, 1_000_000 * USDC_UNIT);
        _buyBasket();
    }

    function test_oneSecondLapseAllowsPermissionlessStickyQuarantine() public {
        address t = address(tokens[0]);
        feeds[0].setUpdatedAt(block.timestamp - 1 days - 1);
        vm.prank(ANYONE);
        registry.quarantineIfStale(t);
        assertTrue(registry.isQuarantined(t));

        // The feed recovers one second later; the quarantine does not.
        skip(1);
        feeds[0].touch();
        (, bool ok) = registry.priceUsd(t);
        assertTrue(ok, "feed is healthy again");
        assertTrue(registry.isQuarantined(t), "quarantine is sticky");

        usdc.mint(BOB, 1000 * USDC_UNIT);
        vm.startPrank(BOB);
        usdc.approve(address(vault), 1000 * USDC_UNIT);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.PriceUnavailable.selector, t));
        vault.deposit(1000 * USDC_UNIT, BOB, 0);
        vm.stopPrank();

        (, uint256 current, uint256 target) = executor.position(t);
        assertGt(current, 0);
        assertEq(target, 0);

        vm.prank(GUARDIAN);
        vm.expectRevert(AssetRegistry.NotTimelock.selector);
        registry.releaseQuarantine(t);

        // Only the timelock reopens deposits, after its delay.
        _gov(address(registry), abi.encodeCall(registry.releaseQuarantine, (t)));
        assertFalse(registry.isQuarantined(t));
        vm.startPrank(BOB);
        assertGt(vault.deposit(1000 * USDC_UNIT, BOB, 0), 0);
        vm.stopPrank();
    }

    function test_exactHeartbeatAgeIsStillFresh() public {
        address t = address(tokens[0]);
        feeds[0].setUpdatedAt(block.timestamp - 1 days);
        vm.prank(ANYONE);
        vm.expectRevert(AssetRegistry.PriceIsFresh.selector);
        registry.quarantineIfStale(t);
    }

    function test_heartbeatSlackClosesTheLapseWindow() public {
        address t = address(tokens[0]);
        // Governance approves with 1.5x the feed's nominal one-day heartbeat.
        _gov(
            address(registry),
            abi.encodeCall(
                registry.approveToken,
                (t, address(feeds[0]), 36 hours, 2000, uint40(block.timestamp - 31 days), keccak256("review"))
            )
        );
        feeds[0].setUpdatedAt(block.timestamp - 1 days - 1);
        vm.prank(ANYONE);
        vm.expectRevert(AssetRegistry.PriceIsFresh.selector);
        registry.quarantineIfStale(t);

        // A feed that is actually stale against the configured heartbeat is still quarantinable.
        feeds[0].setUpdatedAt(block.timestamp - 36 hours - 1);
        vm.prank(ANYONE);
        registry.quarantineIfStale(t);
        assertTrue(registry.isQuarantined(t));
    }
}
