// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IFeeWaterfall} from "./interfaces/IIndex.sol";

/// @dev The hook-permission bits the FeeHook's address must carry, and no others:
/// beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta.
uint160 constant FEE_HOOK_FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
/// @dev Mask of all fourteen v4 hook-permission bits.
uint160 constant ALL_HOOK_FLAGS = (1 << 14) - 1;

/// @title FeeHook
/// @notice Uniswap v4 hook for the one project-token pool. On every swap it collects the project fee
/// in the quote currency, sends it to the FeeWaterfall and records it. It never trades the basket.
/// @dev The fee read from the waterfall has two parts. The liquidity providers' part is returned as
/// the pool's LP fee for the swap (the pool must be a dynamic-fee pool). The rest is taken by the hook
/// from whichever side of the swap is the quote currency: in `beforeSwap` when the quote currency is
/// the specified amount (requiring a full fee-adjusted fill), in `afterSwap` when it is the
/// unspecified one. Partial quote-specified fills revert atomically. The hook holds no funds, has
/// no owner and no configuration of its own.
contract FeeHook is IHooks {
    uint160 public constant REQUIRED_FLAGS = FEE_HOOK_FLAGS;
    int24 public constant TICK_SPACING = 60;
    uint256 private constant PIPS = 1_000_000;

    struct FeeQuote {
        uint24 lpFeePips;
        uint24 hookFeePips;
        uint16 basketBps;
        uint16 nonLpBps;
    }

    IPoolManager public immutable poolManager;
    address public immutable projectToken;
    /// @notice The currency fees are collected in; the zero address means native ETH.
    address public immutable quoteCurrency;
    IFeeWaterfall public immutable waterfall;
    bool public immutable quoteIsCurrency0;

    PoolId public poolId;
    bool public poolRegistered;
    /// @notice Lifetime fees sent to the waterfall, in the quote currency.
    uint256 public totalFeesCollected;
    /// @notice Lifetime basket-reserve share of those fees, as computed swap by swap. The waterfall
    /// never credits the basket less than this.
    uint256 public basketReserveRecorded;
    uint256 public swapCount;

    event PoolRegistered(PoolId indexed poolId, address indexed initializer, uint160 sqrtPriceX96);
    event FeeCollected(
        PoolId indexed poolId,
        address indexed sender,
        address indexed currency,
        uint256 feeAmount,
        uint256 basketReserveAmount,
        uint24 lpFeePips,
        uint24 hookFeePips,
        bool zeroForOne
    );

    error ZeroAddress();
    error InvalidHookAddress();
    error NotPoolManager();
    error PoolAlreadyRegistered();
    error WrongPool();
    error HookNotImplemented();
    error FeeOverflow();
    error PartialFill();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(address poolManager_, address projectToken_, address quoteCurrency_, address waterfall_) {
        if (poolManager_ == address(0) || projectToken_ == address(0) || waterfall_ == address(0)) {
            revert ZeroAddress();
        }
        if (projectToken_ == quoteCurrency_) revert WrongPool();
        if (uint160(address(this)) & ALL_HOOK_FLAGS != FEE_HOOK_FLAGS) revert InvalidHookAddress();
        poolManager = IPoolManager(poolManager_);
        projectToken = projectToken_;
        quoteCurrency = quoteCurrency_;
        waterfall = IFeeWaterfall(waterfall_);
        quoteIsCurrency0 = quoteCurrency_ < projectToken_;
    }

    /// @notice The only pool key this hook accepts.
    function poolKey() public view returns (PoolKey memory) {
        (address currency0, address currency1) =
            quoteIsCurrency0 ? (quoteCurrency, projectToken) : (projectToken, quoteCurrency);
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    // ---------------------------------------------------------------- hook callbacks

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (poolRegistered) revert PoolAlreadyRegistered();
        PoolKey memory expected = poolKey();
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(expected.currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(expected.currency1) || key.fee != expected.fee
                || key.tickSpacing != expected.tickSpacing || address(key.hooks) != address(this)
        ) revert WrongPool();
        poolRegistered = true;
        poolId = key.toId();
        emit PoolRegistered(poolId, sender, sqrtPriceX96);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        FeeQuote memory q = _feeQuote();
        BeforeSwapDelta delta = BeforeSwapDeltaLibrary.ZERO_DELTA;

        // The quote currency is the specified amount: charge the fee on it before the swap runs.
        if (_quoteIsSpecified(params)) {
            uint256 specified =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            delta = toBeforeSwapDelta(_collect(sender, specified, q, params.zeroForOne), 0);
        }
        return (IHooks.beforeSwap.selector, delta, q.lpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata params,
        BalanceDelta swapDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (_quoteIsSpecified(params)) {
            // beforeSwap adjusted the pool request by its positive specified fee delta. v4 passes
            // the raw pool delta here, before subtracting that fee. Refuse any unfilled request;
            // reverting also undoes the provisional collection and every fee-accounting event.
            uint256 requested =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 fee = requested * _feeQuote().hookFeePips / PIPS;
            int256 filled = quoteIsCurrency0 ? swapDelta.amount0() : swapDelta.amount1();
            if (filled != params.amountSpecified + int256(fee)) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }

        // The quote currency is the unspecified amount: charge the fee on what the swap produced.
        int256 quoteDelta = quoteIsCurrency0 ? swapDelta.amount0() : swapDelta.amount1();
        uint256 quoteAmount = quoteDelta < 0 ? uint256(-quoteDelta) : uint256(quoteDelta);
        return (IHooks.afterSwap.selector, _collect(sender, quoteAmount, _feeQuote(), params.zeroForOne));
    }

    // ---------------------------------------------------------------- unused callbacks

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------- internals

    /// @dev The specified currency is currency0 exactly when the swap is zeroForOne exact-input or
    /// oneForZero exact-output.
    function _quoteIsSpecified(SwapParams calldata params) private view returns (bool) {
        bool specifiedIsCurrency0 = params.zeroForOne == (params.amountSpecified < 0);
        return specifiedIsCurrency0 == quoteIsCurrency0;
    }

    function _feeQuote() private view returns (FeeQuote memory q) {
        (q.lpFeePips, q.hookFeePips, q.basketBps, q.nonLpBps) = waterfall.feeQuote();
    }

    /// @dev Charges the hook fee on `quoteAmount`. Records first, then moves the fee out of the pool
    /// manager; the debt that creates for the hook is cancelled by the delta the callback returns.
    function _collect(address sender, uint256 quoteAmount, FeeQuote memory q, bool zeroForOne)
        private
        returns (int128 feeDelta)
    {
        uint256 fee = quoteAmount * q.hookFeePips / PIPS;
        if (fee == 0) return 0;
        feeDelta = _toInt128(fee);
        uint256 basketShare = q.nonLpBps == 0 ? fee : fee * q.basketBps / q.nonLpBps;
        totalFeesCollected += fee;
        basketReserveRecorded += basketShare;
        ++swapCount;
        emit FeeCollected(poolId, sender, quoteCurrency, fee, basketShare, q.lpFeePips, q.hookFeePips, zeroForOne);
        poolManager.take(Currency.wrap(quoteCurrency), address(waterfall), fee);
    }

    function _toInt128(uint256 value) private pure returns (int128) {
        if (value > uint256(uint128(type(int128).max))) revert FeeOverflow();
        return int128(uint128(value));
    }
}
