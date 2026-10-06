// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {RebalanceExecutor} from "../src/RebalanceExecutor.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {EpochManager} from "../src/EpochManager.sol";
import {Param, Role} from "../src/interfaces/IIndex.sol";
import {FeeOnTransferToken, MockERC20, MockFeed, MockRouter} from "./utils/Mocks.sol";

contract RebalanceExecutorTest is Fixture {
    uint256 internal constant NAV = 1_000_000 * 1e6;
    address internal t0;

    event TradeFailed(
        address indexed sellToken, address indexed buyToken, address indexed router, uint256 sellAmount, bytes reason
    );

    function setUp() public override {
        super.setUp();
        t0 = address(tokens[0]);
        _deposit(ALICE, NAV);
        (address[] memory members, uint16[] memory weights) = _topFive();
        _activateBasket(members, weights);
    }

    function _swapData(address sell, address buy, uint256 amount, uint256 fillBps)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(router.swap, (sell, buy, amount, _fair(sell, buy, amount) * fillBps / 10_000));
    }

    function _expectTradeRevert(address sell, address buy, uint256 amount, bytes memory err) internal {
        bytes memory data = _swapData(sell, buy, amount, 10_000);
        vm.prank(KEEPER);
        vm.expectRevert(err);
        executor.executeTrade(sell, buy, amount, 0, address(router), data);
    }

    function _sel(bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }

    // ---------------------------------------------------------------- building the basket

    function test_buysTheTopFiveAtTwentyPercentAndKeepsTheBuffer() public {
        _buyBasket();
        for (uint256 i; i < 5; ++i) {
            (, uint256 current, uint256 target) = executor.position(address(tokens[i]));
            assertApproxEqRel(target, 196_000 * USDC_UNIT, 1e12, "20% of the 98% that is investable");
            assertApproxEqRel(current, target, 1e12);
            assertTrue(vault.isHeld(address(tokens[i])));
        }
        assertApproxEqRel(usdc.balanceOf(address(vault)), 20_000 * USDC_UNIT, 1e13, "ETH/USDC buffer preserved");
        assertEq(usdc.balanceOf(address(executor)), 0);
        assertEq(usdc.allowance(address(executor), address(router)), 0, "no standing approval");
        assertEq(executor.windowEpoch(), 1);
    }

    function test_cannotBuyBeyondTheTargetDelta() public {
        _expectTradeRevert(
            address(usdc),
            t0,
            196_000 * USDC_UNIT + 1,
            abi.encodeWithSelector(
                RebalanceExecutor.ExceedsDelta.selector, 196_000 * USDC_UNIT + 1, 196_000 * USDC_UNIT
            )
        );
        _buyBasket();
        _expectTradeRevert(address(usdc), t0, 1000 * USDC_UNIT, _sel(RebalanceExecutor.NothingToTrade.selector));
    }

    function test_reserveBufferCannotBeSpent() public {
        _buyBasket();
        // T0 halves: it is now 98k under target, but only the reserve above the buffer may be spent.
        feeds[0].set(1000e8);
        (uint256 nav,,) = executor.position(t0);
        uint256 buffer = nav * 200 / 10_000;
        uint256 spendable = usdc.balanceOf(address(vault)) - buffer;
        _expectTradeRevert(
            address(usdc),
            t0,
            spendable + 1,
            abi.encodeWithSelector(RebalanceExecutor.ExceedsDelta.selector, spendable + 1, spendable)
        );
        (bool ok,) = _trade(address(usdc), t0, spendable, 10_000);
        assertTrue(ok);
        assertEq(usdc.balanceOf(address(vault)), buffer);
    }

    function test_cannotBuyATokenOutsideTheActiveBasket() public {
        _expectTradeRevert(
            address(usdc),
            address(tokens[5]),
            1000 * USDC_UNIT,
            abi.encodeWithSelector(RebalanceExecutor.NotBuyable.selector, address(tokens[5]))
        );
    }

    function test_oneLegMustBeTheReserve() public {
        _buyBasket();
        _expectTradeRevert(t0, address(tokens[1]), 1e18, _sel(RebalanceExecutor.InvalidPair.selector));
        _expectTradeRevert(address(usdc), address(usdc), 1e6, _sel(RebalanceExecutor.InvalidPair.selector));
        _expectTradeRevert(address(usdc), t0, 0, _sel(RebalanceExecutor.ZeroAmount.selector));
    }

    // ---------------------------------------------------------------- only the delta trades

    function test_sellsOnlyTheExcessOverTarget() public {
        _buyBasket();
        _skip(7 days);
        feeds[0].set(4000e8); // T0 doubles to 392k of a 1.196M NAV
        (uint256 nav, uint256 current, uint256 target) = executor.position(t0);
        assertApproxEqRel(nav, 1_196_000 * USDC_UNIT, 1e13);
        uint256 excess = current - target;
        uint256 excessTokens = _fair(address(usdc), t0, excess);

        _expectTradeRevert(
            t0,
            address(usdc),
            excessTokens + 1e15,
            abi.encodeWithSelector(
                RebalanceExecutor.ExceedsDelta.selector, _fair(t0, address(usdc), excessTokens + 1e15), excess
            )
        );
        (bool ok, uint256 out) = _trade(t0, address(usdc), excessTokens, 10_000);
        assertTrue(ok);
        assertApproxEqRel(out, excess, 1e13);
        (, current, target) = executor.position(t0);
        assertApproxEqRel(current, target, 1e13, "back on target");
    }

    function test_cannotSellATokenAtOrBelowTarget() public {
        _buyBasket();
        _expectTradeRevert(address(tokens[4]), address(usdc), 1e18, _sel(RebalanceExecutor.NothingToTrade.selector));
    }

    function test_smallDriftDoesNotTradeButMaterialDriftDoes() public {
        _buyBasket();
        _skip(7 days);
        feeds[0].set(2100e8); // +5% on one asset: about 0.8% of NAV over target
        (, uint256 current, uint256 target) = executor.position(t0);
        uint256 excessTokens = _fair(address(usdc), t0, current - target);
        _expectTradeRevert(t0, address(usdc), excessTokens, _sel(RebalanceExecutor.BelowDriftThreshold.selector));

        feeds[0].set(2500e8); // +25%: about 3.2% of NAV over target, above the 2.5% threshold
        (, current, target) = executor.position(t0);
        (bool ok,) = _trade(t0, address(usdc), _fair(address(usdc), t0, current - target), 10_000);
        assertTrue(ok);
    }

    // ---------------------------------------------------------------- weekly window

    function test_tradesOutsideTheWindowWaitForTheNextInterval() public {
        _buyBasket();
        uint256 opened = executor.windowStart();
        feeds[0].set(4000e8);
        vm.warp(opened + 2 days + 1);
        _touchFeeds();
        (, uint256 current, uint256 target) = executor.position(t0);
        uint256 excessTokens = _fair(address(usdc), t0, current - target);
        _expectTradeRevert(t0, address(usdc), excessTokens, _sel(RebalanceExecutor.WindowClosed.selector));

        vm.warp(opened + 7 days - 1);
        _touchFeeds();
        _expectTradeRevert(t0, address(usdc), excessTokens, _sel(RebalanceExecutor.WindowClosed.selector));

        vm.warp(opened + 7 days);
        _touchFeeds();
        (bool ok,) = _trade(t0, address(usdc), excessTokens, 10_000);
        assertTrue(ok);
        assertEq(executor.windowStart(), opened + 7 days);
    }

    function test_noTradingBeforeAnyBasketIsActive() public {
        // A second, unconfigured deployment sharing nothing: use a fresh executor wired to a fresh epoch manager.
        EpochManager emptyEpochs = new EpochManager(address(tl), address(registry));
        RebalanceExecutor other =
            new RebalanceExecutor(address(tl), address(registry), address(emptyEpochs), address(vault));
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutor.NotBuyable.selector, t0));
        other.executeTrade(address(usdc), t0, 1e6, 0, address(router), "");
    }

    // ---------------------------------------------------------------- price protection

    function test_fillBelowTheOracleFloorIsUndoneAndCounted() public {
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.expectEmit(true, true, true, false);
        emit TradeFailed(address(usdc), t0, address(router), 100_000 * USDC_UNIT, "");
        (bool ok, uint256 out) = _trade(address(usdc), t0, 100_000 * USDC_UNIT, 9_899); // 1.01% worse than oracle
        assertFalse(ok);
        assertEq(out, 0);
        assertEq(usdc.balanceOf(address(vault)), vaultBefore, "vault untouched");
        assertEq(tokens[0].balanceOf(address(vault)), 0);
        assertFalse(vault.isHeld(t0));
        assertEq(executor.failureCount(t0), 1);
        assertEq(usdc.allowance(address(executor), address(router)), 0);
        (uint256 nav, bool complete) = vault.nav(); // the lock was released with the rollback
        assertEq(nav, NAV);
        assertTrue(complete);
    }

    function test_fillAtTheSlippageLimitSucceedsAndResetsTheFailureCount() public {
        _trade(address(usdc), t0, 100_000 * USDC_UNIT, 9_000);
        assertEq(executor.failureCount(t0), 1);
        (bool ok, uint256 out) = _trade(address(usdc), t0, 100_000 * USDC_UNIT, 9_900);
        assertTrue(ok);
        assertEq(out, 49.5e18);
        assertEq(executor.failureCount(t0), 0);
    }

    function test_keeperFloorAppliesWhenStricterThanTheOracleFloor() public {
        bytes memory data = _swapData(address(usdc), t0, 100_000 * USDC_UNIT, 9_950);
        vm.prank(KEEPER);
        (bool ok,) = executor.executeTrade(address(usdc), t0, 100_000 * USDC_UNIT, 50e18, address(router), data);
        assertFalse(ok, "keeper asked for the full oracle amount");
    }

    function testFuzz_sandwichedFillNeverCostsMoreThanTheSlippageLimit(uint256 fillBps, uint256 amount) public {
        fillBps = bound(fillBps, 0, 12_000);
        amount = bound(amount, 30_000 * USDC_UNIT, 196_000 * USDC_UNIT);
        (uint256 navBefore,) = vault.nav();
        (bool ok,) = _trade(address(usdc), t0, amount, fillBps);
        (uint256 navAfter,) = vault.nav();

        assertEq(ok, fillBps >= 9_900, "accepted exactly when the fill is within 1% of the oracle");
        if (ok) assertGe(navAfter + amount / 100 + 1, navBefore, "loss bounded by MaxSlippageBps of the trade");
        else assertEq(navAfter, navBefore, "a refused fill changes nothing");
        assertEq(usdc.balanceOf(address(executor)), 0);
        assertEq(tokens[0].balanceOf(address(executor)), 0);
    }

    function test_partialFillReturnsTheUnsoldRemainder() public {
        // The router takes only half the input but still delivers the full floor.
        bytes memory data = abi.encodeCall(router.swap, (address(usdc), t0, 50_000 * USDC_UNIT, 50e18));
        vm.prank(KEEPER);
        (bool ok, uint256 out) = executor.executeTrade(address(usdc), t0, 100_000 * USDC_UNIT, 0, address(router), data);
        assertTrue(ok);
        assertEq(out, 50e18);
        assertEq(usdc.balanceOf(address(vault)), NAV - 50_000 * USDC_UNIT);
        assertEq(usdc.balanceOf(address(executor)), 0);
    }

    function test_staleOracleStopsATradeUntilTheTokenIsQuarantined() public {
        _buyBasket();
        _skip(7 days);
        feeds[1].set(200e8); // T1 doubles: it needs selling
        feeds[3].setUpdatedAt(block.timestamp - 1 days - 1); // while T3's feed dies

        (uint256 excessTokens) = 980e18; // roughly half of the 1,960 T1 held
        bytes memory data = abi.encodeCall(router.swap, (address(tokens[1]), address(usdc), excessTokens, 196_000e6));
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutor.UnpricedHolding.selector, address(tokens[3])));
        executor.executeTrade(address(tokens[1]), address(usdc), excessTokens, 0, address(router), data);

        registry.quarantineIfStale(address(tokens[3])); // anyone
        (, uint256 current, uint256 target) = executor.position(address(tokens[1]));
        excessTokens = _fair(address(usdc), address(tokens[1]), current - target);
        (bool ok,) = _trade(address(tokens[1]), address(usdc), excessTokens, 10_000);
        assertTrue(ok, "the rest of the basket keeps working");
    }

    function test_dustTradeWithNoEnforceableFloorIsRefused() public {
        _gov(address(registry), abi.encodeCall(registry.setParam, (Param.DriftThresholdBps, 0)));
        // 40 millionths of a dollar buys less than one unit of an 8-decimal, $60,000 token.
        bytes memory data = abi.encodeCall(router.swap, (address(usdc), address(tokens[2]), 40, 0));
        vm.prank(KEEPER);
        vm.expectRevert(RebalanceExecutor.NothingToTrade.selector);
        executor.executeTrade(address(usdc), address(tokens[2]), 40, 0, address(router), data);
    }

    // ---------------------------------------------------------------- failed assets are quarantined

    function test_repeatedFailuresQuarantineTheAssetInsteadOfBlockingTheBasket() public {
        bytes memory bad = abi.encodeCall(router.fail, ());
        for (uint256 i; i < 3; ++i) {
            vm.prank(KEEPER);
            (bool ok,) = executor.executeTrade(address(usdc), t0, 100_000 * USDC_UNIT, 0, address(router), bad);
            assertFalse(ok);
        }
        assertTrue(registry.isAutoQuarantined(t0));
        assertFalse(registry.isQuarantined(t0));
        assertEq(executor.failureCount(t0), 3);

        _expectTradeRevert(
            address(usdc), t0, 1000 * USDC_UNIT, abi.encodeWithSelector(RebalanceExecutor.NotBuyable.selector, t0)
        );
        // The other four members are unaffected.
        _buyBasket();
        for (uint256 i = 1; i < 5; ++i) {
            assertTrue(vault.isHeld(address(tokens[i])));
        }
        (,, uint256 target) = executor.position(t0);
        assertApproxEqAbs(target, 196_000 * USDC_UNIT, 1000, "router failures do not rewrite the signed target");
    }

    function test_quarantinedPositionCanBeExitedAtAnyTime() public {
        _buyBasket();
        vm.prank(GUARDIAN);
        registry.quarantine(t0);
        _skip(3 days); // the rebalance window is closed
        uint256 balance = tokens[0].balanceOf(address(vault));

        _expectTradeRevert(
            t0,
            address(usdc),
            balance + 1,
            abi.encodeWithSelector(RebalanceExecutor.ExceedsDelta.selector, balance + 1, balance)
        );
        (bool ok, uint256 out) = _trade(t0, address(usdc), balance, 9_950);
        assertTrue(ok);
        assertApproxEqRel(out, 196_000 * USDC_UNIT * 995 / 1000, 1e13);
        assertFalse(vault.isHeld(t0), "an emptied position is no longer tracked");
        assertEq(vault.heldTokens().length, 4);
    }

    function test_quarantinedTokenWithDeadFeedIsDisposedThroughTheTimelock() public {
        _buyBasket();
        feeds[0].setReverts(true);
        registry.quarantineIfStale(t0);
        uint256 balance = tokens[0].balanceOf(address(vault));

        // The keeper path cannot price it.
        bytes memory data = abi.encodeCall(router.swap, (t0, address(usdc), balance, 150_000 * USDC_UNIT));
        vm.prank(KEEPER);
        vm.expectRevert(RebalanceExecutor.PriceUnavailable.selector);
        executor.executeTrade(t0, address(usdc), balance, 0, address(router), data);

        vm.prank(OWNER);
        vm.expectRevert(RebalanceExecutor.NotTimelock.selector);
        executor.disposeQuarantined(t0, balance, 150_000 * USDC_UNIT, address(router), data);

        uint256 reserveBefore = usdc.balanceOf(address(vault));
        _gov(
            address(executor),
            abi.encodeCall(executor.disposeQuarantined, (t0, balance, 150_000 * USDC_UNIT, address(router), data))
        );
        assertEq(usdc.balanceOf(address(vault)), reserveBefore + 150_000 * USDC_UNIT);
        assertFalse(vault.isHeld(t0));
    }

    function test_disposalIsOnlyForQuarantinedTokensAndEnforcesItsFloor() public {
        _buyBasket();
        uint256 balance = tokens[0].balanceOf(address(vault));
        bytes memory data = abi.encodeCall(router.swap, (t0, address(usdc), balance, 100_000 * USDC_UNIT));
        vm.startPrank(address(tl));
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutor.NotQuarantined.selector, t0));
        executor.disposeQuarantined(t0, balance, 150_000 * USDC_UNIT, address(router), data);
        vm.stopPrank();

        vm.prank(GUARDIAN);
        registry.quarantine(t0);
        vm.startPrank(address(tl));
        vm.expectRevert(
            abi.encodeWithSelector(
                RebalanceExecutor.InsufficientOutput.selector, 100_000 * USDC_UNIT, 150_000 * USDC_UNIT
            )
        );
        executor.disposeQuarantined(t0, balance, 150_000 * USDC_UNIT, address(router), data);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- membership changes

    function test_removedMemberIsSoldAndItsReplacementBought() public {
        _buyBasket();
        (address[] memory members, uint16[] memory weights) = _topFive();
        members[4] = address(tokens[5]); // T4 out, T5 in
        _activateBasket(members, weights);
        assertEq(epochs.epoch(), 2);

        uint256 balance = tokens[4].balanceOf(address(vault));
        (bool ok,) = _trade(address(tokens[4]), address(usdc), balance, 10_000);
        assertTrue(ok);
        assertFalse(vault.isHeld(address(tokens[4])));

        (, uint256 current, uint256 target) = executor.position(address(tokens[5]));
        (ok,) = _trade(address(usdc), address(tokens[5]), target - current, 10_000);
        assertTrue(ok);
        assertTrue(vault.isHeld(address(tokens[5])));
        assertEq(executor.windowEpoch(), 2);
        _expectTradeRevert(
            address(usdc),
            address(tokens[4]),
            1000 * USDC_UNIT,
            abi.encodeWithSelector(RebalanceExecutor.NotBuyable.selector, address(tokens[4]))
        );
    }

    // ---------------------------------------------------------------- access control and routing

    function test_onlyKeepersTrade() public {
        bytes memory data = _swapData(address(usdc), t0, 1000 * USDC_UNIT, 10_000);
        address[4] memory callers = [OWNER, GUARDIAN, vm.addr(signerKeys[0]), BOB];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(RebalanceExecutor.NotKeeper.selector);
            executor.executeTrade(address(usdc), t0, 1000 * USDC_UNIT, 0, address(router), data);
        }
        vm.prank(GUARDIAN);
        tl.revokeKeeper(KEEPER);
        vm.prank(KEEPER);
        vm.expectRevert(RebalanceExecutor.NotKeeper.selector);
        executor.executeTrade(address(usdc), t0, 1000 * USDC_UNIT, 0, address(router), data);
    }

    function test_pauseStopsTrading() public {
        vm.prank(GUARDIAN);
        tl.pause();
        _expectTradeRevert(address(usdc), t0, 1000 * USDC_UNIT, _sel(RebalanceExecutor.Paused.selector));
    }

    function test_onlyAllowlistedRoutersAndNeverProjectContracts() public {
        MockRouter rogue = new MockRouter();
        bytes memory data = _swapData(address(usdc), t0, 1000 * USDC_UNIT, 10_000);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutor.RouterNotApproved.selector, address(rogue)));
        executor.executeTrade(address(usdc), t0, 1000 * USDC_UNIT, 0, address(rogue), data);

        // Even if governance allowlisted the vault or a token by mistake, the executor refuses to call it.
        _queue(address(registry), abi.encodeCall(registry.setRouter, (address(vault), true)));
        _queue(address(registry), abi.encodeCall(registry.setRouter, (address(usdc), true)));
        _flush();
        vm.startPrank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutor.RouterNotApproved.selector, address(vault)));
        executor.executeTrade(address(usdc), t0, 1000 * USDC_UNIT, 0, address(vault), data);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutor.RouterNotApproved.selector, address(usdc)));
        executor.executeTrade(address(usdc), t0, 1000 * USDC_UNIT, 0, address(usdc), data);
        vm.stopPrank();
    }

    function test_swapEntryPointIsNotCallableFromOutside() public {
        vm.prank(KEEPER);
        vm.expectRevert(RebalanceExecutor.NotSelf.selector);
        executor.swapThroughRouter(address(usdc), t0, 1e6, 0, address(router), "");
    }

    function test_routerCannotReenterVaultOrExecutorDuringASwap() public {
        uint256 amount = 100_000 * USDC_UNIT;
        bytes memory data = abi.encodeCall(router.swapAndReenter, (address(usdc), t0, amount, 50e18));
        vm.prank(KEEPER);
        (bool ok,) = executor.executeTrade(address(usdc), t0, amount, 0, address(router), data);
        assertTrue(ok, "the honest part of the swap completes");
        assertEq(router.blockedCalls(), 4, "deposit, redeem, NAV read and nested trade were all refused");
        assertEq(vault.balanceOf(address(router)), 0, "no shares minted against a half-empty vault");
    }

    function test_replacedExecutorLosesAccessToTheVault() public {
        RebalanceExecutor next = new RebalanceExecutor(address(tl), address(registry), address(epochs), address(vault));
        _gov(address(tl), abi.encodeCall(tl.setExecutor, (address(next))));
        assertEq(uint8(tl.roleOf(address(executor))), uint8(Role.None));

        (bool ok,) = _trade(address(usdc), t0, 100_000 * USDC_UNIT, 10_000);
        assertFalse(ok, "the old executor's swap is refused by the vault");
        assertEq(usdc.balanceOf(address(vault)), NAV);

        bytes memory data = _swapData(address(usdc), t0, 100_000 * USDC_UNIT, 10_000);
        vm.prank(KEEPER);
        (ok,) = next.executeTrade(address(usdc), t0, 100_000 * USDC_UNIT, 0, address(router), data);
        assertTrue(ok);
    }

    function test_outputIsMeasuredOnTheVaultSoFeeOnTransferTokensFailTheFloor() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        MockFeed feed = new MockFeed(8, 1e8);
        fot.mint(address(router), 1e30);
        _gov(
            address(registry),
            abi.encodeCall(
                registry.approveToken,
                (address(fot), address(feed), 7 days, 2000, uint40(block.timestamp - 31 days), bytes32(0))
            )
        );
        feed.touch();
        (address[] memory members, uint16[] memory weights) = _topFive();
        members[4] = address(fot);
        _activateBasket(members, weights);

        // The router sends the full oracle amount, but 19% is lost across the two transfers.
        (bool ok,) = _trade(address(usdc), address(fot), 100_000 * USDC_UNIT, 10_000);
        assertFalse(ok);
        assertEq(fot.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), NAV);
    }
}
