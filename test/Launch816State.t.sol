// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Launch816Live} from "./utils/Launch816Live.sol";
import {MockWETH} from "./utils/Mocks.sol";
import {TimelockedAdmin} from "../src/TimelockedAdmin.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EpochManager} from "../src/EpochManager.sol";
import {IndexVault} from "../src/IndexVault.sol";
import {RebalanceExecutor} from "../src/RebalanceExecutor.sol";
import {FeeWaterfall} from "../src/FeeWaterfall.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {FeeHookDeployer} from "../src/FeeHookDeployer.sol";
import {Param, Role} from "../src/interfaces/IIndex.sol";

/// @dev Launch 816 verification follow-up, brief item 6 and the manifest notes' claims about the
/// launched state: no role is assigned, nothing is configured, deposits and trading are closed, and
/// every privileged entry point refuses the owner wallet, the factory and strangers until the
/// timelock has run. Then the one path that opens the system is exercised with the exact literals.
contract Launch816StateTest is Launch816Live {
    function setUp() public {
        _launch();
    }

    // ---------------------------------------------------------------- nothing granted, nothing configured

    function testFuzz_noAddressHoldsAnyRoleOrAllowlistEntry(address who) public view {
        assertEq(uint256(tl.roleOf(who)), uint256(Role.None));
        assertFalse(registry.isRouterApproved(who));
        assertFalse(registry.isApproved(who));
        assertFalse(registry.isQuarantined(who));
        assertFalse(registry.isAutoQuarantined(who));
        assertFalse(registry.isEligible(who));
        assertEq(vault.balanceOf(who), 0);
        assertEq(epochs.targetWeightBps(who), 0);
        assertEq(token.balanceOf(who), who == address(factory) ? token.TOTAL_SUPPLY() : 0);
    }

    function test_timelockStartsWithOnlyTheOwnerAndTheManifestDelay() public view {
        assertEq(tl.admin(), OWNER);
        assertEq(tl.pendingAdmin(), address(0));
        assertEq(tl.guardian(), address(0));
        assertEq(tl.executor(), address(0));
        assertEq(tl.minDelay(), 172_800);
        assertFalse(tl.paused());
        assertEq(tl.signerCount(), 0);
        assertEq(tl.quorum(), 0);
        assertEq(tl.signerSetVersion(), 0);
        assertEq(address(tl).balance, 0);
    }

    function test_registryStartsWithDocumentedDefaultsAndNoListings() public view {
        assertEq(registry.reserveAsset(), WETH);
        assertEq(registry.reserveDecimals(), 18);
        assertEq(registry.reserveFeed(), address(0));
        assertEq(registry.reserveHeartbeat(), 0);
        assertEq(registry.methodologyVersion(), 1);
        assertEq(registry.methodologyHash(), bytes32(0));
        assertEq(registry.listedTokens().length, 0);
        uint256[15] memory expected = [
            uint256(100),
            200,
            250,
            30 days,
            250_000_000,
            5_000_000,
            5_000_000,
            1 days,
            6 hours,
            7 days,
            2 days,
            2,
            3 days,
            3,
            0
        ];
        uint256[15] memory actual = registry.allParams();
        for (uint256 i; i < 15; ++i) {
            assertEq(actual[i], expected[i], "default parameter");
            (uint256 lo, uint256 hi) = registry.paramBounds(Param(i));
            assertTrue(actual[i] >= lo && actual[i] <= hi, "default outside its own bounds");
        }
    }

    /// @dev Construction never touches the reserve literal, but the first read of it does: until the
    /// WETH address has code, NAV, previews and distribution revert. On mainnet it has; on the floor
    /// and here it does not, which is why these reads come after `_etchWeth` everywhere else.
    function test_reserveReadsNeedLiveCodeAtTheWethLiteral() public {
        assertEq(WETH.code.length, 0);
        vm.expectRevert();
        vault.nav();
        vm.expectRevert();
        vault.previewDeposit(1 ether);
        vm.expectRevert();
        waterfall.pendingDistribution();
        vm.expectRevert();
        waterfall.distribute();
        vm.expectRevert();
        executor.position(WETH);
        _etchWeth();
        (uint256 nav,) = vault.nav();
        assertEq(nav, 0);
        assertEq(waterfall.distribute(), 0);
    }

    function test_epochsVaultExecutorAndWaterfallStartEmpty() public {
        _etchWeth();
        assertEq(epochs.epoch(), 0);
        assertEq(epochs.activatedAt(), 0);
        assertEq(epochs.pendingProposal().proposalHash, bytes32(0));
        assertEq(epochs.lastReportTime(), 0);
        assertFalse(epochs.basketStale());

        assertEq(vault.asset(), WETH);
        assertEq(vault.decimals(), 24, "reserve decimals plus six");
        assertEq(vault.depositCap(), DEPOSIT_CAP);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.heldTokens().length, 0);
        (uint256 nav, bool complete) = vault.nav();
        assertEq(nav, 0);
        assertTrue(complete);
        (, bool available) = vault.previewDeposit(1 ether);
        assertFalse(available, "deposits are closed without a guardian");

        assertEq(address(executor.vault()), address(vault));
        assertEq(executor.reserve(), WETH);
        assertEq(executor.windowStart(), 0);
        assertEq(executor.windowEpoch(), 0);

        assertEq(waterfall.basketBps(), 4000);
        assertEq(waterfall.lpBps(), 2500);
        assertEq(waterfall.swarmBps(), 2000);
        assertEq(waterfall.protocolBps(), 1000);
        assertEq(waterfall.utilityBps(), 500);
        assertEq(waterfall.swapFeePips(), 10_000);
        assertEq(waterfall.staleSurchargePips(), 0);
        assertEq(waterfall.totalAccrued(), 0);
        assertEq(waterfall.recipient(FeeWaterfall.Bucket.Swarm), address(0));
        assertEq(waterfall.recipient(FeeWaterfall.Bucket.Protocol), address(0));
        assertEq(waterfall.recipient(FeeWaterfall.Bucket.Utility), address(0));
        (uint24 lpFee, uint24 hookFee, uint16 basketBps, uint16 nonLpBps) = waterfall.feeQuote();
        assertEq(lpFee, 2_500);
        assertEq(hookFee, 7_500);
        assertEq(basketBps, 4000);
        assertEq(nonLpBps, 7500);

        assertEq(deployer.hook(), address(0));
        assertEq(deployer.creationCodeHash(), keccak256(type(FeeHook).creationCode));
        assertEq(
            deployer.initCodeHash(),
            keccak256(
                bytes.concat(
                    type(FeeHook).creationCode, abi.encode(POOL_MANAGER, address(token), address(0), address(waterfall))
                )
            )
        );
    }

    // ---------------------------------------------------------------- closed until governance runs

    function test_depositsAreClosedAndNothingCanBeRedeemed() public {
        vm.prank(BOB);
        vm.expectRevert(IndexVault.NoGuardian.selector);
        vault.deposit(1, BOB, 0);
        vm.prank(OWNER);
        vm.expectRevert(IndexVault.NoGuardian.selector);
        vault.deposit(1, OWNER, 0);
        vm.prank(BOB);
        vm.expectRevert(IndexVault.ZeroAmount.selector);
        vault.redeem(0, BOB, true);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 0, 1));
        vault.redeem(1, BOB, true);
    }

    function test_nobodyCanTradeProposeOrAnchorBeforeRolesExist() public {
        address[3] memory callers = [BOB, OWNER, address(factory)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(RebalanceExecutor.NotKeeper.selector);
            executor.executeTrade(WETH, address(0xBEEF), 1, 0, address(0xBEEF), "");
            vm.prank(callers[i]);
            vm.expectRevert(EpochManager.NotAuthorized.selector);
            epochs.cancelPending();
            vm.prank(callers[i]);
            vm.expectRevert(EpochManager.NoPendingProposal.selector);
            epochs.activate();
        }
        // A report with no signatures: quorum zero means nothing can ever be anchored or published.
        vm.expectRevert(EpochManager.QuorumNotConfigured.selector);
        epochs.anchorReport(uint64(block.timestamp), keccak256("report"), new bytes[](0));

        // A well-formed proposal fails the hard rules before quorum is even consulted: nothing is listed.
        EpochManager.Proposal memory p;
        p.epoch = 1;
        p.snapshotTime = uint64(block.timestamp);
        p.expiry = uint64(block.timestamp + 2 days);
        p.methodologyVersion = 1;
        p.signerSetVersion = 0;
        p.dataHash = keccak256("data");
        p.tokens = new address[](1);
        p.tokens[0] = address(0xBEEF);
        p.weightsBps = new uint16[](1);
        p.weightsBps[0] = 10_000;
        p.marketCapsUsd = new uint256[](1);
        p.liquidityUsd = new uint256[](1);
        p.volumesUsd = new uint256[](1);
        p.marketCapsUsd[0] = 1e12;
        p.liquidityUsd[0] = 1e12;
        p.volumesUsd[0] = 1e12;
        vm.expectRevert(abi.encodeWithSelector(EpochManager.NotEligible.selector, address(0xBEEF)));
        epochs.publish(p, new bytes[](0));
    }

    function test_feeFlowIsInertUntilConfigured() public {
        _etchWeth();
        assertEq(waterfall.distribute(), 0);
        assertEq(waterfall.pendingDistribution(), 0);
        vm.expectRevert(FeeWaterfall.ZeroAddress.selector);
        waterfall.claim(FeeWaterfall.Bucket.Swarm);
        vm.expectRevert(FeeWaterfall.InvalidBucket.selector);
        waterfall.claim(FeeWaterfall.Bucket.Basket);
        // The owner wallet is not the timelock and holds no keeper role.
        vm.prank(OWNER);
        vm.expectRevert(FeeWaterfall.NotAuthorized.selector);
        waterfall.pushBasketReserve(0);
        vm.prank(BOB);
        vm.expectRevert(FeeWaterfall.NotAuthorized.selector);
        waterfall.pushBasketReserve(0);
        vm.prank(BOB);
        vm.expectRevert(AssetRegistry.NotAuthorized.selector);
        registry.quarantine(WETH);
        vm.expectRevert(AssetRegistry.NotListed.selector);
        registry.quarantineIfStale(WETH);
        vm.expectRevert(FeeHookDeployer.HookNotDeployed.selector);
        deployer.poolKey();
    }

    /// @dev Every configuration entry point refuses the owner wallet, the factory and a stranger
    /// directly; only a call from the timelock itself, after its delay, is accepted.
    function test_configurationRefusesEveryDirectCaller() public {
        address[3] memory callers = [OWNER, address(factory), BOB];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
            tl.setGuardian(callers[i]);
            vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
            tl.setExecutor(address(executor));
            vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
            tl.setSigner(callers[i], true);
            vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
            tl.setKeeper(callers[i], true);
            vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
            tl.setMinDelay(1 days);
            vm.expectRevert(TimelockedAdmin.NotTimelock.selector);
            tl.transferAdmin(callers[i]);
            vm.expectRevert(TimelockedAdmin.NotGuardian.selector);
            tl.pause();
            vm.expectRevert(TimelockedAdmin.NotAuthorized.selector);
            tl.unpause();
            vm.expectRevert(TimelockedAdmin.NotAuthorized.selector);
            tl.acceptAdmin();
            vm.expectRevert(AssetRegistry.NotTimelock.selector);
            registry.setRouter(callers[i], true);
            vm.expectRevert(AssetRegistry.NotTimelock.selector);
            registry.setParam(Param.MaxSlippageBps, 1000);
            vm.expectRevert(AssetRegistry.NotTimelock.selector);
            registry.setMethodology(2, keccak256("m"));
            vm.expectRevert(AssetRegistry.NotTimelock.selector);
            registry.setReserveFeed(callers[i], 1 days);
            vm.expectRevert(IndexVault.NotTimelock.selector);
            vault.setDepositCap(type(uint256).max);
            vm.expectRevert(IndexVault.NotTimelock.selector);
            vault.rescue(address(token), callers[i]);
            vm.expectRevert(IndexVault.NotExecutor.selector);
            vault.beginTrade(WETH, 1);
            vm.expectRevert(FeeWaterfall.NotTimelock.selector);
            waterfall.setSwapFee(30_000, 0);
            vm.expectRevert(FeeWaterfall.NotTimelock.selector);
            waterfall.setSplit(10_000, 0, 0, 0, 0);
            vm.expectRevert(FeeWaterfall.NotTimelock.selector);
            waterfall.setRecipient(FeeWaterfall.Bucket.Swarm, callers[i]);
            vm.expectRevert(FeeWaterfall.NotTimelock.selector);
            waterfall.rescue(address(token), callers[i]);
            vm.expectRevert(RebalanceExecutor.NotTimelock.selector);
            executor.disposeQuarantined(address(0xBEEF), 1, 1, address(0xBEEF), "");
            vm.expectRevert(RebalanceExecutor.NotSelf.selector);
            executor.swapThroughRouter(WETH, address(0xBEEF), 1, 0, address(0xBEEF), "");
            vm.stopPrank();
        }
        // Only the owner may schedule, and only at or above the manifest delay.
        bytes memory data = abi.encodeCall(tl.setGuardian, (GUARDIAN));
        vm.prank(BOB);
        vm.expectRevert(TimelockedAdmin.NotAdmin.selector);
        tl.schedule(address(tl), 0, data, 0, MIN_DELAY);
        vm.prank(address(factory));
        vm.expectRevert(TimelockedAdmin.NotAdmin.selector);
        tl.schedule(address(tl), 0, data, 0, MIN_DELAY);
        vm.startPrank(OWNER);
        vm.expectRevert(TimelockedAdmin.DelayOutOfRange.selector);
        tl.schedule(address(tl), 0, data, 0, MIN_DELAY - 1);
        vm.expectRevert(TimelockedAdmin.DelayOutOfRange.selector);
        tl.schedule(address(tl), 0, data, 0, 30 days + 1);
        tl.schedule(address(tl), 0, data, 0, MIN_DELAY);
        vm.expectRevert(TimelockedAdmin.NotReady.selector);
        tl.execute(address(tl), 0, data, 0);
        skip(MIN_DELAY - 1);
        vm.expectRevert(TimelockedAdmin.NotReady.selector);
        tl.execute(address(tl), 0, data, 0);
        skip(1);
        tl.execute(address(tl), 0, data, 0);
        vm.stopPrank();
        assertEq(tl.guardian(), GUARDIAN);
        assertEq(uint256(tl.roleOf(GUARDIAN)), uint256(Role.Guardian));
    }

    // ---------------------------------------------------------------- the launched literals in use

    /// @dev With the mainnet WETH literal given code, the first governance step opens deposits and
    /// the 100 WETH cap from launch.json binds exactly: 100 WETH mints 100 whole shares, one more wei
    /// is refused, and the owner wallet still cannot move the reserve.
    function test_firstGovernanceStepOpensDepositsUpToExactlyTheManifestCap() public {
        _etchWeth();
        _gov(address(tl), abi.encodeCall(tl.setGuardian, (GUARDIAN)));
        MockWETH(WETH).mint(BOB, DEPOSIT_CAP + 1);
        vm.startPrank(BOB);
        MockWETH(WETH).approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(DEPOSIT_CAP, BOB, 0);
        assertEq(shares, 100 * 10 ** 24, "one whole share per reserve unit at launch");
        vm.expectRevert(IndexVault.DepositCapExceeded.selector);
        vault.deposit(1, BOB, 0);
        vm.stopPrank();
        (uint256 nav,) = vault.nav();
        assertEq(nav, DEPOSIT_CAP);
        assertEq(vault.balanceOf(BOB), shares);
        vm.prank(OWNER);
        vm.expectRevert(IndexVault.NotTimelock.selector);
        vault.setDepositCap(0);
        vm.prank(OWNER);
        vm.expectRevert(IndexVault.NotTimelock.selector);
        vault.rescue(WETH, OWNER);
        vm.prank(address(tl));
        vm.expectRevert(IndexVault.NotRescuable.selector);
        vault.rescue(WETH, OWNER);
        assertEq(MockWETH(WETH).balanceOf(address(vault)), DEPOSIT_CAP, "the reserve never left the vault");
        // Redemption needs no role, no feed and no keeper: the depositor exits next block.
        vm.roll(block.number + 1);
        vm.prank(BOB);
        vault.redeem(shares, BOB, true);
        // The virtual-share offset keeps one wei in the vault on a full exit; the depositor gets the rest.
        assertEq(MockWETH(WETH).balanceOf(BOB), DEPOSIT_CAP + 1 - 1 wei);
        assertEq(MockWETH(WETH).balanceOf(address(vault)), 1 wei);
        assertEq(vault.totalSupply(), 0);
    }

    /// @dev A wrong reserve-decimals literal would not fail the launch; it fails the first deposit.
    /// The launched pair (WETH, 18) passes that check only because the token really has 18 decimals.
    function test_firstDepositVerifiesTheReserveLiteralsAgainstTheToken() public {
        _etchWeth();
        _gov(address(tl), abi.encodeCall(tl.setGuardian, (GUARDIAN)));
        // A vault configured with 6 decimals against the 18-decimal WETH literal refuses deposits.
        IndexVault wrong = new IndexVault(address(tl), address(registry), WETH, 6, DEPOSIT_CAP);
        MockWETH(WETH).mint(BOB, 1 ether);
        vm.startPrank(BOB);
        MockWETH(WETH).approve(address(wrong), 1 ether);
        vm.expectRevert(IndexVault.DecimalsMismatch.selector);
        wrong.deposit(1 ether, BOB, 0);
        vm.stopPrank();
    }

    /// @dev The post-launch hook deployment works offline with the launched literals: the hook's
    /// constructor calls nothing, its immutables equal the manifest, and the pool key is the native
    /// ETH / IMDEX dynamic-fee pool at tick spacing 60 with native ETH as currency0.
    function test_hookDeploysWithTheLaunchedLiteralsAndYieldsTheNativePoolKey() public {
        (bytes32 salt, bool found) = deployer.findSalt(0, 400_000);
        assertTrue(found);
        vm.prank(BOB); // permissionless
        FeeHook hook = FeeHook(deployer.deploy(salt, type(FeeHook).creationCode));
        assertEq(deployer.hook(), address(hook));
        assertEq(address(hook), deployer.computeAddress(salt));
        assertEq(uint160(address(hook)) & 0x3FFF, hook.REQUIRED_FLAGS());
        assertEq(address(hook.poolManager()), POOL_MANAGER);
        assertEq(hook.projectToken(), address(token));
        assertEq(hook.quoteCurrency(), address(0));
        assertEq(address(hook.waterfall()), address(waterfall));
        assertTrue(hook.quoteIsCurrency0(), "native ETH sorts first");
        PoolKey memory key = deployer.poolKey();
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), address(token));
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(key.tickSpacing, 60);
        assertEq(address(key.hooks), address(hook));
        assertEq(keccak256(abi.encode(key)), keccak256(abi.encode(hook.poolKey())));
        assertFalse(hook.poolRegistered(), "the pool still has to be initialised on the PoolManager");
        vm.expectRevert(FeeHookDeployer.AlreadyDeployed.selector);
        deployer.deploy(salt, type(FeeHook).creationCode);
    }

    /// @dev In the launched configuration fee ETH is wrapped into the reserve on distribution and no
    /// one, not even the timelock, can sweep it; only a stray token is rescuable.
    function test_nativeFeesAreWrappedIntoTheReserveAndCannotBeSwept() public {
        _etchWeth();
        uint256 amount = 3 ether + 7; // not divisible by the 75% denominator, so rounding has a remainder
        vm.deal(BOB, amount);
        vm.prank(BOB);
        (bool ok,) = address(waterfall).call{value: amount}("");
        assertTrue(ok);
        assertEq(waterfall.pendingDistribution(), amount, "ETH counts as pending because it wraps");
        vm.startPrank(address(tl));
        vm.expectRevert(FeeWaterfall.NotRescuable.selector);
        waterfall.rescue(address(0), OWNER);
        vm.expectRevert(FeeWaterfall.NotRescuable.selector);
        waterfall.rescue(WETH, OWNER);
        vm.stopPrank();
        assertEq(waterfall.distribute(), amount);
        assertEq(address(waterfall).balance, 0);
        assertEq(MockWETH(WETH).balanceOf(address(waterfall)), amount);
        uint256 swarm = amount * 2000 / 7500;
        uint256 protocol = amount * 1000 / 7500;
        uint256 utility = amount * 500 / 7500;
        uint256 dust = amount - (swarm + protocol + utility + amount * 4000 / 7500);
        assertTrue(dust >= 1 && dust <= 3, "four floors leave one to three units of dust");
        assertEq(
            waterfall.accrued(FeeWaterfall.Bucket.Basket), amount - swarm - protocol - utility, "dust to the basket"
        );
        assertEq(waterfall.accrued(FeeWaterfall.Bucket.Swarm), swarm);
        assertEq(waterfall.accrued(FeeWaterfall.Bucket.Protocol), protocol);
        assertEq(waterfall.accrued(FeeWaterfall.Bucket.Utility), utility);
        assertEq(waterfall.totalAccrued(), amount);
        // Without a WETH contract the wrap itself would fail: the reserve literal must be live WETH.
        vm.etch(WETH, "");
        vm.deal(address(waterfall), 1 wei);
        vm.expectRevert();
        waterfall.distribute();
    }
}
