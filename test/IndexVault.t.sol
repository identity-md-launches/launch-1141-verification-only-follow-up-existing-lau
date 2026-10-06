// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {Param} from "../src/interfaces/IIndex.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockERC20} from "./utils/Mocks.sol";

contract IndexVaultTest is Fixture {
    uint256 internal constant SHARE = 1e12; // one whole share: reserve decimals (6) + 6

    function _basketLive(uint256 aliceDeposit) internal {
        _deposit(ALICE, aliceDeposit);
        (address[] memory members, uint16[] memory weights) = _topFive();
        _activateBasket(members, weights);
        _buyBasket();
    }

    // ---------------------------------------------------------------- deposits

    function test_shareTokenMetadata() public view {
        assertEq(vault.name(), "IMD Index Vault Share");
        assertEq(vault.symbol(), "vIMDEX");
        assertEq(vault.decimals(), 12);
        assertEq(vault.asset(), address(usdc));
    }

    function test_firstDepositMintsOneShareUnitPerReserveUnit() public {
        uint256 shares = _deposit(ALICE, 1000 * USDC_UNIT);
        assertEq(shares, 1000 * SHARE);
        assertEq(vault.balanceOf(ALICE), 1000 * SHARE);
        (uint256 nav, bool complete) = vault.nav();
        assertEq(nav, 1000 * USDC_UNIT);
        assertTrue(complete);
        (uint256 perShare,) = vault.navPerShare();
        assertEq(perShare, USDC_UNIT);
    }

    function test_depositRejectsZeroAmountAndZeroReceiver() public {
        usdc.mint(ALICE, 10);
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 10);
        vm.expectRevert(IndexVault.ZeroAmount.selector);
        vault.deposit(0, ALICE, 0);
        vm.expectRevert(IndexVault.ZeroAddress.selector);
        vault.deposit(10, address(0), 0);
        vm.stopPrank();
    }

    function test_depositHonoursMinShares() public {
        usdc.mint(ALICE, 100 * USDC_UNIT);
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 100 * USDC_UNIT);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.InsufficientShares.selector, 100 * SHARE, 100 * SHARE + 1));
        vault.deposit(100 * USDC_UNIT, ALICE, 100 * SHARE + 1);
        vault.deposit(100 * USDC_UNIT, ALICE, 100 * SHARE);
        vm.stopPrank();
    }

    function test_pauseClosesDepositsButNeverRedemptions() public {
        uint256 shares = _deposit(ALICE, 1000 * USDC_UNIT);
        vm.prank(GUARDIAN);
        tl.pause();

        usdc.mint(BOB, 10 * USDC_UNIT);
        vm.startPrank(BOB);
        usdc.approve(address(vault), 10 * USDC_UNIT);
        vm.expectRevert(IndexVault.Paused.selector);
        vault.deposit(10 * USDC_UNIT, BOB, 0);
        vm.stopPrank();

        vm.prank(ALICE);
        vault.redeem(shares, ALICE, true);
        assertGe(usdc.balanceOf(ALICE), 1000 * USDC_UNIT - 1);
    }

    function test_depositsStayClosedUntilAGuardianExists() public {
        // A freshly launched system: nothing configured through the timelock yet.
        Deploy.Deployment memory d = new Deploy()
            .deploy(
                Deploy.Config(
                    OWNER, MIN_DELAY, address(imdex), address(usdc), 6, 1e12, address(0), address(1), address(usdc)
                )
            );
        usdc.mint(ALICE, 10 * USDC_UNIT);
        vm.startPrank(ALICE);
        usdc.approve(address(d.vault), 10 * USDC_UNIT);
        vm.expectRevert(IndexVault.NoGuardian.selector);
        d.vault.deposit(10 * USDC_UNIT, ALICE, 0);
        vm.stopPrank();
    }

    function test_depositCapBoundsTheBeta() public {
        vm.prank(OWNER);
        vm.expectRevert(IndexVault.NotTimelock.selector);
        vault.setDepositCap(1);
        _gov(address(vault), abi.encodeCall(vault.setDepositCap, (1000 * USDC_UNIT)));

        _deposit(ALICE, 600 * USDC_UNIT);
        usdc.mint(BOB, 500 * USDC_UNIT);
        vm.startPrank(BOB);
        usdc.approve(address(vault), 500 * USDC_UNIT);
        vm.expectRevert(IndexVault.DepositCapExceeded.selector);
        vault.deposit(400 * USDC_UNIT + 1, BOB, 0);
        vault.deposit(400 * USDC_UNIT, BOB, 0);
        vm.stopPrank();
    }

    function test_wrongReserveDecimalsAreCaughtOnFirstDeposit() public {
        IndexVault bad = new IndexVault(address(tl), address(registry), address(usdc), 8, type(uint128).max);
        usdc.mint(ALICE, 10 * USDC_UNIT);
        vm.startPrank(ALICE);
        usdc.approve(address(bad), 10 * USDC_UNIT);
        vm.expectRevert(IndexVault.DecimalsMismatch.selector);
        bad.deposit(10 * USDC_UNIT, ALICE, 0);
        vm.stopPrank();
    }

    function test_depositFeeAccruesToExistingHolders() public {
        _deposit(ALICE, 1000 * USDC_UNIT);
        _gov(address(registry), abi.encodeCall(registry.setParam, (Param.DepositFeeBps, 50)));
        uint256 shares = _deposit(BOB, 1000 * USDC_UNIT);
        assertApproxEqRel(shares, 995 * SHARE, 1e12);
        (uint256 perShare,) = vault.navPerShare();
        assertGt(perShare, USDC_UNIT, "the fee stayed in the vault");
    }

    // ---------------------------------------------------------------- NAV and holdings

    function test_navAndHoldingsFollowTheBasketAndPrices() public {
        _basketLive(1_000_000 * USDC_UNIT);
        (uint256 nav, bool complete) = vault.nav();
        assertTrue(complete);
        assertApproxEqRel(nav, 1_000_000 * USDC_UNIT, 1e12, "buying at oracle price keeps NAV");

        (address[] memory held, uint256[] memory balances, uint256[] memory values, bool[] memory priced) =
            vault.holdings();
        assertEq(held.length, 6);
        assertEq(held[0], address(usdc));
        assertApproxEqRel(balances[0], 20_000 * USDC_UNIT, 1e13, "2% reserve buffer stays in the reserve asset");
        for (uint256 i = 1; i < 6; ++i) {
            assertTrue(priced[i]);
            assertApproxEqRel(values[i], 196_000 * USDC_UNIT, 1e13, "20% of the investable 98%");
        }

        feeds[0].set(4000e8); // T0 doubles
        (uint256 navAfter,) = vault.nav();
        assertApproxEqRel(navAfter, 1_196_000 * USDC_UNIT, 1e13);
    }

    function test_laterDepositorPaysCurrentNav() public {
        _basketLive(1_000_000 * USDC_UNIT);
        feeds[0].set(4000e8);
        uint256 aliceShares = vault.balanceOf(ALICE);
        uint256 bobShares = _deposit(BOB, 119_600 * USDC_UNIT); // 10% of the new NAV
        assertApproxEqRel(bobShares, aliceShares / 10, 1e13);
    }

    function test_depositIsRefusedWhileAHeldTokenHasNoFreshPrice() public {
        _basketLive(1_000_000 * USDC_UNIT);
        feeds[2].setUpdatedAt(block.timestamp - 1 days - 1);
        (, bool complete) = vault.nav();
        assertFalse(complete);

        usdc.mint(BOB, 100 * USDC_UNIT);
        vm.startPrank(BOB);
        usdc.approve(address(vault), 100 * USDC_UNIT);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.PriceUnavailable.selector, address(tokens[2])));
        vault.deposit(100 * USDC_UNIT, BOB, 0);
        vm.stopPrank();
        (, bool available) = vault.previewDeposit(100 * USDC_UNIT);
        assertFalse(available);
    }

    // ---------------------------------------------------------------- redemptions

    function test_redeemPaysProRataInKind() public {
        _basketLive(1_000_000 * USDC_UNIT);
        uint256 shares = vault.balanceOf(ALICE);
        (address[] memory held, uint256[] memory preview) = vault.previewRedeem(shares / 4);

        vm.prank(ALICE);
        vault.redeem(shares / 4, BOB, true);
        assertEq(usdc.balanceOf(BOB), preview[0]);
        assertApproxEqRel(usdc.balanceOf(BOB), 5_000 * USDC_UNIT, 1e13);
        for (uint256 i = 1; i < held.length; ++i) {
            uint256 got = MockERC20(held[i]).balanceOf(BOB);
            assertEq(got, preview[i]);
            assertApproxEqRel(_fair(held[i], address(usdc), got), 49_000 * USDC_UNIT, 1e13);
        }
        assertEq(vault.balanceOf(ALICE), shares - shares / 4);
    }

    function test_redeemWorksWithSwarmKeeperAndOraclesAllOffline() public {
        _basketLive(1_000_000 * USDC_UNIT);
        uint256 shares = vault.balanceOf(ALICE);
        // A year passes: no reports, no keeper, every feed stale, and the guardian pauses.
        skip(365 days);
        vm.prank(GUARDIAN);
        tl.pause();
        (, bool complete) = vault.nav();
        assertFalse(complete);

        vm.prank(ALICE);
        vault.redeem(shares, ALICE, true);
        assertEq(vault.totalSupply(), 0);
        for (uint256 i; i < 5; ++i) {
            uint256 paid = tokens[i].balanceOf(ALICE);
            assertGt(paid, 0);
            assertLe(tokens[i].balanceOf(address(vault)), paid / 1e11 + 1, "only virtual-share dust is left");
        }
    }

    function test_redeemRejectsZeroAndMoreThanBalance() public {
        uint256 shares = _deposit(ALICE, 1000 * USDC_UNIT);
        vm.startPrank(ALICE);
        vm.expectRevert(IndexVault.ZeroAmount.selector);
        vault.redeem(0, ALICE, true);
        vm.expectRevert(IndexVault.ZeroAddress.selector);
        vault.redeem(shares, address(0), true);
        vm.expectRevert();
        vault.redeem(shares + 1, ALICE, true);
        vm.stopPrank();
    }

    function test_untransferableTokenCannotTrapHolders() public {
        _basketLive(1_000_000 * USDC_UNIT);
        tokens[1].setBlockedFrom(address(vault)); // T1 turns into a honeypot
        uint256 shares = vault.balanceOf(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.TransferFailed.selector, address(tokens[1])));
        vault.redeem(shares / 2, ALICE, true);

        uint256 stuck = tokens[1].balanceOf(address(vault));
        vm.prank(ALICE);
        vault.redeem(shares / 2, ALICE, false);
        assertEq(tokens[1].balanceOf(ALICE), 0, "skipped");
        assertEq(tokens[1].balanceOf(address(vault)), stuck, "the skipped slice stays for remaining holders");
        assertGt(tokens[0].balanceOf(ALICE), 0);
        assertApproxEqRel(usdc.balanceOf(ALICE), 10_000 * USDC_UNIT, 1e13);
    }

    function test_tokenWithBrokenBalanceOfBlocksDepositsNotRedemptions() public {
        _basketLive(1_000_000 * USDC_UNIT);
        tokens[3].setBalanceReverts(true);
        (, bool complete) = vault.nav();
        assertFalse(complete);

        usdc.mint(BOB, 100 * USDC_UNIT);
        vm.startPrank(BOB);
        usdc.approve(address(vault), 100 * USDC_UNIT);
        vm.expectRevert(abi.encodeWithSelector(IndexVault.PriceUnavailable.selector, address(tokens[3])));
        vault.deposit(100 * USDC_UNIT, BOB, 0);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(ALICE);
        vm.prank(ALICE);
        vault.redeem(shares, ALICE, false);
        assertGt(tokens[0].balanceOf(ALICE), 0);
        assertTrue(vault.isHeld(address(tokens[3])), "an unreadable position is never dropped");
    }

    // ---------------------------------------------------------------- attacks

    function test_donationInflationDoesNotStealFromTheNextDepositor() public {
        address attacker = address(0xBAD);
        usdc.mint(attacker, 10_001 * USDC_UNIT);
        vm.startPrank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        uint256 attackerShares = vault.deposit(1, attacker, 0);
        usdc.transfer(address(vault), 10_000 * USDC_UNIT); // inflate the share price
        vm.stopPrank();

        uint256 victimShares = _deposit(BOB, 5_000 * USDC_UNIT);
        assertGt(victimShares, 0);
        vm.prank(BOB);
        vault.redeem(victimShares, BOB, true);
        assertApproxEqRel(usdc.balanceOf(BOB), 5_000 * USDC_UNIT, 1e15, "victim keeps at least 99.9%");

        vm.prank(attacker);
        vault.redeem(attackerShares, attacker, true);
        assertLt(usdc.balanceOf(attacker), 6_000 * USDC_UNIT, "the donation is lost to the attacker");
    }

    function testFuzz_depositThenRedeemNeverReturnsMore(uint256 assets, uint256 priceMove) public {
        _basketLive(1_000_000 * USDC_UNIT);
        priceMove = bound(priceMove, 5_000, 20_000);
        feeds[0].set(int256(2000e8 * priceMove / 10_000));
        assets = bound(assets, 1, 10_000_000 * USDC_UNIT);

        (uint256 navBefore,) = vault.nav();
        uint256 supplyBefore = vault.totalSupply();
        usdc.mint(BOB, assets);
        vm.startPrank(BOB);
        usdc.approve(address(vault), assets);
        (uint256 expected,) = vault.previewDeposit(assets);
        if (expected == 0) {
            vm.expectRevert();
            vault.deposit(assets, BOB, 0);
            return;
        }
        uint256 shares = vault.deposit(assets, BOB, 0);
        assertEq(shares, expected);
        vault.redeem(shares, BOB, true);
        vm.stopPrank();

        uint256 got = usdc.balanceOf(BOB);
        for (uint256 i; i < 5; ++i) {
            got += _fair(address(tokens[i]), address(usdc), tokens[i].balanceOf(BOB));
        }
        assertLe(got, assets, "a round trip never profits");
        (uint256 navAfter,) = vault.nav();
        assertGe(navAfter + 6, navBefore, "existing holders are not diluted");
        assertEq(vault.totalSupply(), supplyBefore);
    }

    // ---------------------------------------------------------------- access control

    function test_onlyTheExecutorContractMovesAssets() public {
        _deposit(ALICE, 1000 * USDC_UNIT);
        address[4] memory callers = [OWNER, GUARDIAN, KEEPER, address(tl)];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(IndexVault.NotExecutor.selector);
            vault.beginTrade(address(usdc), 1);
            vm.expectRevert(IndexVault.NotExecutor.selector);
            vault.endTrade(address(usdc));
            vm.stopPrank();
        }
    }

    function test_executorCannotTakeUntrackedTokenOrEndWithoutBegin() public {
        _deposit(ALICE, 1000 * USDC_UNIT);
        vm.startPrank(address(executor));
        vm.expectRevert(abi.encodeWithSelector(IndexVault.NotHeld.selector, address(tokens[0])));
        vault.beginTrade(address(tokens[0]), 1);
        vm.expectRevert(IndexVault.Locked.selector);
        vault.endTrade(address(usdc));
        vault.beginTrade(address(usdc), 1);
        vm.expectRevert(IndexVault.Locked.selector);
        vault.beginTrade(address(usdc), 1);
        vm.stopPrank();
    }

    function test_rescueCannotTouchReserveOrBasket() public {
        _basketLive(1_000_000 * USDC_UNIT);
        MockERC20 stray = new MockERC20("STRAY", 18);
        stray.mint(address(vault), 5e18);

        vm.prank(OWNER);
        vm.expectRevert(IndexVault.NotTimelock.selector);
        vault.rescue(address(stray), OWNER);

        vm.startPrank(address(tl));
        vm.expectRevert(IndexVault.NotRescuable.selector);
        vault.rescue(address(usdc), OWNER);
        vm.expectRevert(IndexVault.NotRescuable.selector);
        vault.rescue(address(tokens[0]), OWNER);
        vault.rescue(address(stray), BOB);
        vm.stopPrank();
        assertEq(stray.balanceOf(BOB), 5e18);
    }
}
