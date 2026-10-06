// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAssetRegistry, IEpochManager, IIndexVault, ITimelockedAdmin, Param, Role} from "./interfaces/IIndex.sol";

/// @title RebalanceExecutor
/// @notice The only path by which basket assets are traded. A keeper chooses a route and calldata;
/// this contract decides whether the trade is allowed and whether its result is acceptable.
/// @dev A keeper cannot choose what the basket is, how much may be traded or at what price:
///  - one leg of every trade is the reserve asset, the other a token;
///  - a token can be bought only if it is an eligible member of the active basket, and only up to
///    its target deficit; it can be sold only down to its target (to zero when it is no longer a
///    member, revoked or quarantined), so only the delta between holdings and targets ever trades;
///  - reserve spending always leaves the reserve buffer in place;
///  - the output must reach the oracle value less `MaxSlippageBps`, measured on the vault's balance;
///  - routers are allowlisted by the timelock and approved for exactly the amount sold;
///  - trades happen inside the rebalance window that opens with a new epoch or once per interval.
/// A trade whose swap reverts or under-delivers is undone and counted; after `FailureThreshold`
/// consecutive failures further buys are blocked. Only confirmed quarantine zeroes its target;
/// keeper-controlled route failures cannot grant exits or veto signed proposals.
contract RebalanceExecutor {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @dev Mirrors IndexVault.MAX_HELD.
    uint256 private constant MAX_HELD = 10;
    uint256 private constant BALANCE_GAS = 500_000;

    ITimelockedAdmin public immutable admin;
    IAssetRegistry public immutable registry;
    IEpochManager public immutable epochs;
    IIndexVault public immutable vault;
    address public immutable reserve;

    /// @notice Start of the current rebalance window and the epoch it was opened for.
    uint64 public windowStart;
    uint64 public windowEpoch;
    mapping(address token => uint256) public failureCount;
    mapping(address token => uint256) private _failureVersion;
    uint256 private _lock = 1;

    event TradeExecuted(
        address indexed sellToken,
        address indexed buyToken,
        address indexed router,
        uint256 sellAmount,
        uint256 received,
        uint256 minOut
    );
    event TradeFailed(
        address indexed sellToken, address indexed buyToken, address indexed router, uint256 sellAmount, bytes reason
    );
    event WindowOpened(uint64 indexed epoch, uint64 start);
    event AutoQuarantined(address indexed token, uint256 failures);

    error ZeroAddress();
    error ZeroAmount();
    error Paused();
    error Reentrancy();
    error NotKeeper();
    error NotTimelock();
    error NotSelf();
    error RouterNotApproved(address router);
    error InvalidPair();
    error NoActiveBasket();
    error NotBuyable(address token);
    error NotHeld(address token);
    error UnpricedHolding(address token);
    error PriceUnavailable();
    error NothingToTrade();
    error ExceedsDelta(uint256 tradeValue, uint256 allowedValue);
    error BelowDriftThreshold();
    error WindowClosed();
    error NotQuarantined(address token);
    error HeldListFull();
    error RouterCallFailed(bytes reason);
    error InsufficientOutput(uint256 received, uint256 minOut);

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address admin_, address registry_, address epochs_, address vault_) {
        if (admin_ == address(0) || registry_ == address(0) || epochs_ == address(0) || vault_ == address(0)) {
            revert ZeroAddress();
        }
        admin = ITimelockedAdmin(admin_);
        registry = IAssetRegistry(registry_);
        epochs = IEpochManager(epochs_);
        vault = IIndexVault(vault_);
        reserve = IIndexVault(vault_).asset();
    }

    // ---------------------------------------------------------------- keeper

    /// @notice Sells `sellAmount` of `sellToken` for `buyToken` through `router`, if the rules allow it.
    /// @param minOut Keeper's own floor; the oracle floor applies whenever it is higher.
    /// @return success False when the swap failed or under-delivered; the vault is then unchanged.
    function executeTrade(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minOut,
        address router,
        bytes calldata data
    ) external nonReentrant returns (bool success, uint256 received) {
        if (admin.roleOf(msg.sender) != Role.Keeper) revert NotKeeper();
        if (admin.paused()) revert Paused();
        _checkRouter(router, sellToken, buyToken);

        uint256 oracleMinOut = _authorize(sellToken, buyToken, sellAmount);
        if (oracleMinOut > minOut) minOut = oracleMinOut;

        address token = sellToken == reserve ? buyToken : sellToken;
        uint256 version = registry.quarantineVersion(token);
        if (_failureVersion[token] != version) {
            delete failureCount[token];
            _failureVersion[token] = version;
        }
        try this.swapThroughRouter(sellToken, buyToken, sellAmount, minOut, router, data) returns (uint256 out) {
            delete failureCount[token];
            emit TradeExecuted(sellToken, buyToken, router, sellAmount, out, minOut);
            return (true, out);
        } catch (bytes memory reason) {
            emit TradeFailed(sellToken, buyToken, router, sellAmount, reason);
            uint256 failures = ++failureCount[token];
            if (
                failures >= registry.param(Param.FailureThreshold) && !registry.isQuarantined(token)
                    && !registry.isAutoQuarantined(token)
            ) {
                registry.quarantine(token);
                emit AutoQuarantined(token, failures);
            }
            return (false, 0);
        }
    }

    // ---------------------------------------------------------------- timelock

    /// @notice Sells a quarantined token for the reserve with an explicit floor, for the case where
    /// its price feed is dead and the keeper path cannot price it. Timelock only, so it is delayed
    /// and open to guardian veto.
    function disposeQuarantined(address token, uint256 amount, uint256 minOut, address router, bytes calldata data)
        external
        nonReentrant
        returns (uint256 received)
    {
        if (msg.sender != address(admin)) revert NotTimelock();
        if (!registry.isQuarantined(token)) revert NotQuarantined(token);
        if (amount == 0 || minOut == 0) revert ZeroAmount();
        _checkRouter(router, token, reserve);
        received = _swap(token, reserve, amount, minOut, router, data);
        emit TradeExecuted(token, reserve, router, amount, received, minOut);
    }

    // ---------------------------------------------------------------- swap

    /// @dev External only so `executeTrade` can undo a failed swap with try/catch. Not callable by others.
    function swapThroughRouter(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minOut,
        address router,
        bytes calldata data
    ) external returns (uint256) {
        if (msg.sender != address(this)) revert NotSelf();
        return _swap(sellToken, buyToken, sellAmount, minOut, router, data);
    }

    function _swap(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minOut,
        address router,
        bytes calldata data
    ) private returns (uint256 received) {
        uint256 buyBefore = IERC20(buyToken).balanceOf(address(vault));
        vault.beginTrade(sellToken, sellAmount);

        IERC20(sellToken).forceApprove(router, sellAmount);
        (bool ok, bytes memory reason) = router.call(data);
        if (!ok) revert RouterCallFailed(reason);
        IERC20(sellToken).forceApprove(router, 0);

        // Everything this contract holds goes back: the proceeds and any unsold remainder.
        uint256 bought = IERC20(buyToken).balanceOf(address(this));
        if (bought != 0) IERC20(buyToken).safeTransfer(address(vault), bought);
        uint256 unsold = IERC20(sellToken).balanceOf(address(this));
        if (unsold != 0) IERC20(sellToken).safeTransfer(address(vault), unsold);

        // Measured on the vault, so a token that keeps part of a transfer cannot pass the floor.
        uint256 buyAfter = IERC20(buyToken).balanceOf(address(vault));
        received = buyAfter > buyBefore ? buyAfter - buyBefore : 0;
        if (received < minOut) revert InsufficientOutput(received, minOut);
        vault.endTrade(buyToken);
    }

    // ---------------------------------------------------------------- rules

    /// @notice What the rules would allow right now for one token, in reserve units.
    /// @return nav Vault NAV as the executor counts it (confirmed-quarantined positions count as zero).
    /// @return current Value currently held in `token`.
    /// @return target Value the active basket assigns to `token`.
    function position(address token) external view returns (uint256 nav, uint256 current, uint256 target) {
        nav = _nav();
        current = _valueOf(token);
        target = _target(token, nav);
    }

    /// @dev Reverts unless the trade is inside the rules. Returns the oracle floor on the output.
    function _authorize(address sellToken, address buyToken, uint256 sellAmount)
        private
        returns (uint256 oracleMinOut)
    {
        if (sellAmount == 0) revert ZeroAmount();
        if ((sellToken == reserve) == (buyToken == reserve)) revert InvalidPair();

        uint256 nav = _nav();
        uint256 threshold = nav * registry.param(Param.DriftThresholdBps) / BPS;
        bool exit;
        bool material;

        if (sellToken == reserve) {
            // Buying a member: bounded by its deficit and by the reserve above the buffer.
            if (epochs.targetWeightBps(buyToken) == 0 || !registry.isApproved(buyToken)) revert NotBuyable(buyToken);
            if (registry.isQuarantined(buyToken) || registry.isAutoQuarantined(buyToken)) revert NotBuyable(buyToken);
            if (!vault.isHeld(buyToken) && vault.heldTokens().length >= MAX_HELD) revert HeldListFull();
            uint256 target = _target(buyToken, nav);
            uint256 current = _valueOf(buyToken);
            if (current >= target) revert NothingToTrade();
            uint256 deficit = target - current;
            uint256 buffer = nav * registry.param(Param.ReserveBufferBps) / BPS;
            uint256 reserveBalance = IERC20(reserve).balanceOf(address(vault));
            uint256 spendable = reserveBalance > buffer ? reserveBalance - buffer : 0;
            uint256 allowed = deficit < spendable ? deficit : spendable;
            if (sellAmount > allowed) revert ExceedsDelta(sellAmount, allowed);
            material = deficit >= threshold;
        } else {
            // Selling a token: only the part above its target.
            if (!vault.isHeld(sellToken)) revert NotHeld(sellToken);
            uint256 target = _target(sellToken, nav);
            uint256 balance = _balanceOf(sellToken);
            (uint256 current, bool priced) = registry.convert(sellToken, balance, reserve);
            if (!priced) revert PriceUnavailable();
            exit = target == 0;
            if (!exit && current <= target) revert NothingToTrade();
            uint256 excess = current - target;
            if (exit) {
                if (sellAmount > balance) revert ExceedsDelta(sellAmount, balance);
            } else {
                (uint256 tradeValue,) = registry.convert(sellToken, sellAmount, reserve);
                if (tradeValue > excess) revert ExceedsDelta(tradeValue, excess);
            }
            material = excess >= threshold;
        }

        // Leaving a position that should not be held is always allowed. Anything else needs an
        // active basket, a material drift and an open window.
        if (!exit) {
            if (!material) revert BelowDriftThreshold();
            _requireWindow();
        }

        (uint256 fair, bool ok) = registry.convert(sellToken, sellAmount, buyToken);
        if (!ok) revert PriceUnavailable();
        // Only the entire remainder of a zero-target position may clear without a value floor.
        if (fair == 0 && !(exit && sellAmount == _balanceOf(sellToken))) revert NothingToTrade();
        oracleMinOut = Math.mulDiv(fair, BPS - registry.param(Param.MaxSlippageBps), BPS, Math.Rounding.Ceil);
    }

    function _requireWindow() private {
        uint64 current = epochs.epoch();
        if (current == 0) revert NoActiveBasket();
        uint256 anchor = epochs.activatedAt();
        uint256 interval = registry.param(Param.RebalanceInterval);
        uint256 start = anchor + ((block.timestamp - anchor) / interval) * interval;
        if (block.timestamp > start + registry.param(Param.RebalanceWindow)) revert WindowClosed();
        if (current != windowEpoch || windowStart != start) {
            windowEpoch = current;
            windowStart = uint64(start);
            emit WindowOpened(current, windowStart);
        }
    }

    function _checkRouter(address router, address sellToken, address buyToken) private view {
        if (
            !registry.isRouterApproved(router) || router == address(vault) || router == address(this)
                || router == address(registry) || router == address(admin) || router == address(epochs)
                || router == sellToken || router == buyToken
        ) revert RouterNotApproved(router);
    }

    /// @dev Value the basket assigns to `token`: its weight applied to NAV net of the reserve buffer.
    /// Zero for anything that is not an approved, unquarantined member.
    function _target(address token, uint256 nav) private view returns (uint256) {
        if (token == reserve || !registry.isApproved(token) || registry.isQuarantined(token)) return 0;
        uint256 investable = nav * (BPS - registry.param(Param.ReserveBufferBps)) / BPS;
        return investable * epochs.targetWeightBps(token) / BPS;
    }

    function _valueOf(address token) private view returns (uint256 value) {
        if (token != reserve && !vault.isHeld(token)) return 0;
        uint256 balance = _balanceOf(token);
        if (token == reserve || balance == 0) return balance;
        (value,) = registry.convert(token, balance, reserve);
    }

    /// @dev Confirmed-quarantined positions count as zero and are skipped before balance reads.
    /// Automatic buy blocks retain their value and target; all other balance reads are gas-capped.
    function _nav() private view returns (uint256 nav) {
        nav = IERC20(reserve).balanceOf(address(vault));
        address[] memory held = vault.heldTokens();
        for (uint256 i; i < held.length; ++i) {
            if (registry.isQuarantined(held[i])) continue;
            (bool ok, bytes memory ret) =
                held[i].staticcall{gas: BALANCE_GAS}(abi.encodeCall(IERC20.balanceOf, (address(vault))));
            uint256 value;
            if (ok && ret.length >= 32) {
                uint256 balance = abi.decode(ret, (uint256));
                if (balance == 0) continue;
                (value, ok) = registry.convert(held[i], balance, reserve);
            } else {
                ok = false;
            }
            if (ok) nav += value;
            else revert UnpricedHolding(held[i]);
        }
    }

    function _balanceOf(address token) private view returns (uint256) {
        (bool ok, bytes memory ret) =
            token.staticcall{gas: BALANCE_GAS}(abi.encodeCall(IERC20.balanceOf, (address(vault))));
        if (!ok || ret.length < 32) revert UnpricedHolding(token);
        return abi.decode(ret, (uint256));
    }
}
