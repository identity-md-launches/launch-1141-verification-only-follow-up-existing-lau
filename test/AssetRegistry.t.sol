// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {Param} from "../src/interfaces/IIndex.sol";
import {MockERC20, MockFeed} from "./utils/Mocks.sol";

contract AssetRegistryTest is Fixture {
    address internal t0;

    function setUp() public override {
        super.setUp();
        t0 = address(tokens[0]);
    }

    function _expectGovRevert(bytes memory data, bytes4 err) internal {
        vm.prank(OWNER);
        tl.schedule(address(registry), 0, data, bytes32("revert"), MIN_DELAY);
        skip(MIN_DELAY);
        vm.prank(OWNER);
        vm.expectRevert(err);
        tl.execute(address(registry), 0, data, bytes32("revert"));
    }

    function test_defaultParametersMatchTheDocumentedStartingValues() public view {
        assertEq(registry.param(Param.MaxSlippageBps), 100);
        assertEq(registry.param(Param.ReserveBufferBps), 200);
        assertEq(registry.param(Param.DriftThresholdBps), 250);
        assertEq(registry.param(Param.MinTokenAge), 30 days);
        assertEq(registry.param(Param.MinMarketCapUsd), 250_000_000);
        assertEq(registry.param(Param.MinLiquidityUsd), 5_000_000);
        assertEq(registry.param(Param.MinVolumeUsd), 5_000_000);
        assertEq(registry.param(Param.MaxSnapshotAge), 1 days);
        assertEq(registry.param(Param.ProposalDelay), 6 hours);
        assertEq(registry.param(Param.RebalanceInterval), 7 days);
        assertEq(registry.param(Param.RebalanceWindow), 2 days);
        assertEq(registry.param(Param.MaxAdditionsPerEpoch), 2);
        assertEq(registry.param(Param.StaleBasketAfter), 3 days);
        assertEq(registry.param(Param.FailureThreshold), 3);
        assertEq(registry.param(Param.DepositFeeBps), 0);
        assertEq(registry.methodologyVersion(), 1);
        uint256[15] memory all = registry.allParams();
        assertEq(all[uint256(Param.RebalanceInterval)], 7 days);
    }

    function test_everySetterIsTimelockOnly() public {
        vm.startPrank(OWNER);
        vm.expectRevert(AssetRegistry.NotTimelock.selector);
        registry.approveToken(t0, address(feeds[0]), 1 days, 2000, uint40(block.timestamp - 1), bytes32(0));
        vm.expectRevert(AssetRegistry.NotTimelock.selector);
        registry.revokeToken(t0);
        vm.expectRevert(AssetRegistry.NotTimelock.selector);
        registry.releaseQuarantine(t0);
        vm.expectRevert(AssetRegistry.NotTimelock.selector);
        registry.setReserveFeed(address(usdcFeed), 1 days);
        vm.expectRevert(AssetRegistry.NotTimelock.selector);
        registry.setRouter(address(router), true);
        vm.expectRevert(AssetRegistry.NotTimelock.selector);
        registry.setParam(Param.MaxSlippageBps, 50);
        vm.expectRevert(AssetRegistry.NotTimelock.selector);
        registry.setMethodology(2, keccak256("v2"));
        vm.stopPrank();
    }

    function test_paramsStayInsideHardBounds() public {
        _gov(address(registry), abi.encodeCall(registry.setParam, (Param.MaxSlippageBps, 50)));
        assertEq(registry.param(Param.MaxSlippageBps), 50);
        _expectGovRevert(
            abi.encodeCall(registry.setParam, (Param.MaxSlippageBps, 1001)), AssetRegistry.InvalidValue.selector
        );
    }

    function test_slippageLimitCannotBeSwitchedOff() public {
        _expectGovRevert(
            abi.encodeCall(registry.setParam, (Param.MaxSlippageBps, 0)), AssetRegistry.InvalidValue.selector
        );
    }

    function test_minimumTokenAgeCannotGoBelowThirtyDays() public {
        _expectGovRevert(
            abi.encodeCall(registry.setParam, (Param.MinTokenAge, 30 days - 1)), AssetRegistry.InvalidValue.selector
        );
    }

    function test_windowCannotExceedInterval() public {
        _expectGovRevert(
            abi.encodeCall(registry.setParam, (Param.RebalanceWindow, 8 days)), AssetRegistry.InvalidValue.selector
        );
    }

    function test_methodologyVersionOnlyMovesForward() public {
        _gov(address(registry), abi.encodeCall(registry.setMethodology, (2, keccak256("v2"))));
        assertEq(registry.methodologyVersion(), 2);
        assertEq(registry.methodologyHash(), keccak256("v2"));
        _expectGovRevert(
            abi.encodeCall(registry.setMethodology, (2, keccak256("v2b"))), AssetRegistry.InvalidValue.selector
        );
    }

    function test_approveTokenRejectsReserveAsset() public {
        _expectGovRevert(
            abi.encodeCall(
                registry.approveToken, (address(usdc), address(usdcFeed), 1 days, 2000, uint40(1), bytes32(0))
            ),
            AssetRegistry.InvalidToken.selector
        );
    }

    function test_approveTokenRejectsCodelessTokenAndFeed() public {
        _expectGovRevert(
            abi.encodeCall(registry.approveToken, (address(0x1234), address(feeds[0]), 1 days, 2000, 1, bytes32(0))),
            AssetRegistry.InvalidToken.selector
        );
    }

    function test_approveTokenRejectsCodelessFeed() public {
        MockERC20 fresh = new MockERC20("NEW", 18);
        _expectGovRevert(
            abi.encodeCall(registry.approveToken, (address(fresh), address(0x1234), 1 days, 2000, 1, bytes32(0))),
            AssetRegistry.InvalidFeed.selector
        );
    }

    function test_approveTokenRejectsZeroCapAndFutureListing() public {
        MockERC20 fresh = new MockERC20("NEW", 18);
        _expectGovRevert(
            abi.encodeCall(registry.approveToken, (address(fresh), address(feeds[0]), 1 days, 0, 1, bytes32(0))),
            AssetRegistry.InvalidValue.selector
        );
        _expectGovRevert(
            abi.encodeCall(
                registry.approveToken,
                (address(fresh), address(feeds[0]), 1 days, 2000, uint40(block.timestamp + 30 days), bytes32(0))
            ),
            AssetRegistry.InvalidValue.selector
        );
    }

    function test_listedTokensAndAssetRecordArePublished() public view {
        assertEq(registry.listedTokens().length, 6);
        AssetRegistry.Asset memory a = registry.asset(address(tokens[2]));
        assertTrue(a.approved);
        assertEq(a.decimals, 8);
        assertEq(a.feedDecimals, 8);
        assertEq(a.maxWeightBps, 2000);
        assertEq(a.feed, address(feeds[2]));
        assertEq(a.reviewHash, keccak256("review"));
    }

    // ---------------------------------------------------------------- prices

    function test_freshPriceIsNormalisedTo18Decimals() public view {
        (uint256 price, bool ok) = registry.priceUsd(t0);
        assertTrue(ok);
        assertEq(price, 2000e18);
    }

    function test_priceIsValidAtHeartbeatAndStaleOneSecondLater() public {
        skip(1 days);
        (, bool ok) = registry.priceUsd(t0);
        assertTrue(ok, "exactly at heartbeat");
        skip(1);
        (, ok) = registry.priceUsd(t0);
        assertFalse(ok, "one second past heartbeat");
    }

    function test_badFeedAnswersReadAsNoPrice() public {
        feeds[0].set(0);
        (, bool ok) = registry.priceUsd(t0);
        assertFalse(ok, "zero");
        feeds[0].set(-5);
        (, ok) = registry.priceUsd(t0);
        assertFalse(ok, "negative");
        feeds[0].set(2000e8);
        feeds[0].setUpdatedAt(block.timestamp + 1);
        (, ok) = registry.priceUsd(t0);
        assertFalse(ok, "future timestamp");
        feeds[0].setUpdatedAt(0);
        (, ok) = registry.priceUsd(t0);
        assertFalse(ok, "round not complete");
        feeds[0].touch();
        feeds[0].setAnsweredInRound(0);
        (, ok) = registry.priceUsd(t0);
        assertFalse(ok, "answer carried from an older round");
    }

    function test_revertingOrMalformedFeedDoesNotRevertTheReader() public {
        feeds[0].setReverts(true);
        (, bool ok) = registry.priceUsd(t0);
        assertFalse(ok);
        assertFalse(registry.isEligible(t0));
        feeds[0].setReverts(false);
        feeds[0].setMalformed(true);
        (, ok) = registry.priceUsd(t0);
        assertFalse(ok);
        (, ok) = registry.convert(t0, 1e18, address(usdc));
        assertFalse(ok);
    }

    function test_convertHandlesDifferentDecimals() public view {
        (uint256 out, bool ok) = registry.convert(t0, 1e18, address(usdc));
        assertTrue(ok);
        assertEq(out, 2000 * USDC_UNIT, "18-decimal token to 6-decimal reserve");
        (out,) = registry.convert(address(tokens[2]), 1e8, address(usdc));
        assertEq(out, 60_000 * USDC_UNIT, "8-decimal token to reserve");
        (out,) = registry.convert(address(usdc), 60_000 * USDC_UNIT, address(tokens[2]));
        assertEq(out, 1e8, "reserve to 8-decimal token");
        (out,) = registry.convert(address(usdc), 1000 * USDC_UNIT, address(tokens[5]));
        assertEq(out, 2000e18, "reserve to a 50-cent token");
        (out,) = registry.convert(address(usdc), 5, address(usdc));
        assertEq(out, 5);
    }

    function test_convertFailsWhenReserveFeedIsStale() public {
        usdcFeed.setUpdatedAt(block.timestamp - 1 days - 1);
        (, bool ok) = registry.convert(t0, 1e18, address(usdc));
        assertFalse(ok);
    }

    function testFuzz_convertRoundTripNeverCreatesValue(uint256 amount, uint8 a, uint8 b) public view {
        amount = bound(amount, 0, 1e30);
        address from = address(tokens[a % 6]);
        address to = address(tokens[b % 6]);
        (uint256 there,) = registry.convert(from, amount, to);
        (uint256 back,) = registry.convert(to, there, from);
        assertLe(back, amount);
    }

    // ---------------------------------------------------------------- eligibility and quarantine

    function test_tokenYoungerThanThirtyDaysIsNotEligible() public {
        MockERC20 young = new MockERC20("YOUNG", 18);
        MockFeed feed = new MockFeed(8, 5e8);
        uint40 listedAt = uint40(block.timestamp - 10 days);
        _gov(
            address(registry),
            abi.encodeCall(registry.approveToken, (address(young), address(feed), 1 days, 2000, listedAt, bytes32(0)))
        );
        feed.touch();
        assertFalse(registry.isEligible(address(young)));
        vm.warp(uint256(listedAt) + 30 days - 1);
        feed.touch();
        assertFalse(registry.isEligible(address(young)), "one second early");
        vm.warp(uint256(listedAt) + 30 days);
        feed.touch();
        assertTrue(registry.isEligible(address(young)), "exactly thirty days");
    }

    function test_revokedTokenIsNotEligibleButStillPriced() public {
        _gov(address(registry), abi.encodeCall(registry.revokeToken, (t0)));
        assertFalse(registry.isEligible(t0));
        (, bool ok) = registry.priceUsd(t0);
        assertTrue(ok);
    }

    function test_onlyGuardianExecutorOrTimelockQuarantine() public {
        vm.prank(OWNER);
        vm.expectRevert(AssetRegistry.NotAuthorized.selector);
        registry.quarantine(t0);
        vm.prank(KEEPER);
        vm.expectRevert(AssetRegistry.NotAuthorized.selector);
        registry.quarantine(t0);

        vm.prank(GUARDIAN);
        registry.quarantine(t0);
        assertTrue(registry.isQuarantined(t0));
        assertFalse(registry.isEligible(t0));

        vm.prank(GUARDIAN);
        vm.expectRevert(AssetRegistry.AlreadyQuarantined.selector);
        registry.quarantine(t0);
        // The guardian cannot undo it; only the timelock can.
        vm.prank(GUARDIAN);
        vm.expectRevert(AssetRegistry.NotTimelock.selector);
        registry.releaseQuarantine(t0);
        _gov(address(registry), abi.encodeCall(registry.releaseQuarantine, (t0)));
        assertTrue(registry.isEligible(t0));
    }

    function test_anyoneCanQuarantineAStaleTokenButNotAFreshOne() public {
        vm.expectRevert(AssetRegistry.PriceIsFresh.selector);
        registry.quarantineIfStale(t0);
        vm.expectRevert(AssetRegistry.NotListed.selector);
        registry.quarantineIfStale(address(0x1234));

        feeds[0].setUpdatedAt(block.timestamp - 1 days - 1);
        vm.prank(BOB);
        registry.quarantineIfStale(t0);
        assertTrue(registry.isQuarantined(t0));
    }

    function test_routerAllowlist() public {
        assertTrue(registry.isRouterApproved(address(router)));
        _gov(address(registry), abi.encodeCall(registry.setRouter, (address(router), false)));
        assertFalse(registry.isRouterApproved(address(router)));
    }
}
