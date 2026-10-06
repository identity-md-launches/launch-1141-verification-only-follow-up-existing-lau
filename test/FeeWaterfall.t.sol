// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {FeeWaterfall} from "../src/FeeWaterfall.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {MockERC20} from "./utils/Mocks.sol";

contract FeeWaterfallTest is Fixture {
    address internal constant SWARM = address(0x5A);
    address internal constant PROTOCOL = address(0x5B);
    address internal constant UTILITY = address(0x5C);

    function _fees(uint256 amount) internal {
        usdc.mint(address(waterfall), amount);
    }

    function _setRecipients() internal {
        _queue(address(waterfall), abi.encodeCall(waterfall.setRecipient, (FeeWaterfall.Bucket.Swarm, SWARM)));
        _queue(address(waterfall), abi.encodeCall(waterfall.setRecipient, (FeeWaterfall.Bucket.Protocol, PROTOCOL)));
        _queue(address(waterfall), abi.encodeCall(waterfall.setRecipient, (FeeWaterfall.Bucket.Utility, UTILITY)));
        _flush();
    }

    function _accrued(FeeWaterfall.Bucket bucket) internal view returns (uint256) {
        return waterfall.accrued(bucket);
    }

    function test_startingSplitAndFeeAreVisibleOnChain() public view {
        assertEq(waterfall.basketBps(), 4000);
        assertEq(waterfall.lpBps(), 2500);
        assertEq(waterfall.swarmBps(), 2000);
        assertEq(waterfall.protocolBps(), 1000);
        assertEq(waterfall.utilityBps(), 500);
        assertEq(waterfall.swapFeePips(), 10_000);
        (uint24 lpFee, uint24 hookFee, uint16 basketBps, uint16 nonLpBps) = waterfall.feeQuote();
        assertEq(lpFee, 2_500, "25% of a 1% fee goes to LPs as the pool fee");
        assertEq(hookFee, 7_500);
        assertEq(basketBps, 4000);
        assertEq(nonLpBps, 7500);
    }

    function test_distributeSplitsTheNonLpSeventyFivePercent() public {
        // 100 of total fee: 25 stayed with LPs in the pool, 75 arrives here.
        _fees(75 * USDC_UNIT);
        assertEq(waterfall.pendingDistribution(), 75 * USDC_UNIT);
        assertEq(waterfall.distribute(), 75 * USDC_UNIT);
        assertEq(_accrued(FeeWaterfall.Bucket.Basket), 40 * USDC_UNIT);
        assertEq(_accrued(FeeWaterfall.Bucket.Swarm), 20 * USDC_UNIT);
        assertEq(_accrued(FeeWaterfall.Bucket.Protocol), 10 * USDC_UNIT);
        assertEq(_accrued(FeeWaterfall.Bucket.Utility), 5 * USDC_UNIT);
        assertEq(waterfall.totalAccrued(), 75 * USDC_UNIT);
        assertEq(waterfall.distribute(), 0, "nothing new");
    }

    function test_roundingDustGoesToTheBasketReserve() public {
        _fees(7);
        waterfall.distribute();
        assertEq(_accrued(FeeWaterfall.Bucket.Swarm), 1); // 7 * 2000 / 7500
        assertEq(_accrued(FeeWaterfall.Bucket.Protocol), 0);
        assertEq(_accrued(FeeWaterfall.Bucket.Utility), 0);
        assertEq(_accrued(FeeWaterfall.Bucket.Basket), 6);
    }

    function testFuzz_distributionConservesEveryUnit(uint256 a, uint256 b, uint16 lp, uint16 swarm) public {
        a = bound(a, 0, 1e30);
        b = bound(b, 0, 1e30);
        lp = uint16(bound(lp, 0, 10_000));
        swarm = uint16(bound(swarm, 0, 10_000 - lp));
        uint16 basket = 10_000 - lp - swarm;
        vm.prank(address(tl));
        waterfall.setSplit(basket, lp, swarm, 0, 0);

        _fees(a);
        waterfall.distribute();
        _fees(b);
        waterfall.distribute();

        uint256 sum = _accrued(FeeWaterfall.Bucket.Basket) + _accrued(FeeWaterfall.Bucket.Swarm)
            + _accrued(FeeWaterfall.Bucket.Protocol) + _accrued(FeeWaterfall.Bucket.Utility);
        assertEq(sum, a + b);
        assertEq(waterfall.totalAccrued(), a + b);
        assertEq(usdc.balanceOf(address(waterfall)), a + b);
        if (lp < 10_000) {
            assertGe(_accrued(FeeWaterfall.Bucket.Basket) + 1, (a + b) * basket / (10_000 - uint256(lp)));
        }
    }

    function test_claimPaysOnlyTheConfiguredRecipient() public {
        _fees(75 * USDC_UNIT);
        vm.expectRevert(FeeWaterfall.ZeroAddress.selector);
        waterfall.claim(FeeWaterfall.Bucket.Swarm); // no recipient yet: funds wait

        _setRecipients();
        vm.prank(BOB); // anyone can trigger; the money still goes to the recipient
        assertEq(waterfall.claim(FeeWaterfall.Bucket.Swarm), 20 * USDC_UNIT);
        assertEq(usdc.balanceOf(SWARM), 20 * USDC_UNIT);
        assertEq(usdc.balanceOf(BOB), 0);
        waterfall.claim(FeeWaterfall.Bucket.Protocol);
        waterfall.claim(FeeWaterfall.Bucket.Utility);
        assertEq(usdc.balanceOf(PROTOCOL), 10 * USDC_UNIT);
        assertEq(usdc.balanceOf(UTILITY), 5 * USDC_UNIT);
        assertEq(waterfall.totalAccrued(), 40 * USDC_UNIT);
        assertEq(usdc.balanceOf(address(waterfall)), 40 * USDC_UNIT);
        assertEq(waterfall.lifetime(FeeWaterfall.Bucket.Swarm), 20 * USDC_UNIT);

        vm.expectRevert(FeeWaterfall.NothingToSend.selector);
        waterfall.claim(FeeWaterfall.Bucket.Swarm);
        vm.expectRevert(FeeWaterfall.InvalidBucket.selector);
        waterfall.claim(FeeWaterfall.Bucket.Basket);
    }

    function test_basketReserveIsDepositedAtNavForTheTreasury() public {
        _deposit(ALICE, 1000 * USDC_UNIT);
        _fees(75 * USDC_UNIT);
        vm.prank(KEEPER);
        uint256 shares = waterfall.pushBasketReserve(0);
        assertEq(shares, 40 * 1e12);
        assertEq(vault.balanceOf(address(tl)), shares, "shares belong to the timelock treasury");
        assertEq(usdc.balanceOf(address(vault)), 1040 * USDC_UNIT);
        assertEq(_accrued(FeeWaterfall.Bucket.Basket), 0);
        assertEq(usdc.allowance(address(waterfall), address(vault)), 0);
        assertEq(waterfall.lifetime(FeeWaterfall.Bucket.Basket), 40 * USDC_UNIT);
        // Alice's holders are not diluted: NAV per share is unchanged.
        (uint256 perShare,) = vault.navPerShare();
        assertEq(perShare, USDC_UNIT);

        vm.prank(KEEPER);
        vm.expectRevert(FeeWaterfall.NothingToSend.selector);
        waterfall.pushBasketReserve(0);
    }

    function test_basketReserveKeepsAccumulatingWhileTheVaultIsClosed() public {
        _fees(75 * USDC_UNIT);
        vm.prank(GUARDIAN);
        tl.pause();
        vm.prank(KEEPER);
        vm.expectRevert(IndexVault.Paused.selector);
        waterfall.pushBasketReserve(0);

        _fees(75 * USDC_UNIT);
        waterfall.distribute();
        assertEq(_accrued(FeeWaterfall.Bucket.Basket), 80 * USDC_UNIT);
        vm.prank(GUARDIAN);
        tl.unpause();
        vm.prank(KEEPER);
        assertEq(waterfall.pushBasketReserve(80 * 1e12), 80 * 1e12);
    }

    function test_pushHonoursMinShares() public {
        _fees(75 * USDC_UNIT);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.InsufficientShares.selector, 40 * 1e12, 40 * 1e12 + 1));
        waterfall.pushBasketReserve(40 * 1e12 + 1);
    }

    function test_configurationIsTimelockOnly() public {
        vm.startPrank(OWNER);
        vm.expectRevert(FeeWaterfall.NotTimelock.selector);
        waterfall.setSplit(10_000, 0, 0, 0, 0);
        vm.expectRevert(FeeWaterfall.NotTimelock.selector);
        waterfall.setSwapFee(1, 0);
        vm.expectRevert(FeeWaterfall.NotTimelock.selector);
        waterfall.setRecipient(FeeWaterfall.Bucket.Swarm, OWNER);
        vm.expectRevert(FeeWaterfall.NotTimelock.selector);
        waterfall.rescue(address(tokens[0]), OWNER);
        vm.stopPrank();
    }

    function test_splitMustSumToOneHundredPercent() public {
        vm.startPrank(address(tl));
        vm.expectRevert(FeeWaterfall.InvalidSplit.selector);
        waterfall.setSplit(4000, 2500, 2000, 1000, 499);
        vm.expectRevert(FeeWaterfall.InvalidSplit.selector);
        waterfall.setSplit(4000, 2500, 2000, 1000, 501);
        vm.expectRevert(FeeWaterfall.InvalidBucket.selector);
        waterfall.setRecipient(FeeWaterfall.Bucket.Basket, OWNER);
        vm.stopPrank();
    }

    function test_splitChangeOnlyAffectsLaterFees() public {
        _fees(75 * USDC_UNIT);
        _gov(address(waterfall), abi.encodeCall(waterfall.setSplit, (5000, 2500, 2500, 0, 0)));
        assertEq(_accrued(FeeWaterfall.Bucket.Utility), 5 * USDC_UNIT, "earlier fees keep the earlier split");

        _fees(75 * USDC_UNIT);
        waterfall.distribute();
        assertEq(_accrued(FeeWaterfall.Bucket.Basket), 90 * USDC_UNIT);
        assertEq(_accrued(FeeWaterfall.Bucket.Swarm), 45 * USDC_UNIT);
        assertEq(_accrued(FeeWaterfall.Bucket.Utility), 5 * USDC_UNIT);
        (uint24 lpFee, uint24 hookFee, uint16 basketBps,) = waterfall.feeQuote();
        assertEq(lpFee, 2_500);
        assertEq(hookFee, 7_500);
        assertEq(basketBps, 5000);
    }

    function test_swapFeeIsBoundedAtThreePercentIncludingSurcharge() public {
        vm.startPrank(address(tl));
        vm.expectRevert(FeeWaterfall.FeeTooHigh.selector);
        waterfall.setSwapFee(30_001, 0);
        vm.expectRevert(FeeWaterfall.FeeTooHigh.selector);
        waterfall.setSwapFee(20_000, 10_001);
        waterfall.setSwapFee(20_000, 10_000);
        vm.stopPrank();
        (uint24 lpFee, uint24 hookFee,,) = waterfall.feeQuote();
        assertEq(lpFee, 5_000);
        assertEq(hookFee, 15_000);
    }

    function test_staleBasketSurchargeIsAppliedOnlyWhileStale() public {
        vm.prank(address(tl));
        waterfall.setSwapFee(10_000, 4_000);
        (address[] memory members, uint16[] memory weights) = _topFive();
        _activateBasket(members, weights);
        (uint24 lpFee, uint24 hookFee,,) = waterfall.feeQuote();
        assertEq(uint256(lpFee) + hookFee, 10_000);

        _skip(3 days + 1);
        (lpFee, hookFee,,) = waterfall.feeQuote();
        assertEq(uint256(lpFee) + hookFee, 14_000);
        assertEq(lpFee, 3_500);
    }

    function test_rescueCannotTouchFeeAssets() public {
        MockERC20 stray = new MockERC20("STRAY", 18);
        stray.mint(address(waterfall), 3e18);
        vm.deal(address(waterfall), 1 ether);
        _fees(75 * USDC_UNIT);

        vm.startPrank(address(tl));
        vm.expectRevert(FeeWaterfall.NotRescuable.selector);
        waterfall.rescue(address(usdc), OWNER);
        waterfall.rescue(address(stray), BOB);
        waterfall.rescue(address(0), BOB); // this deployment does not wrap ETH, so stray ETH is recoverable
        vm.stopPrank();
        assertEq(stray.balanceOf(BOB), 3e18);
        assertEq(BOB.balance, 1 ether);
    }
}
