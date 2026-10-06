// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {MockERC20} from "./utils/Mocks.sol";
import {TimelockedAdmin} from "../src/TimelockedAdmin.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {EpochManager} from "../src/EpochManager.sol";
import {RebalanceExecutor} from "../src/RebalanceExecutor.sol";
import {Param} from "../src/interfaces/IIndex.sol";

contract GasBurningBalance {
    function balanceOf(address) external pure returns (uint256) {
        assembly { invalid() }
    }
}

contract RevisionTest is Fixture {
    uint256 private constant NAV = 1_000_000e6;

    function _live(bool buy) private {
        _deposit(ALICE, NAV);
        (address[] memory members, uint16[] memory weights) = _topFive();
        _activateBasket(members, weights);
        if (buy) _buyBasket();
        vm.roll(block.number + 1);
    }

    function _fail(address sell, address buy) private {
        vm.prank(KEEPER);
        (bool ok,) = executor.executeTrade(
            sell, buy, sell == address(usdc) ? 1000e6 : 1e18, 0, address(router), abi.encodeCall(router.fail, ())
        );
        assertFalse(ok);
    }

    function test_strictUnreadableBalancePreservesSharesAfterHoldingPeriod() public {
        _live(true);
        tokens[3].setBalanceReverts(true);
        uint256 shares = vault.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.TransferFailed.selector, address(tokens[3])));
        vault.redeem(shares, ALICE, true);
        assertEq(vault.balanceOf(ALICE), shares);
    }

    function test_keeperFailuresCannotCreateExitRightsForAnyMember() public {
        _live(true);
        _deposit(KEEPER, 150_000e6);
        for (uint256 i; i < 5; ++i) {
            address token = address(tokens[i]);
            for (uint256 j; j < 3; ++j) {
                _fail(address(usdc), token);
            }
            (,, uint256 target) = executor.position(token);
            assertGt(target, 0, "keeper manufactured a zero target");
            uint256 balance = tokens[i].balanceOf(address(vault));
            vm.prank(KEEPER);
            vm.expectRevert(RebalanceExecutor.NothingToTrade.selector);
            executor.executeTrade(token, address(usdc), balance, 0, address(router), "");
        }
        assertEq(vault.heldTokens().length, 5);
    }

    function test_releaseStartsANewFailureStreak() public {
        _live(true);
        feeds[0].set(8000e8);
        address token = address(tokens[0]);
        for (uint256 j; j < 3; ++j) {
            _fail(token, address(usdc));
        }
        _gov(address(registry), abi.encodeCall(registry.releaseQuarantine, (token)));
        // Governance took two days, so use the next scheduled window.
        vm.warp(uint256(epochs.activeBasket().activatedAt) + 7 days);
        _touchFeeds();
        _fail(token, address(usdc));
        assertFalse(registry.isQuarantined(token), "one failure restored the quarantine");
        assertEq(executor.failureCount(token), 1);
    }

    function test_newSharesCannotRedeemInTheirDepositBlock() public {
        _live(true);
        usdc.mint(BOB, NAV);
        vm.startPrank(BOB);
        usdc.approve(address(vault), NAV);
        uint256 shares = vault.deposit(NAV, BOB, 0);
        vm.expectRevert(bytes4(keccak256("SharesLocked()")));
        vault.redeem(shares, BOB, true);
        vm.roll(block.number + 1);
        vault.redeem(shares, BOB, true);
        vm.stopPrank();
    }

    function test_newSharesCannotTransferOrTransferFromToBypassLock() public {
        _live(true);
        usdc.mint(BOB, NAV);
        vm.startPrank(BOB);
        usdc.approve(address(vault), NAV);
        uint256 shares = vault.deposit(NAV, BOB, 0);
        vm.expectRevert(bytes4(keccak256("SharesLocked()")));
        vault.transfer(ALICE, shares);
        vault.approve(ALICE, shares);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(bytes4(keccak256("SharesLocked()")));
        vault.transferFrom(BOB, ALICE, shares);
    }

    function test_heldQuarantineClosesDepositsEvenWithFreshFeed() public {
        _live(true);
        tokens[0].setBlockedFrom(address(vault));
        vm.prank(GUARDIAN);
        registry.quarantine(address(tokens[0]));
        usdc.mint(BOB, 100_000e6);
        vm.startPrank(BOB);
        usdc.approve(address(vault), 100_000e6);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.PriceUnavailable.selector, address(tokens[0])));
        vault.deposit(100_000e6, BOB, 0);
        vm.stopPrank();
    }

    function test_deadUntransferablePositionPreservesClaimsAndClosesDeposits() public {
        _live(true);
        tokens[0].setBlockedFrom(address(vault));
        feeds[0].setReverts(true);
        registry.quarantineIfStale(address(tokens[0]));
        usdc.mint(BOB, 100e6);
        vm.startPrank(BOB);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.PriceUnavailable.selector, address(tokens[0])));
        vault.deposit(100e6, BOB, 0);
        vm.stopPrank();
        usdc.mint(address(waterfall), 10_000e6);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.PriceUnavailable.selector, address(tokens[0])));
        waterfall.pushBasketReserve(0);
        uint256 balance = tokens[0].balanceOf(address(vault));
        vm.prank(address(tl));
        vm.expectRevert(bytes("transfers blocked"));
        executor.disposeQuarantined(address(tokens[0]), balance, 1, address(router), "");
        assertTrue(vault.isHeld(address(tokens[0])));
        uint256 shares = vault.balanceOf(ALICE) / 10;
        vm.prank(ALICE);
        vault.redeem(shares, ALICE, false);
        assertGt(tokens[1].balanceOf(ALICE), 0);
    }

    function test_quarantinedGasBurnerCannotStopUnrelatedTrades() public {
        _live(true);
        address token = address(tokens[1]);
        GasBurningBalance burner = new GasBurningBalance();
        vm.etch(token, address(burner).code);
        vm.prank(GUARDIAN);
        registry.quarantine(token);
        feeds[0].set(4000e8);
        vm.prank(KEEPER);
        (bool ok,) = executor.executeTrade{gas: 10_000_000}(
            address(tokens[0]),
            address(usdc),
            1e18,
            0,
            address(router),
            abi.encodeCall(router.swap, (address(tokens[0]), address(usdc), 1e18, 4000e6))
        );
        assertTrue(ok);
    }

    function test_emptyBasketCannotResetTurnoverHistory() public {
        _live(false);
        _skip(7 days);
        EpochManager.Proposal memory p = _proposal(new address[](0), new uint16[](0));
        bytes[] memory sigs = _sign(p);
        vm.expectRevert(EpochManager.Malformed.selector);
        epochs.publish(p, sigs);
    }

    function test_firstTradeCannotChooseWindowStart() public {
        _live(false);
        _skip(20 days);
        vm.prank(KEEPER);
        vm.expectRevert(RebalanceExecutor.WindowClosed.selector);
        executor.executeTrade(address(usdc), address(tokens[0]), 1000e6, 0, address(router), "");
    }

    function test_fullDustExitCanFreeHeldSlot() public {
        _live(true);
        address token = address(tokens[0]);
        vm.prank(GUARDIAN);
        registry.quarantine(token);
        uint256 balance = tokens[0].balanceOf(address(vault));
        (bool ok,) = _trade(token, address(usdc), balance - 1, 10_000);
        assertTrue(ok);
        assertEq(tokens[0].balanceOf(address(vault)), 1);
        (ok,) = _trade(token, address(usdc), 1, 10_000);
        assertTrue(ok);
        assertFalse(vault.isHeld(token));
    }

    function test_untrackedDonationDoesNotBlockMemberPurchase() public {
        _live(false);
        address token = address(tokens[0]);
        tokens[0].mint(address(vault), 99e18);
        (, uint256 current,) = executor.position(token);
        assertEq(current, 0, "untracked donation included in current but excluded from NAV");
        (bool ok,) = _trade(address(usdc), token, 1000e6, 10_000);
        assertTrue(ok);
        assertTrue(vault.isHeld(token));
    }

    function test_onlyKeeperOrTimelockChoosesTreasuryDepositTime() public {
        usdc.mint(address(waterfall), 10_000e6);
        vm.prank(BOB);
        vm.expectRevert(bytes4(keccak256("NotAuthorized()")));
        waterfall.pushBasketReserve(0);
        vm.prank(KEEPER);
        assertGt(waterfall.pushBasketReserve(0), 0);
    }

    function test_proposalDelayCannotConsumeEntireValidityPeriod() public {
        vm.prank(address(tl));
        vm.expectRevert(AssetRegistry.InvalidValue.selector);
        registry.setParam(Param.ProposalDelay, 7 days);
    }

    function test_firstDepositChecksRegistryReserveScale() public {
        AssetRegistry wrong = new AssetRegistry(address(tl), address(usdc), 18);
        IndexVault other = new IndexVault(address(tl), address(wrong), address(usdc), 6, type(uint128).max);
        usdc.mint(BOB, 1000e6);
        vm.startPrank(BOB);
        usdc.approve(address(other), 1000e6);
        vm.expectRevert(IndexVault.DecimalsMismatch.selector);
        other.deposit(1000e6, BOB, 0);
        vm.stopPrank();
    }

    function _recovery(bytes memory data, bytes32 salt) private returns (bytes32 id) {
        vm.prank(OWNER);
        id = tl.schedule(address(tl), 0, data, salt, MIN_DELAY);
        vm.prank(GUARDIAN);
        vm.expectRevert(TimelockedAdmin.RecoveryCannotBeVetoed.selector);
        tl.cancel(id);
        _skip(MIN_DELAY);
        vm.prank(OWNER);
        tl.execute(address(tl), 0, data, salt);
        assertEq(tl.readyAt(id), 0);
        assertFalse(tl.recoveryOperation(id));
    }

    function test_guardianCannotVetoReplacementOrUnpause() public {
        vm.prank(GUARDIAN);
        tl.pause();
        _recovery(abi.encodeCall(tl.unpause, ()), bytes32("unpause"));
        assertFalse(tl.paused());
        _recovery(abi.encodeCall(tl.setGuardian, (BOB)), bytes32("replace"));
        assertEq(tl.guardian(), BOB);
        vm.prank(GUARDIAN);
        vm.expectRevert(TimelockedAdmin.NotGuardian.selector);
        tl.pause();
    }

    function test_adminCanCancelRecoveryAndGuardianStillVetoesOtherCalls() public {
        bytes memory data = abi.encodeCall(tl.setGuardian, (BOB));
        vm.prank(OWNER);
        bytes32 id = tl.schedule(address(tl), 0, data, bytes32("admin cancel"), MIN_DELAY);
        vm.prank(OWNER);
        tl.cancel(id);
        assertEq(tl.readyAt(id), 0);
        assertFalse(tl.recoveryOperation(id));
        // Even the same selector gets no exemption when aimed at another contract.
        vm.prank(OWNER);
        id = tl.schedule(address(router), 0, data, bytes32("external target"), MIN_DELAY);
        vm.prank(GUARDIAN);
        tl.cancel(id);
        assertEq(tl.readyAt(id), 0);
        vm.prank(OWNER);
        id = tl.schedule(address(tl), 0, abi.encodeCall(tl.setKeeper, (BOB, true)), 0, MIN_DELAY);
        vm.prank(GUARDIAN);
        tl.cancel(id);
        assertEq(tl.readyAt(id), 0);
    }

    function test_activationRechecksSnapshotAgeWithFreshPrices() public {
        (address[] memory members, uint16[] memory weights) = _topFive();
        EpochManager.Proposal memory p = _proposal(members, weights);
        p.snapshotTime = uint64(block.timestamp);
        p.expiry = uint64(block.timestamp + 3 days);
        _publish(p);
        _skip(25 hours);
        assertTrue(registry.isEligible(members[0]));
        vm.expectRevert(EpochManager.StaleSnapshot.selector);
        epochs.activate();
        assertEq(epochs.epoch(), 0);
    }

    function test_activationAtSnapshotAgeBoundarySucceeds() public {
        (address[] memory members, uint16[] memory weights) = _topFive();
        EpochManager.Proposal memory p = _proposal(members, weights);
        p.snapshotTime = uint64(block.timestamp);
        _publish(p);
        _skip(1 days);
        epochs.activate();
        assertEq(epochs.epoch(), 1);
    }

    function test_autoQuarantineDoesNotVetoProposalOrCloseFairDeposits() public {
        _live(false);
        _skip(7 days);
        (address[] memory members, uint16[] memory weights) = _topFive();
        _publish(_proposal(members, weights));
        for (uint256 j; j < 3; ++j) {
            _fail(address(usdc), members[0]);
        }
        assertTrue(registry.isAutoQuarantined(members[0]));
        assertTrue(registry.isEligible(members[0]));
        _skip(6 hours);
        epochs.activate();
        assertEq(epochs.epoch(), 2);
        assertGt(_deposit(BOB, 100e6), 0);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutor.NotBuyable.selector, members[0]));
        executor.executeTrade(address(usdc), members[0], 1000e6, 0, address(router), "");
    }

    function test_autoQuarantineRetainsDeltaAndWindowUntilGuardianConfirms() public {
        _live(true);
        address token = address(tokens[0]);
        feeds[0].set(4000e8);
        for (uint256 j; j < 3; ++j) {
            _fail(token, address(usdc));
        }
        assertTrue(registry.isAutoQuarantined(token));
        uint256 balance = tokens[0].balanceOf(address(vault));
        vm.prank(KEEPER);
        vm.expectPartialRevert(RebalanceExecutor.ExceedsDelta.selector);
        executor.executeTrade(token, address(usdc), balance, 0, address(router), "");
        _skip(3 days);
        vm.prank(KEEPER);
        vm.expectRevert(RebalanceExecutor.WindowClosed.selector);
        executor.executeTrade(token, address(usdc), 1e18, 0, address(router), "");
        vm.prank(GUARDIAN);
        registry.quarantine(token);
        (bool ok,) = _trade(token, address(usdc), balance, 10_000);
        assertTrue(ok);
        assertFalse(vault.isHeld(token));
    }

    function test_dustDepositCannotLockExistingShares() public {
        _live(true);
        uint256 oldShares = vault.balanceOf(ALICE);
        usdc.mint(BOB, 2);
        vm.startPrank(BOB);
        usdc.approve(address(vault), 2);
        uint256 locked = vault.deposit(1, ALICE, 0);
        locked += vault.deposit(1, ALICE, 0);
        vm.stopPrank();
        vm.startPrank(ALICE);
        vault.redeem(oldShares, ALICE, true);
        assertEq(vault.balanceOf(ALICE), locked);
        vm.expectRevert(IndexVault.SharesLocked.selector);
        vault.redeem(locked, ALICE, true);
        vm.roll(block.number + 1);
        vault.redeem(locked, ALICE, true);
        vm.stopPrank();
    }

    event RedemptionSkipped(address indexed receiver, address indexed token, uint256 amount);

    function test_unreadableNonStrictRedemptionEmitsUnknownSkippedSlice() public {
        _live(true);
        tokens[3].setBalanceReverts(true);
        uint256 shares = vault.balanceOf(ALICE);
        vm.expectEmit(true, true, false, true, address(vault));
        emit RedemptionSkipped(ALICE, address(tokens[3]), 0);
        vm.prank(ALICE);
        vault.redeem(shares, ALICE, false);
        assertEq(vault.balanceOf(ALICE), 0);
        assertGt(tokens[0].balanceOf(ALICE), 0);
    }

    function test_gasBurningUnquarantinedBalanceFailsWithBoundedError() public {
        _live(true);
        GasBurningBalance burner = new GasBurningBalance();
        vm.etch(address(tokens[0]), address(burner).code);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutor.UnpricedHolding.selector, address(tokens[0])));
        executor.position{gas: 1_000_000}(address(tokens[0]));
        vm.prank(GUARDIAN);
        registry.quarantine(address(tokens[0]));
        // NAV now skips it before balanceOf; the position-specific read is still gas-capped.
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutor.UnpricedHolding.selector, address(tokens[0])));
        executor.position{gas: 2_000_000}(address(tokens[0]));
    }

    function test_lateFirstTradeUsesTheActivationSchedule() public {
        _live(false);
        uint256 activated = epochs.activeBasket().activatedAt;
        _skip(22 days);
        (bool ok,) = _trade(address(usdc), address(tokens[0]), 1000e6, 10_000);
        assertTrue(ok);
        assertEq(executor.windowStart(), activated + 21 days);
        vm.warp(activated + 23 days + 1);
        _touchFeeds();
        vm.prank(KEEPER);
        vm.expectRevert(RebalanceExecutor.WindowClosed.selector);
        executor.executeTrade(address(usdc), address(tokens[0]), 1000e6, 0, address(router), "");
    }

    function test_proposalDelayAndSnapshotAgeMustLeaveExecutionTime() public {
        vm.startPrank(address(tl));
        vm.expectRevert(AssetRegistry.InvalidValue.selector);
        registry.setParam(Param.ProposalDelay, 1 days);
        vm.expectRevert(AssetRegistry.InvalidValue.selector);
        registry.setParam(Param.MaxSnapshotAge, 6 hours);
        registry.setParam(Param.MaxSnapshotAge, 7 days);
        registry.setParam(Param.ProposalDelay, 7 days - 1 hours);
        vm.stopPrank();
        (address[] memory members, uint16[] memory weights) = _topFive();
        EpochManager.Proposal memory p = _proposal(members, weights);
        p.snapshotTime = uint64(block.timestamp);
        p.expiry = uint64(block.timestamp + 7 days);
        _publish(p);
        _skip(7 days - 1 hours);
        epochs.activate();
        assertEq(epochs.epoch(), 1);
    }
}
