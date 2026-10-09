// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Launch816Live} from "../utils/Launch816Live.sol";
import {MockERC20, MockWETH} from "../utils/Mocks.sol";
import {TimelockedAdmin} from "../../src/TimelockedAdmin.sol";
import {IndexVault} from "../../src/IndexVault.sol";
import {FeeWaterfall} from "../../src/FeeWaterfall.sol";

/// @dev Drives the launched FeeWaterfall and IndexVault in the exact launch 816 configuration: WETH
/// reserve, native ETH fees that must be wrapped, 100 WETH deposit cap, timelock treasury. Ghost
/// totals are kept independently of the contracts' own accounting.
contract Launch816WaterfallHandler is Test {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 internal constant BPS = 10_000;

    FeeWaterfall public immutable waterfall;
    IndexVault public immutable vault;
    TimelockedAdmin public immutable tl;
    address public immutable owner;
    address public immutable keeper;
    address[4] public actors = [address(0xFE01), address(0xFE02), address(0xFE03), address(0xFE04)];
    MockERC20 public stray;

    uint256 public ethIn;
    uint256 public wethIn;
    uint256 public pushed;
    uint256 public treasuryOut;
    uint256 public basketFloor;
    uint256 public distributions;
    mapping(FeeWaterfall.Bucket => uint256) public claimed;
    mapping(address => uint256) public paidTo;

    constructor(FeeWaterfall w, IndexVault v, TimelockedAdmin t, address owner_, address keeper_) {
        waterfall = w;
        vault = v;
        tl = t;
        owner = owner_;
        keeper = keeper_;
        stray = new MockERC20("STRAY", 18);
    }

    // ---------------------------------------------------------------- fee arrivals

    function feeNative(uint256 amount) public {
        amount = bound(amount, 1, 50 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(waterfall).call{value: amount}("");
        assertTrue(ok, "receive must accept native fees");
        ethIn += amount;
        assertEq(waterfall.totalAccrued(), _sumAccrued(), "receiving ETH changes no accounting");
    }

    function feeWrapped(uint256 amount) public {
        amount = bound(amount, 1, 50 ether);
        MockWETH(WETH).mint(address(waterfall), amount);
        wethIn += amount;
    }

    // ---------------------------------------------------------------- distribution and payouts

    function distribute() public {
        uint256 pending = _recordPendingWithCurrentSplit();
        uint256 ethBefore = address(waterfall).balance;
        uint256 amount = waterfall.distribute();
        assertEq(amount, pending, "distribute returns exactly what was pending");
        assertEq(address(waterfall).balance, 0, "all native fees are wrapped");
        assertGe(MockWETH(WETH).balanceOf(address(waterfall)), ethBefore);
        if (pending != 0) ++distributions;
    }

    function claim(uint256 bucketSeed) public {
        FeeWaterfall.Bucket bucket = FeeWaterfall.Bucket(1 + bucketSeed % 3);
        address to = waterfall.recipient(bucket);
        if (to == address(0)) {
            vm.expectRevert(FeeWaterfall.ZeroAddress.selector);
            waterfall.claim(bucket);
            return;
        }
        distribute();
        uint256 due = waterfall.accrued(bucket);
        if (due == 0) {
            vm.expectRevert(FeeWaterfall.NothingToSend.selector);
            waterfall.claim(bucket);
            return;
        }
        uint256 before = MockWETH(WETH).balanceOf(to);
        vm.prank(actors[bucketSeed % 4]); // anyone may trigger
        uint256 amount = waterfall.claim(bucket);
        assertEq(amount, due);
        assertEq(MockWETH(WETH).balanceOf(to) - before, due, "recipient receives exactly the bucket");
        assertEq(waterfall.accrued(bucket), 0);
        claimed[bucket] += due;
        paidTo[to] += due;
    }

    function claimBasketIsRefused() public {
        vm.expectRevert(FeeWaterfall.InvalidBucket.selector);
        waterfall.claim(FeeWaterfall.Bucket.Basket);
    }

    function push(uint256 seed, bool badFloor) public {
        distribute();
        uint256 due = waterfall.accrued(FeeWaterfall.Bucket.Basket);
        (uint256 navBefore,) = vault.nav();
        (uint256 preview,) = vault.previewDeposit(due);
        uint256 sharesBefore = vault.balanceOf(address(tl));
        uint256 reserveBefore = waterfall.accrued(FeeWaterfall.Bucket.Basket);
        address caller = seed % 2 == 0 ? keeper : address(tl);
        if (due == 0) {
            vm.prank(caller);
            vm.expectRevert(FeeWaterfall.NothingToSend.selector);
            waterfall.pushBasketReserve(0);
            return;
        }
        if (navBefore + due > vault.depositCap()) {
            vm.prank(caller);
            vm.expectRevert(IndexVault.DepositCapExceeded.selector);
            waterfall.pushBasketReserve(0);
            assertEq(waterfall.accrued(FeeWaterfall.Bucket.Basket), reserveBefore, "a refused push keeps the reserve");
            return;
        }
        if (badFloor) {
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(IndexVault.InsufficientShares.selector, preview, preview + 1));
            waterfall.pushBasketReserve(preview + 1);
            assertEq(waterfall.accrued(FeeWaterfall.Bucket.Basket), reserveBefore);
            return;
        }
        vm.prank(caller);
        uint256 shares = waterfall.pushBasketReserve(preview);
        assertEq(shares, preview, "preview is exact");
        assertEq(vault.balanceOf(address(tl)) - sharesBefore, shares, "shares go to the treasury");
        assertEq(waterfall.accrued(FeeWaterfall.Bucket.Basket), 0);
        pushed += due;
    }

    function treasuryRedeem(uint256 seed) public {
        uint256 balance = vault.balanceOf(address(tl));
        vm.roll(block.number + 1); // past the deposit-block lock
        uint256 shares = bound(seed, 0, balance);
        if (shares == 0) {
            vm.prank(address(tl));
            vm.expectRevert(IndexVault.ZeroAmount.selector);
            vault.redeem(0, address(tl), true);
            return;
        }
        (, uint256[] memory preview) = vault.previewRedeem(shares);
        uint256 before = MockWETH(WETH).balanceOf(address(tl));
        vm.prank(address(tl));
        vault.redeem(shares, address(tl), true);
        uint256 received = MockWETH(WETH).balanceOf(address(tl)) - before;
        assertEq(received, preview[0], "redemption pays exactly its preview");
        assertEq(vault.balanceOf(address(tl)), balance - shares);
        treasuryOut += received;
    }

    // ---------------------------------------------------------------- timelocked configuration

    function setRecipient(uint256 bucketSeed, uint256 whoSeed) public {
        FeeWaterfall.Bucket bucket = FeeWaterfall.Bucket(bucketSeed % 4);
        address to = whoSeed % 5 == 0 ? address(0) : actors[whoSeed % 4];
        vm.prank(address(tl));
        if (bucket == FeeWaterfall.Bucket.Basket) {
            vm.expectRevert(FeeWaterfall.InvalidBucket.selector);
            waterfall.setRecipient(bucket, to);
            return;
        }
        waterfall.setRecipient(bucket, to);
        assertEq(waterfall.recipient(bucket), to);
    }

    function setSplit(uint256 seed) public {
        uint16[5][6] memory splits = [
            [uint16(4000), 2500, 2000, 1000, 500],
            [uint16(5000), 2500, 2500, 0, 0],
            [uint16(0), 10_000, 0, 0, 0],
            [uint16(10_000), 0, 0, 0, 0],
            [uint16(3334), 3333, 3333, 0, 0],
            [uint16(1), 9999, 0, 0, 0]
        ];
        uint16[5] memory s = splits[seed % 6];
        if (seed % 7 == 0) {
            vm.prank(address(tl));
            vm.expectRevert(FeeWaterfall.InvalidSplit.selector);
            waterfall.setSplit(s[0], s[1], s[2], s[3], s[4] + 1);
            return;
        }
        // The pending amount is divided under the split in force before the change.
        _recordPendingWithCurrentSplit();
        vm.prank(address(tl));
        waterfall.setSplit(s[0], s[1], s[2], s[3], s[4]);
        assertEq(address(waterfall).balance, 0);
        assertEq(waterfall.basketBps(), s[0]);
        assertEq(waterfall.lpBps(), s[1]);
    }

    // ---------------------------------------------------------------- refusals

    function rescueAttempts(uint256 seed) public {
        address to = actors[seed % 4];
        uint256 ethBefore = address(waterfall).balance;
        uint256 wethBefore = MockWETH(WETH).balanceOf(address(waterfall));
        vm.startPrank(address(tl));
        vm.expectRevert(FeeWaterfall.NotRescuable.selector);
        waterfall.rescue(address(0), to);
        vm.expectRevert(FeeWaterfall.NotRescuable.selector);
        waterfall.rescue(WETH, to);
        vm.expectRevert(FeeWaterfall.ZeroAddress.selector);
        waterfall.rescue(address(stray), address(0));
        vm.stopPrank();
        uint256 amount = bound(seed, 0, 1e21);
        stray.mint(address(waterfall), amount);
        uint256 before = stray.balanceOf(to);
        vm.prank(address(tl));
        waterfall.rescue(address(stray), to);
        assertEq(stray.balanceOf(to) - before, amount);
        assertEq(address(waterfall).balance, ethBefore);
        assertEq(MockWETH(WETH).balanceOf(address(waterfall)), wethBefore);
    }

    function unauthorized(uint256 seed) public {
        address who = seed % 5 == 0 ? owner : actors[seed % 4];
        vm.startPrank(who);
        vm.expectRevert(FeeWaterfall.NotTimelock.selector);
        waterfall.setSplit(10_000, 0, 0, 0, 0);
        vm.expectRevert(FeeWaterfall.NotTimelock.selector);
        waterfall.setSwapFee(30_000, 0);
        vm.expectRevert(FeeWaterfall.NotTimelock.selector);
        waterfall.setRecipient(FeeWaterfall.Bucket.Swarm, who);
        vm.expectRevert(FeeWaterfall.NotTimelock.selector);
        waterfall.rescue(address(stray), who);
        vm.expectRevert(FeeWaterfall.NotAuthorized.selector);
        waterfall.pushBasketReserve(0);
        vm.expectRevert(IndexVault.NotTimelock.selector);
        vault.setDepositCap(type(uint256).max);
        vm.stopPrank();
    }

    function advance(uint256 elapsed) public {
        vm.warp(block.timestamp + bound(elapsed, 0, 3 days));
        vm.roll(block.number + 1);
    }

    // ---------------------------------------------------------------- views for invariants

    function sumClaimed() external view returns (uint256) {
        return claimed[FeeWaterfall.Bucket.Swarm] + claimed[FeeWaterfall.Bucket.Protocol]
            + claimed[FeeWaterfall.Bucket.Utility];
    }

    function _sumAccrued() private view returns (uint256) {
        return waterfall.accrued(FeeWaterfall.Bucket.Basket) + waterfall.accrued(FeeWaterfall.Bucket.Swarm)
            + waterfall.accrued(FeeWaterfall.Bucket.Protocol) + waterfall.accrued(FeeWaterfall.Bucket.Utility);
    }

    /// @dev Ghost lower bound on the basket's share of what is about to be distributed, under the
    /// split currently in force. The contract gives the basket the remainder, so it may only exceed it.
    function _recordPendingWithCurrentSplit() private returns (uint256 pending) {
        pending = waterfall.pendingDistribution();
        uint256 nonLp = BPS - waterfall.lpBps();
        basketFloor += nonLp == 0 ? pending : pending * waterfall.basketBps() / nonLp;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract Launch816WaterfallInvariantTest is Launch816Live {
    Launch816WaterfallHandler private handler;

    function setUp() public {
        _launch();
        _etchWeth();
        address[] memory targets = new address[](2);
        bytes[] memory calls = new bytes[](2);
        targets[0] = address(tl);
        calls[0] = abi.encodeCall(tl.setGuardian, (GUARDIAN));
        targets[1] = address(tl);
        calls[1] = abi.encodeCall(tl.setKeeper, (KEEPER, true));
        _gov(targets, calls);

        handler = new Launch816WaterfallHandler(waterfall, vault, tl, OWNER, KEEPER);
        // Seed one of each path so every run starts from a live, partly configured waterfall.
        handler.setRecipient(1, 1);
        handler.feeNative(1 ether);
        handler.feeWrapped(1 ether);
        handler.distribute();
        handler.claim(1);
        handler.push(0, false);
        handler.treasuryRedeem(1);

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.feeNative.selector;
        selectors[1] = handler.feeWrapped.selector;
        selectors[2] = handler.distribute.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.claimBasketIsRefused.selector;
        selectors[5] = handler.push.selector;
        selectors[6] = handler.treasuryRedeem.selector;
        selectors[7] = handler.setRecipient.selector;
        selectors[8] = handler.setSplit.selector;
        selectors[9] = handler.rescueAttempts.selector;
        selectors[10] = handler.unauthorized.selector;
        selectors[11] = handler.advance.selector;
        selectors[12] = handler.feeNative.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _weth(address who) private view returns (uint256) {
        return MockWETH(WETH).balanceOf(who);
    }

    /// @dev What the waterfall holds (wrapped plus still-native) always covers what it owes, and the
    /// bucket ledgers sum to the total.
    function invariant_liabilitiesAreCoveredAndLedgersSum() public view {
        uint256 held = _weth(address(waterfall)) + address(waterfall).balance;
        assertGe(held, waterfall.totalAccrued(), "waterfall owes more than it holds");
        uint256 sum = waterfall.accrued(FeeWaterfall.Bucket.Basket) + waterfall.accrued(FeeWaterfall.Bucket.Swarm)
            + waterfall.accrued(FeeWaterfall.Bucket.Protocol) + waterfall.accrued(FeeWaterfall.Bucket.Utility);
        assertEq(sum, waterfall.totalAccrued(), "bucket ledgers diverge from the total");
        assertEq(waterfall.pendingDistribution(), held - waterfall.totalAccrued(), "pending is held minus owed");
    }

    /// @dev Every unit of fee that ever arrived, native or wrapped, is either still in the waterfall,
    /// paid to a configured recipient, or deposited into the vault. Nothing leaks, nothing is minted.
    function invariant_everyFeeUnitIsAccountedFor() public view {
        uint256 inFlow = handler.ethIn() + handler.wethIn();
        uint256 held = _weth(address(waterfall)) + address(waterfall).balance;
        assertEq(inFlow, held + handler.sumClaimed() + handler.pushed(), "fee conservation");
    }

    /// @dev Lifetime per bucket equals what it still holds plus what left through the only exits.
    function invariant_lifetimeEqualsAccruedPlusPaidOut() public view {
        assertEq(
            waterfall.lifetime(FeeWaterfall.Bucket.Basket),
            waterfall.accrued(FeeWaterfall.Bucket.Basket) + handler.pushed()
        );
        FeeWaterfall.Bucket[3] memory b =
            [FeeWaterfall.Bucket.Swarm, FeeWaterfall.Bucket.Protocol, FeeWaterfall.Bucket.Utility];
        for (uint256 i; i < 3; ++i) {
            assertEq(waterfall.lifetime(b[i]), waterfall.accrued(b[i]) + handler.claimed(b[i]));
        }
    }

    /// @dev Rounding dust goes to the basket: its lifetime is never below the sum of its proportional
    /// floors under each split that was in force.
    function invariant_basketNeverReceivesLessThanItsShare() public view {
        assertGe(waterfall.lifetime(FeeWaterfall.Bucket.Basket), handler.basketFloor());
    }

    /// @dev Recipients receive exactly their claims; the owner wallet and strangers receive nothing.
    function invariant_onlyConfiguredRecipientsArePaid() public view {
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(_weth(actor), handler.paidTo(actor), "recipient balance diverges from claims");
        }
        assertEq(_weth(OWNER), 0);
        assertEq(_weth(KEEPER), 0);
        assertEq(_weth(address(factory)), 0);
        assertEq(_weth(address(handler)), 0);
    }

    /// @dev The vault's reserve is the pushed basket reserve less treasury redemptions, the timelock
    /// is the only share holder, and NAV never exceeds the 100 WETH launch cap.
    function invariant_treasurySharesAreBackedAndCapped() public view {
        assertEq(_weth(address(vault)), handler.pushed() - handler.treasuryOut(), "vault reserve diverges");
        assertEq(vault.totalSupply(), vault.balanceOf(address(tl)), "someone other than the treasury holds shares");
        (uint256 nav, bool complete) = vault.nav();
        assertTrue(complete);
        assertLe(nav, DEPOSIT_CAP, "deposit cap breached");
        assertEq(vault.heldTokens().length, 0, "the fee path never buys basket assets");
        assertLe(handler.treasuryOut(), handler.pushed(), "treasury withdrew more than it deposited");
    }

    /// @dev What the handler never touches stays at its launch value: fee level, references, roles.
    function invariant_untouchedConfigurationHoldsItsLaunchValues() public view {
        assertEq(waterfall.swapFeePips(), 10_000);
        assertEq(waterfall.staleSurchargePips(), 0);
        assertEq(waterfall.reserveAsset(), WETH);
        assertEq(waterfall.weth(), WETH);
        assertEq(vault.depositCap(), DEPOSIT_CAP);
        assertEq(tl.admin(), OWNER);
        assertEq(tl.guardian(), GUARDIAN);
        assertEq(tl.executor(), address(0));
        assertEq(tl.quorum(), 0);
        assertEq(deployer.hook(), address(0));
    }
}
