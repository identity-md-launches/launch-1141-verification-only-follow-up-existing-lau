// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Fixture} from "./utils/Fixture.sol";
import {V4Router} from "./utils/V4Router.sol";
import {MockERC20, MockWETH} from "./utils/Mocks.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {FeeHookDeployer} from "../src/FeeHookDeployer.sol";
import {FeeWaterfall} from "../src/FeeWaterfall.sol";

/// @dev Runs the hook inside the real Uniswap v4 PoolManager. Concrete contracts below choose the
/// quote currency, covering native ETH and an ERC-20 quote on either side of the pair.
abstract contract FeeHookBase is Fixture {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    uint256 internal constant HOOK_PIPS = 7_500; // 75% of the 1% fee

    PoolManager internal manager;
    V4Router internal v4;
    FeeHook internal hook;
    PoolKey internal key;
    address internal quote;
    address internal trader = address(0x7EADE);

    receive() external payable {}

    /// @dev Returns the vault's reserve asset and its decimals, the wrapped native token (or zero) and
    /// the pool's quote currency (zero for native ETH).
    function _currencies()
        internal
        virtual
        returns (address reserve, uint8 decimals, address weth, address quoteCurrency);

    function _poolManager() internal view override returns (address) {
        return address(manager);
    }

    function setUp() public override {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        v4 = new V4Router(IPoolManager(address(manager)));
        (address reserve, uint8 decimals, address weth, address quoteCurrency) = _currencies();
        quote = quoteCurrency;
        _deploySystem(reserve, decimals, weth, quoteCurrency);
        _queue(address(tl), abi.encodeCall(tl.setGuardian, (GUARDIAN)));
        _queue(address(tl), abi.encodeCall(tl.setKeeper, (KEEPER, true)));
        _flush();

        (bytes32 salt, bool found) = hookDeployer.findSalt(0, 400_000);
        assertTrue(found, "no salt found");
        hook = FeeHook(hookDeployer.deploy(salt));
        key = hook.poolKey();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Liquidity from this contract, which holds the IMDEX supply.
        imdex.approve(address(v4), type(uint256).max);
        _fund(address(this), 1_000_000 ether);
        v4.modifyLiquidity{value: quote == address(0) ? 500_000 ether : 0}(
            key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e24, salt: 0})
        );

        imdex.transfer(trader, 100_000 ether);
        _fund(trader, 100_000 ether);
        vm.prank(trader);
        imdex.approve(address(v4), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers

    function _fund(address who, uint256 amount) internal {
        if (quote == address(0)) {
            vm.deal(who, who.balance + amount);
        } else {
            MockERC20(quote).mint(who, amount);
            vm.prank(who);
            IERC20(quote).approve(address(v4), type(uint256).max);
        }
    }

    function _quoteBalance(address who) internal view returns (uint256) {
        return quote == address(0) ? who.balance : IERC20(quote).balanceOf(who);
    }

    /// @dev `buy` means paying quote for IMDEX. Returns what the trader paid and received.
    function _swap(bool buy, bool exactInput, uint256 amount)
        internal
        returns (uint256 quoteMoved, uint256 tokenMoved, uint256 fee)
    {
        bool zeroForOne = buy == hook.quoteIsCurrency0();
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 quoteBefore = _quoteBalance(trader);
        uint256 tokenBefore = imdex.balanceOf(trader);
        uint256 feesBefore = _quoteBalance(address(waterfall));
        uint256 value = (buy && quote == address(0)) ? quoteBefore : 0;
        vm.prank(trader);
        v4.swap{value: value}(key, params);
        uint256 quoteAfter = _quoteBalance(trader);
        uint256 tokenAfter = imdex.balanceOf(trader);
        quoteMoved = buy ? quoteBefore - quoteAfter : quoteAfter - quoteBefore;
        tokenMoved = buy ? tokenAfter - tokenBefore : tokenBefore - tokenAfter;
        fee = _quoteBalance(address(waterfall)) - feesBefore;
    }

    function test_quoteSpecifiedExactOutputPartialFillRevertsAtomically() public {
        bool zeroForOne = !hook.quoteIsCurrency0();
        _assertPartialRefused(
            SwapParams(
                zeroForOne,
                1000 ether,
                zeroForOne ? SQRT_PRICE_1_1 - SQRT_PRICE_1_1 / 1e6 : SQRT_PRICE_1_1 + SQRT_PRICE_1_1 / 1e6
            )
        );
    }

    function test_quoteSpecifiedExactInputExhaustedRangeRevertsAtomically() public {
        _fund(trader, 2_000_000 ether);
        bool zeroForOne = hook.quoteIsCurrency0();
        _assertPartialRefused(
            SwapParams(
                zeroForOne, -1_000_000 ether, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
    }

    function _assertPartialRefused(SwapParams memory params) private {
        uint256 quoteBefore = _quoteBalance(trader);
        uint256 tokenBefore = imdex.balanceOf(trader);
        uint256 feesBefore = _quoteBalance(address(waterfall));
        uint256 value = quote == address(0) ? quoteBefore : 0;
        vm.prank(trader);
        (bool ok,) = address(v4).call{value: value}(abi.encodeCall(v4.swap, (key, params)));
        assertFalse(ok, "partial fill charged full requested fee");
        assertEq(_quoteBalance(trader), quoteBefore);
        assertEq(imdex.balanceOf(trader), tokenBefore);
        assertEq(_quoteBalance(address(waterfall)), feesBefore);
    }

    function _lastSwapLpFee() internal view returns (uint24 lpFee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i != 0; --i) {
            if (logs[i - 1].topics[0] == SWAP_TOPIC) {
                (,,,,, lpFee) = abi.decode(logs[i - 1].data, (int128, int128, uint160, uint128, int24, uint24));
                return lpFee;
            }
        }
        revert("no swap event");
    }

    // ---------------------------------------------------------------- deployment

    function test_hookAddressCarriesExactlyTheRequiredPermissionBits() public view {
        assertEq(uint160(address(hook)) & 0x3FFF, hook.REQUIRED_FLAGS());
        assertEq(hook.REQUIRED_FLAGS(), 0x20CC);
        assertEq(hookDeployer.hook(), address(hook));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.projectToken(), address(imdex));
        assertEq(hook.quoteCurrency(), quote);
        assertEq(address(hook.waterfall()), address(waterfall));
        assertEq(address(hookDeployer.poolKey().hooks), address(hook));
    }

    function test_deployerRejectsWrongSaltAndSecondDeployment() public {
        FeeHookDeployer fresh = new FeeHookDeployer(address(manager), address(imdex), quote, address(waterfall));
        (bytes32 salt, bool found) = fresh.findSalt(0, 400_000);
        assertTrue(found);
        assertEq(uint160(fresh.computeAddress(salt)) & 0x3FFF, 0x20CC);

        bytes32 bad = bytes32(uint256(salt) + 1);
        if (uint160(fresh.computeAddress(bad)) & 0x3FFF != 0x20CC) {
            vm.expectRevert(); // the hook's constructor refuses an address without the bits
            fresh.deploy(bad);
        }
        vm.prank(BOB); // permissionless: the salt only selects the address
        address deployed = fresh.deploy(salt);
        assertEq(deployed, fresh.computeAddress(salt));
        vm.expectRevert(FeeHookDeployer.AlreadyDeployed.selector);
        fresh.deploy(salt);
    }

    function test_deployerRejectsAQuoteTheWaterfallCannotAccountFor() public {
        MockERC20 other = new MockERC20("OTHER", 18);
        vm.expectRevert(FeeHookDeployer.IncompatibleQuote.selector);
        new FeeHookDeployer(address(manager), address(imdex), address(other), address(waterfall));
        vm.expectRevert(FeeHookDeployer.ZeroAddress.selector);
        new FeeHookDeployer(address(0), address(imdex), quote, address(waterfall));
    }

    function test_hookAcceptsOnlyItsOnePool() public {
        // Same currencies, static fee: refused.
        PoolKey memory wrongFee = key;
        wrongFee.fee = 3000;
        vm.expectRevert();
        manager.initialize(wrongFee, SQRT_PRICE_1_1);

        PoolKey memory wrongSpacing = key;
        wrongSpacing.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(wrongSpacing, SQRT_PRICE_1_1);

        MockERC20 other = new MockERC20("OTHER", 18);
        PoolKey memory wrongPair = key;
        if (address(other) > Currency.unwrap(key.currency0)) wrongPair.currency1 = Currency.wrap(address(other));
        else wrongPair.currency0 = Currency.wrap(address(other));
        vm.expectRevert();
        manager.initialize(wrongPair, SQRT_PRICE_1_1);

        vm.expectRevert(); // already initialised
        manager.initialize(key, SQRT_PRICE_1_1);
        assertTrue(hook.poolRegistered());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
    }

    function test_callbacksAreOnlyForThePoolManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, 0);
        vm.expectRevert(FeeHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(FeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(FeeHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(FeeHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 0, 0, "");
        vm.expectRevert(FeeHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    // ---------------------------------------------------------------- the four swap shapes

    function test_buyExactInput_feeTakenFromTheQuotePaid() public {
        vm.recordLogs();
        (uint256 paid, uint256 received, uint256 fee) = _swap(true, true, 100 ether);
        assertEq(paid, 100 ether, "the trader pays exactly what they specified");
        assertEq(fee, 100 ether * HOOK_PIPS / 1e6);
        assertGt(received, 0);
        assertEq(_lastSwapLpFee(), 2_500, "LP share applied as the pool fee");
        assertEq(hook.totalFeesCollected(), fee);
        assertEq(hook.basketReserveRecorded(), fee * 4000 / 7500);
        assertEq(hook.swapCount(), 1);
    }

    function test_buyExactOutput_feeAddedToTheQuotePaid() public {
        vm.recordLogs();
        (uint256 paid, uint256 received, uint256 fee) = _swap(true, false, 100 ether);
        assertEq(received, 100 ether, "the trader receives exactly what they specified");
        assertEq(fee, (paid - fee) * HOOK_PIPS / 1e6, "fee charged on the quote the pool took in");
        assertGt(fee, 0);
        assertEq(_lastSwapLpFee(), 2_500);
    }

    function test_sellExactInput_feeTakenFromTheQuoteReceived() public {
        vm.recordLogs();
        (uint256 received, uint256 sold, uint256 fee) = _swap(false, true, 100 ether);
        assertEq(sold, 100 ether);
        assertEq(fee, (received + fee) * HOOK_PIPS / 1e6, "fee charged on the quote the pool paid out");
        assertGt(fee, 0);
        assertEq(_lastSwapLpFee(), 2_500);
    }

    function test_sellExactOutput_traderStillReceivesTheExactQuote() public {
        vm.recordLogs();
        (uint256 received, uint256 sold, uint256 fee) = _swap(false, false, 100 ether);
        assertEq(received, 100 ether, "the trader receives exactly what they specified");
        assertEq(fee, 100 ether * HOOK_PIPS / 1e6);
        assertGt(sold, 100 ether);
        assertEq(_lastSwapLpFee(), 2_500);
    }

    function test_feeIsAlwaysCollectedInTheQuoteCurrencyNeverInTheProjectToken() public {
        _swap(true, true, 10 ether);
        _swap(true, false, 10 ether);
        _swap(false, true, 10 ether);
        _swap(false, false, 10 ether);
        assertEq(imdex.balanceOf(address(waterfall)), 0);
        assertEq(imdex.balanceOf(address(hook)), 0);
        assertEq(_quoteBalance(address(hook)), 0, "the hook holds nothing");
        assertEq(_quoteBalance(address(waterfall)), hook.totalFeesCollected());
        assertEq(hook.swapCount(), 4);
    }

    function test_feeEventIsIndexedByPoolSenderAndCurrency() public {
        vm.recordLogs();
        (,, uint256 fee) = _swap(true, true, 100 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FeeCollected(bytes32,address,address,uint256,uint256,uint24,uint24,bool)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            seen = true;
            assertEq(logs[i].emitter, address(hook));
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(v4)))));
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(quote))));
            (uint256 feeAmount, uint256 basketAmount, uint24 lpFeePips, uint24 hookFeePips,) =
                abi.decode(logs[i].data, (uint256, uint256, uint24, uint24, bool));
            assertEq(feeAmount, fee);
            assertEq(basketAmount, fee * 4000 / 7500);
            assertEq(lpFeePips, 2_500);
            assertEq(hookFeePips, 7_500);
        }
        assertTrue(seen, "FeeCollected not emitted");
    }

    function test_dustSwapWithZeroFeeStillWorks() public {
        (uint256 paid,, uint256 fee) = _swap(true, true, 100);
        assertEq(paid, 100);
        assertEq(fee, 0);
        assertEq(hook.swapCount(), 0);
    }

    function testFuzz_feeAccountingMatchesAcrossSwapShapes(uint256 amount, bool buy, bool exactInput) public {
        amount = bound(amount, 1e6, 5_000 ether);
        uint256 collectedBefore = hook.totalFeesCollected();
        (uint256 quoteMoved,, uint256 fee) = _swap(buy, exactInput, amount);

        assertEq(hook.totalFeesCollected() - collectedBefore, fee, "recorded equals transferred");
        assertEq(_quoteBalance(address(waterfall)), hook.totalFeesCollected());
        // The fee is 0.75% of the quote leg at pool level, whichever shape the swap has.
        uint256 poolQuote = buy ? quoteMoved - fee : quoteMoved + fee;
        if (buy && exactInput) poolQuote = quoteMoved;
        if (!buy && !exactInput) poolQuote = quoteMoved;
        assertEq(fee, poolQuote * HOOK_PIPS / 1e6);
        assertEq(_quoteBalance(address(hook)), 0);
    }

    // ---------------------------------------------------------------- configuration follows the timelock

    function test_feeAndSplitChangesReachTheHookThroughTheTimelockOnly() public {
        _queue(address(waterfall), abi.encodeCall(waterfall.setSwapFee, (20_000, 0)));
        _queue(address(waterfall), abi.encodeCall(waterfall.setSplit, (5000, 5000, 0, 0, 0)));
        _flush();
        vm.recordLogs();
        (,, uint256 fee) = _swap(true, true, 100 ether);
        assertEq(fee, 100 ether * 10_000 / 1e6, "half of a 2% fee");
        assertEq(_lastSwapLpFee(), 10_000, "the other half is the LP fee");
        assertEq(hook.basketReserveRecorded(), fee, "all of the hook fee is basket reserve under this split");
    }

    function test_zeroHookFeeLeavesSwapsUntouched() public {
        _gov(address(waterfall), abi.encodeCall(waterfall.setSplit, (0, 10_000, 0, 0, 0)));
        vm.recordLogs();
        (uint256 paid,, uint256 fee) = _swap(true, true, 100 ether);
        assertEq(paid, 100 ether);
        assertEq(fee, 0);
        assertEq(_lastSwapLpFee(), 10_000);
    }

    // ---------------------------------------------------------------- end to end

    function test_feesFlowFromSwapToWaterfallToVaultWithoutTradingTheBasket() public {
        _swap(true, true, 1_000 ether);
        _swap(false, true, 1_000 ether);
        uint256 collected = hook.totalFeesCollected();
        assertEq(waterfall.pendingDistribution(), collected);

        assertEq(waterfall.distribute(), collected);
        address reserve = waterfall.reserveAsset();
        assertEq(IERC20(reserve).balanceOf(address(waterfall)), collected, "native fees are wrapped, ERC-20 kept");
        uint256 basket = waterfall.accrued(FeeWaterfall.Bucket.Basket);
        assertGe(basket, hook.basketReserveRecorded(), "never less than the hook recorded");
        assertLe(basket - hook.basketReserveRecorded(), 3);
        assertEq(
            basket + waterfall.accrued(FeeWaterfall.Bucket.Swarm) + waterfall.accrued(FeeWaterfall.Bucket.Protocol)
                + waterfall.accrued(FeeWaterfall.Bucket.Utility),
            collected
        );

        vm.prank(KEEPER);
        uint256 shares = waterfall.pushBasketReserve(0);
        assertEq(vault.balanceOf(address(tl)), shares);
        assertEq(IERC20(reserve).balanceOf(address(vault)), basket);
        assertEq(vault.heldTokens().length, 0, "the hook path never buys basket assets");
    }
}

contract FeeHookNativeEthTest is FeeHookBase {
    function _currencies() internal override returns (address, uint8, address, address) {
        MockWETH weth = new MockWETH();
        return (address(weth), 18, address(weth), address(0));
    }

    function test_nativeFeesArriveAsEthAndTheReceiveHookDoesNothing() public {
        (,, uint256 fee) = _swap(true, true, 100 ether);
        assertEq(address(waterfall).balance, fee);
        assertEq(waterfall.totalAccrued(), 0, "receiving ETH mid-swap changes no state");
        vm.prank(address(tl));
        vm.expectRevert(FeeWaterfall.NotRescuable.selector);
        waterfall.rescue(address(0), OWNER); // fee ETH cannot be swept by governance
    }
}

contract FeeHookErc20QuoteLowTest is FeeHookBase {
    /// @dev An ERC-20 quote that sorts below the project token (currency0).
    function _currencies() internal override returns (address, uint8, address, address) {
        MockERC20 impl = new MockERC20("USDX", 18);
        address low = address(0x1111);
        vm.etch(low, address(impl).code);
        return (low, 18, address(0), low);
    }

    function test_quoteIsCurrencyZero() public view {
        assertTrue(hook.quoteIsCurrency0());
    }
}

contract FeeHookErc20QuoteHighTest is FeeHookBase {
    /// @dev An ERC-20 quote that sorts above the project token (currency1).
    function _currencies() internal override returns (address, uint8, address, address) {
        MockERC20 impl = new MockERC20("USDX", 18);
        address high = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        vm.etch(high, address(impl).code);
        return (high, 18, address(0), high);
    }

    function test_quoteIsCurrencyOne() public view {
        assertFalse(hook.quoteIsCurrency0());
    }
}
