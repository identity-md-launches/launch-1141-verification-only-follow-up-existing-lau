// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IndexVault} from "../../src/IndexVault.sol";
import {RebalanceExecutor} from "../../src/RebalanceExecutor.sol";
import {AssetRegistry} from "../../src/AssetRegistry.sol";
import {FeeWaterfall} from "../../src/FeeWaterfall.sol";
import {MockERC20, MockFeed, MockRouter} from "../utils/Mocks.sol";

/// @dev Random depositors, redeemers, price moves, keeper trades at random fill prices and fee flows.
/// Property violations seen mid-call are latched in `violation` for the invariant test to report.
contract Handler is Test {
    IndexVault internal vault;
    RebalanceExecutor internal executor;
    AssetRegistry internal registry;
    FeeWaterfall internal waterfall;
    MockERC20 internal usdc;
    MockRouter internal router;
    MockERC20[6] internal tokens;
    MockFeed[6] internal feeds;
    address internal keeper;

    address[3] public actors = [address(0xA1), address(0xB0B), address(0xCA7)];
    string public violation;
    uint256 public feesIn;
    uint256 public claimedOut;
    uint256 public pushedToVault;
    uint256 public tradesExecuted;
    uint256 public tradesRefused;

    constructor(
        IndexVault vault_,
        RebalanceExecutor executor_,
        AssetRegistry registry_,
        FeeWaterfall waterfall_,
        MockERC20 usdc_,
        MockRouter router_,
        MockERC20[6] memory tokens_,
        MockFeed[6] memory feeds_,
        address keeper_
    ) {
        vault = vault_;
        executor = executor_;
        registry = registry_;
        waterfall = waterfall_;
        usdc = usdc_;
        router = router_;
        tokens = tokens_;
        feeds = feeds_;
        keeper = keeper_;
    }

    function _flag(string memory what) private {
        if (bytes(violation).length == 0) violation = what;
    }

    function _perShare() private view returns (uint256 value) {
        (value,) = vault.navPerShare();
    }

    function deposit(uint256 actorSeed, uint256 assets) external {
        address actor = actors[actorSeed % 3];
        assets = bound(assets, 1, 2_000_000 * 1e6);
        uint256 before = _perShare();
        usdc.mint(actor, assets);
        vm.startPrank(actor);
        usdc.approve(address(vault), assets);
        try vault.deposit(assets, actor, 0) {}
        catch {
            usdc.transfer(address(0xdead), assets);
        }
        vm.stopPrank();
        if (_perShare() < before) _flag("deposit lowered NAV per share");
    }

    function redeem(uint256 actorSeed, uint256 fraction) external {
        address actor = actors[actorSeed % 3];
        uint256 shares = vault.balanceOf(actor) * bound(fraction, 1, 100) / 100;
        if (shares == 0) return;
        uint256 before = _perShare();
        vm.prank(actor);
        vault.redeem(shares, actor, true);
        // In-kind payouts round down per token, so the remaining holders never lose.
        if (_perShare() + 1 < before) _flag("redeem lowered NAV per share");
    }

    function movePrice(uint256 tokenSeed, uint256 moveBps) public {
        uint256 i = tokenSeed % 6;
        int256 price = feeds[i].answer() * int256(bound(moveBps, 7_000, 14_000)) / 10_000;
        if (price < 1e4) price = 1e4;
        if (price > 1e14) price = 1e14;
        feeds[i].set(price);
    }

    /// @dev The price of one token moves and the keeper trades it toward its target, filled anywhere
    /// from -4% to +2% of the oracle price.
    function rebalance(uint256 tokenSeed, uint256 fillBps, uint256 fraction, uint256 moveBps) external {
        movePrice(tokenSeed, moveBps); // so there is a delta to trade
        (address sell, address buy, uint256 amount) = _plan(address(tokens[tokenSeed % 6]), bound(fraction, 25, 100));
        if (amount == 0) return;
        fillBps = bound(fillBps, 9_600, 10_200);
        (uint256 fair,) = registry.convert(sell, amount, buy);
        bytes memory data = abi.encodeCall(router.swap, (sell, buy, amount, fair * fillBps / 10_000));
        (uint256 navBefore,) = vault.nav();
        // Allowed loss: MaxSlippageBps of the trade plus rounding of one smallest unit of the token.
        (uint256 allowedLoss,) = registry.convert(sell, amount, address(usdc));
        (uint256 unitValue,) = registry.convert(sell == address(usdc) ? buy : sell, 1, address(usdc));
        allowedLoss = allowedLoss / 100 + 2 * unitValue + 10;

        vm.prank(keeper);
        try executor.executeTrade(sell, buy, amount, 0, address(router), data) returns (bool ok, uint256) {
            (uint256 navAfter,) = vault.nav();
            if (ok) {
                ++tradesExecuted;
                if (fillBps < 9_900) _flag("a fill below the slippage floor was accepted");
                if (navAfter + allowedLoss < navBefore) _flag("trade lost more than MaxSlippageBps");
            } else {
                ++tradesRefused;
                if (navAfter != navBefore) _flag("a refused trade changed NAV");
            }
        } catch {
            ++tradesRefused;
        }
    }

    function _plan(address token, uint256 percent) private view returns (address sell, address buy, uint256 amount) {
        (uint256 nav, uint256 current, uint256 target) = executor.position(token);
        if (target > current) {
            amount = (target - current) * percent / 100;
            uint256 reserve = usdc.balanceOf(address(vault));
            uint256 buffer = nav * 200 / 10_000;
            uint256 spendable = reserve > buffer ? reserve - buffer : 0;
            if (amount > spendable) amount = spendable;
            return (address(usdc), token, amount);
        }
        (amount,) = registry.convert(address(usdc), (current - target) * percent / 100, token);
        return (token, address(usdc), amount);
    }

    function collectFees(uint256 amount) external {
        amount = bound(amount, 0, 50_000 * 1e6);
        usdc.mint(address(waterfall), amount);
        feesIn += amount;
        waterfall.distribute();
    }

    function claim(uint256 bucketSeed) external {
        FeeWaterfall.Bucket bucket = FeeWaterfall.Bucket(1 + bucketSeed % 3);
        try waterfall.claim(bucket) returns (uint256 amount) {
            claimedOut += amount;
        } catch {}
    }

    function pushBasketReserve() external {
        uint256 amount = waterfall.accrued(FeeWaterfall.Bucket.Basket);
        uint256 before = _perShare();
        try waterfall.pushBasketReserve(0) {
            pushedToVault += amount;
            if (_perShare() < before) _flag("fee deposit lowered NAV per share");
        } catch {}
    }
}
