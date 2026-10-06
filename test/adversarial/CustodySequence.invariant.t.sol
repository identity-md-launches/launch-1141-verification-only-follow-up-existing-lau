// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "../utils/Fixture.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {IndexVault} from "src/IndexVault.sol";
import {FeeWaterfall} from "src/FeeWaterfall.sol";
import {TimelockedAdmin} from "src/TimelockedAdmin.sol";

/// @dev Reserve-only campaign complements the existing trading campaign. Every state-changing
/// selector is targeted explicitly; expected failures are checked, never swallowed.
contract CustodySequenceHandler is Test {
    IndexVault public immutable vault;
    FeeWaterfall public immutable waterfall;
    TimelockedAdmin public immutable admin;
    MockERC20 public immutable reserve;
    address public immutable owner;
    address public immutable guardian;
    address public immutable keeper;
    address[3] public actors = [address(0xCA01), address(0xCA02), address(0xCA03)];
    address[3] public recipients = [address(0xCB01), address(0xCB02), address(0xCB03)];
    uint256 public deposits;
    uint256 public donations;
    uint256 public fees;
    uint256 public redemptions;
    uint256 public pushed;
    uint256[4] public paid;
    uint256 public minted;
    uint256 public burned;
    uint256 private nonce;

    constructor(IndexVault v, FeeWaterfall w, TimelockedAdmin a, MockERC20 r, address o, address g, address k) {
        vault = v;
        waterfall = w;
        admin = a;
        reserve = r;
        owner = o;
        guardian = g;
        keeper = k;
    }

    function deposit(uint256 who, uint256 receiverSeed, uint256 amount) public {
        address payer = actors[who % 3];
        address receiver = actors[receiverSeed % 3];
        amount = bound(amount, 1, 1_000_000e6);
        reserve.mint(payer, amount);
        (uint256 preview,) = vault.previewDeposit(amount);
        uint256 beforeShares = vault.balanceOf(receiver);
        vm.startPrank(payer);
        reserve.approve(address(vault), amount);
        if (admin.paused()) {
            vm.expectRevert(IndexVault.Paused.selector);
            vault.deposit(amount, receiver, 0);
        } else if (preview == 0) {
            vm.expectRevert(abi.encodeWithSelector(IndexVault.InsufficientShares.selector, 0, 0));
            vault.deposit(amount, receiver, 0);
        } else {
            uint256 shares = vault.deposit(amount, receiver, preview);
            assertEq(shares, preview, "preview must match an ordinary reserve transfer");
            assertEq(vault.balanceOf(receiver) - beforeShares, shares);
            minted += shares;
            deposits += amount;
        }
        vm.stopPrank();
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 10_000e6);
        reserve.mint(address(vault), amount);
        donations += amount;
    }

    function receiveFees(uint256 amount) public {
        amount = bound(amount, 0, 10_000e6);
        reserve.mint(address(waterfall), amount);
        fees += amount;
        // Deliberately leave fees pending so claims and configuration must settle them.
    }

    function distribute() public {
        waterfall.distribute();
        assertEq(waterfall.distribute(), 0, "distribution is idempotent");
    }

    function claim(uint256 bucketSeed) public {
        FeeWaterfall.Bucket bucket = FeeWaterfall.Bucket(1 + bucketSeed % 3);
        waterfall.distribute();
        uint256 owed = waterfall.accrued(bucket);
        address to = recipients[uint256(bucket) - 1];
        uint256 beforeBalance = reserve.balanceOf(to);
        if (owed == 0) {
            vm.expectRevert(FeeWaterfall.NothingToSend.selector);
            waterfall.claim(bucket);
        } else {
            assertEq(waterfall.claim(bucket), owed);
            assertEq(reserve.balanceOf(to) - beforeBalance, owed, "claim sent to wrong beneficiary");
            paid[uint256(bucket)] += owed;
        }
    }

    function push() public {
        waterfall.distribute();
        uint256 amount = waterfall.accrued(FeeWaterfall.Bucket.Basket);
        (uint256 preview,) = vault.previewDeposit(amount);
        vm.startPrank(keeper);
        if (amount == 0) {
            vm.expectRevert(FeeWaterfall.NothingToSend.selector);
            waterfall.pushBasketReserve(0);
        } else if (admin.paused()) {
            vm.expectRevert(IndexVault.Paused.selector);
            waterfall.pushBasketReserve(0);
        } else if (preview == 0) {
            vm.expectRevert(abi.encodeWithSelector(IndexVault.InsufficientShares.selector, 0, 0));
            waterfall.pushBasketReserve(0);
        } else {
            uint256 shares = waterfall.pushBasketReserve(preview);
            assertEq(shares, preview);
            minted += shares;
            pushed += amount;
            paid[0] += amount;
        }
        vm.stopPrank();
        assertEq(reserve.allowance(address(waterfall), address(vault)), 0, "leftover deposit approval");
    }

    function redeem(uint256 who, uint256 fraction) public {
        address actor = actors[who % 3];
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;
        if (fraction != type(uint256).max) shares = bound(fraction, 1, shares);
        vm.roll(block.number + 1);
        _redeem(actor, shares);
    }

    function transferShares(uint256 who, uint256 toSeed, uint256 amount, bool delegated) external {
        address from = actors[who % 3];
        address to = actors[toSeed % 3];
        uint256 balance = vault.balanceOf(from);
        amount = bound(amount, 0, balance);
        uint256 locked = vault.depositBlock(from) == block.number ? vault.mintedThisBlock(from) : 0;
        uint256 beforeTo = vault.balanceOf(to);
        if (delegated) {
            vm.prank(from);
            vault.approve(address(this), amount);
        }
        if (amount > balance - locked) vm.expectRevert(IndexVault.SharesLocked.selector);
        if (delegated) {
            vault.transferFrom(from, to, amount);
        } else {
            vm.prank(from);
            vault.transfer(to, amount);
        }
        if (amount <= balance - locked && from != to) {
            assertEq(vault.balanceOf(from), balance - amount);
            assertEq(vault.balanceOf(to), beforeTo + amount);
        } else {
            assertEq(vault.balanceOf(from), balance, "failed/self transfer changed balance");
        }
    }

    function togglePause(bool pause) public {
        vm.prank(guardian);
        if (pause) admin.pause();
        else admin.unpause();
    }

    function changeSplit(uint256 b, uint256 l, uint256 s, uint256 p) external {
        b = bound(b, 0, 10_000);
        l = bound(l, 0, 10_000 - b);
        s = bound(s, 0, 10_000 - b - l);
        p = bound(p, 0, 10_000 - b - l - s);
        bytes memory data = abi.encodeCall(
            waterfall.setSplit, (uint16(b), uint16(l), uint16(s), uint16(p), uint16(10_000 - b - l - s - p))
        );
        _govern(address(waterfall), data);
    }

    function treasuryRedeem(uint256 fraction) external {
        uint256 shares = vault.balanceOf(address(admin));
        if (shares == 0) return;
        if (fraction != type(uint256).max) shares = bound(fraction, 1, shares);
        uint256 beforeBalance = reserve.balanceOf(address(admin));
        _govern(address(vault), abi.encodeCall(vault.redeem, (shares, address(admin), true)));
        redemptions += reserve.balanceOf(address(admin)) - beforeBalance;
        burned += shares;
    }

    function roundTrip(uint256 who, uint256 amount) external {
        if (admin.paused()) return;
        address actor = actors[who % 3];
        uint256 beforeShares = vault.balanceOf(actor);
        uint256 beforeBalance = reserve.balanceOf(actor);
        uint256 beforeDeposits = deposits;
        deposit(who, who, amount);
        uint256 shares = vault.balanceOf(actor) - beforeShares;
        if (shares == 0) return;
        uint256 credited = deposits - beforeDeposits;
        vm.roll(block.number + 1);
        _redeem(actor, shares);
        assertLe(reserve.balanceOf(actor), beforeBalance + credited, "round trip created reserve tokens");
        assertEq(vault.balanceOf(actor), beforeShares);
    }

    function _redeem(address actor, uint256 shares) private {
        (, uint256[] memory expected) = vault.previewRedeem(shares);
        uint256 beforeBalance = reserve.balanceOf(actor);
        vm.prank(actor);
        vault.redeem(shares, actor, true);
        uint256 received = reserve.balanceOf(actor) - beforeBalance;
        assertEq(received, expected[0]);
        redemptions += received;
        burned += shares;
    }

    function _govern(address target, bytes memory data) private {
        bytes32 salt = bytes32(++nonce);
        uint256 delay = admin.minDelay();
        vm.prank(owner);
        admin.schedule(target, 0, data, salt, delay);
        vm.warp(block.timestamp + delay);
        vm.roll(block.number + 1);
        vm.prank(owner);
        admin.execute(target, 0, data, salt);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract CustodySequenceInvariantTest is Fixture {
    CustodySequenceHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CustodySequenceHandler(vault, waterfall, tl, usdc, OWNER, GUARDIAN, KEEPER);
        for (uint256 i; i < 3; ++i) {
            _queue(
                address(waterfall),
                abi.encodeCall(waterfall.setRecipient, (FeeWaterfall.Bucket(i + 1), handler.recipients(i)))
            );
        }
        _flush();
        handler.deposit(0, 0, 100_000e6);
        handler.deposit(1, 1, 100_000e6);
        handler.receiveFees(7500e6);
        handler.claim(0);
        handler.push();
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.receiveFees.selector;
        selectors[3] = handler.distribute.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.push.selector;
        selectors[6] = handler.redeem.selector;
        selectors[7] = handler.transferShares.selector;
        selectors[8] = handler.togglePause.selector;
        selectors[9] = handler.changeSplit.selector;
        selectors[10] = handler.treasuryRedeem.selector;
        selectors[11] = handler.roundTrip.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_everyReserveUnitHasADestination() public view {
        uint256 claims;
        uint256 liabilities;
        for (uint256 i; i < 4; ++i) {
            uint256 owed = waterfall.accrued(FeeWaterfall.Bucket(i));
            assertEq(waterfall.lifetime(FeeWaterfall.Bucket(i)), owed + handler.paid(i));
            liabilities += owed;
            if (i != 0) {
                claims += handler.paid(i);
                assertEq(usdc.balanceOf(handler.recipients(i - 1)), handler.paid(i));
            }
        }
        assertEq(liabilities, waterfall.totalAccrued());
        assertEq(usdc.balanceOf(address(waterfall)), liabilities + waterfall.pendingDistribution());
        assertEq(handler.fees(), usdc.balanceOf(address(waterfall)) + claims + handler.pushed());
        assertEq(
            handler.deposits() + handler.donations() + handler.pushed(),
            usdc.balanceOf(address(vault)) + handler.redemptions(),
            "custody failed to conserve actual reserve inflows"
        );
    }

    function invariant_allSharesAreBackedAndAccountedFor() public view {
        uint256 sum = vault.balanceOf(address(tl));
        uint256 redeemable;
        for (uint256 i; i < 3; ++i) {
            uint256 shares = vault.balanceOf(handler.actors(i));
            sum += shares;
            (, uint256[] memory amounts) = vault.previewRedeem(shares);
            redeemable += amounts[0];
        }
        (, uint256[] memory treasuryAmounts) = vault.previewRedeem(vault.balanceOf(address(tl)));
        assertLe(redeemable + treasuryAmounts[0], usdc.balanceOf(address(vault)));
        assertEq(sum, vault.totalSupply());
        assertEq(handler.minted() - handler.burned(), sum);
        (uint256 nav, bool complete) = vault.nav();
        assertTrue(complete);
        assertEq(nav, usdc.balanceOf(address(vault)));
    }

    function afterInvariant() public {
        handler.togglePause(true);
        handler.redeem(0, type(uint256).max);
        handler.redeem(1, type(uint256).max);
        handler.redeem(2, type(uint256).max);
        handler.treasuryRedeem(type(uint256).max);
        assertEq(vault.totalSupply(), 0, "all actors must be able to exit while paused");
        invariant_everyReserveUnitHasADestination();
    }
}
