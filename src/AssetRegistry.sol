// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAggregatorV3, ITimelockedAdmin, Param, Role} from "./interfaces/IIndex.sol";

/// @title AssetRegistry
/// @notice The deterministic rule book: the token allowlist, each token's price feed and weight cap,
/// the approved swap routers and every numeric limit the epoch manager, vault and executor enforce.
/// @dev Everything here is changed only by the TimelockedAdmin, except quarantine, which can only
/// tighten: the guardian or the executor may quarantine a token, and anyone may quarantine a token
/// whose price feed is demonstrably stale. Only the timelock releases a quarantine.
contract AssetRegistry {
    struct Asset {
        bool approved;
        bool quarantined;
        uint8 decimals;
        uint8 feedDecimals;
        uint16 maxWeightBps;
        uint32 heartbeat;
        uint40 listedAt;
        address feed;
        bytes32 reviewHash;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_TOKEN_AGE_FLOOR = 30 days;
    uint256 private constant PARAM_COUNT = 15;

    ITimelockedAdmin public immutable admin;
    address public immutable reserveAsset;
    uint8 public immutable reserveDecimals;

    address public reserveFeed;
    uint8 public reserveFeedDecimals;
    uint32 public reserveHeartbeat;

    /// @notice Version and content hash of the published methodology document proposals must cite.
    uint32 public methodologyVersion;
    bytes32 public methodologyHash;

    mapping(address token => Asset) private _assets;
    /// @notice Router failures block buys only. They are not evidence for liquidation or exclusion.
    mapping(address token => bool) public isAutoQuarantined;
    /// @notice Release invalidates the executor's previous failure streak, including across re-entry.
    mapping(address token => uint256) public quarantineVersion;
    address[] private _listed;
    mapping(address router => bool) public isRouterApproved;
    mapping(Param key => uint256) private _params;

    event TokenApproved(
        address indexed token,
        address indexed feed,
        uint32 heartbeat,
        uint16 maxWeightBps,
        uint40 listedAt,
        bytes32 reviewHash
    );
    event TokenRevoked(address indexed token);
    event TokenQuarantined(address indexed token, address indexed by);
    event TokenReleased(address indexed token);
    event TokenAutoQuarantined(address indexed token);
    event ReserveFeedSet(address indexed feed, uint32 heartbeat);
    event RouterSet(address indexed router, bool approved);
    event ParamSet(Param indexed key, uint256 oldValue, uint256 newValue);
    event MethodologySet(uint32 indexed version, bytes32 contentHash);

    error ZeroAddress();
    error NotTimelock();
    error NotAuthorized();
    error InvalidToken();
    error InvalidFeed();
    error InvalidValue();
    error NotListed();
    error PriceIsFresh();
    error AlreadyQuarantined();

    modifier onlyAdmin() {
        _requireAdmin();
        _;
    }

    constructor(address admin_, address reserveAsset_, uint8 reserveDecimals_) {
        if (admin_ == address(0) || reserveAsset_ == address(0)) revert ZeroAddress();
        if (reserveDecimals_ > 18) revert InvalidValue();
        admin = ITimelockedAdmin(admin_);
        reserveAsset = reserveAsset_;
        reserveDecimals = reserveDecimals_;

        _params[Param.MaxSlippageBps] = 100;
        _params[Param.ReserveBufferBps] = 200;
        _params[Param.DriftThresholdBps] = 250;
        _params[Param.MinTokenAge] = 30 days;
        _params[Param.MinMarketCapUsd] = 250_000_000;
        _params[Param.MinLiquidityUsd] = 5_000_000;
        _params[Param.MinVolumeUsd] = 5_000_000;
        _params[Param.MaxSnapshotAge] = 1 days;
        _params[Param.ProposalDelay] = 6 hours;
        _params[Param.RebalanceInterval] = 7 days;
        _params[Param.RebalanceWindow] = 2 days;
        _params[Param.MaxAdditionsPerEpoch] = 2;
        _params[Param.StaleBasketAfter] = 3 days;
        _params[Param.FailureThreshold] = 3;
        _params[Param.DepositFeeBps] = 0;
        methodologyVersion = 1;
    }

    // ---------------------------------------------------------------- timelocked configuration

    /// @param listedAt Attested timestamp of the token's deployment or first liquidity, whichever is
    /// later. The token is not eligible until `MinTokenAge` has passed since then.
    /// @param reviewHash Hash of the contract, holder-concentration, upgrade and security review.
    function approveToken(
        address token,
        address feed,
        uint32 heartbeat,
        uint16 maxWeightBps_,
        uint40 listedAt,
        bytes32 reviewHash
    ) external onlyAdmin {
        if (token == address(0) || token == reserveAsset || token.code.length == 0) {
            revert InvalidToken();
        }
        if (maxWeightBps_ == 0 || maxWeightBps_ > BPS || listedAt == 0 || listedAt > block.timestamp) {
            revert InvalidValue();
        }
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        if (tokenDecimals > 30) revert InvalidToken();
        uint8 feedDecimals = _checkFeed(feed, heartbeat);

        Asset storage a = _assets[token];
        if (a.feed == address(0)) _listed.push(token);
        a.approved = true;
        a.decimals = tokenDecimals;
        a.feedDecimals = feedDecimals;
        a.maxWeightBps = maxWeightBps_;
        a.heartbeat = heartbeat;
        a.listedAt = listedAt;
        a.feed = feed;
        a.reviewHash = reviewHash;
        emit TokenApproved(token, feed, heartbeat, maxWeightBps_, listedAt, reviewHash);
    }

    /// @notice Removes a token from the allowlist. Its feed is kept so a remaining position can
    /// still be valued and sold.
    function revokeToken(address token) external onlyAdmin {
        if (!_assets[token].approved) revert NotListed();
        _assets[token].approved = false;
        emit TokenRevoked(token);
    }

    function releaseQuarantine(address token) external onlyAdmin {
        if (!_assets[token].quarantined && !isAutoQuarantined[token]) revert NotListed();
        _assets[token].quarantined = false;
        delete isAutoQuarantined[token];
        ++quarantineVersion[token];
        emit TokenReleased(token);
    }

    function setReserveFeed(address feed, uint32 heartbeat) external onlyAdmin {
        reserveFeedDecimals = _checkFeed(feed, heartbeat);
        reserveFeed = feed;
        reserveHeartbeat = heartbeat;
        emit ReserveFeedSet(feed, heartbeat);
    }

    function setRouter(address router, bool approved) external onlyAdmin {
        if (router == address(0) || (approved && router.code.length == 0)) revert ZeroAddress();
        isRouterApproved[router] = approved;
        emit RouterSet(router, approved);
    }

    function setParam(Param key, uint256 value) external onlyAdmin {
        (uint256 lo, uint256 hi) = paramBounds(key);
        if (value < lo || value > hi) revert InvalidValue();
        if (key == Param.RebalanceWindow && value > _params[Param.RebalanceInterval]) revert InvalidValue();
        if (key == Param.RebalanceInterval && value < _params[Param.RebalanceWindow]) revert InvalidValue();
        if (key == Param.ProposalDelay && value >= _params[Param.MaxSnapshotAge]) revert InvalidValue();
        if (key == Param.MaxSnapshotAge && value <= _params[Param.ProposalDelay]) revert InvalidValue();
        emit ParamSet(key, _params[key], value);
        _params[key] = value;
    }

    function setMethodology(uint32 version, bytes32 contentHash) external onlyAdmin {
        if (version <= methodologyVersion || contentHash == bytes32(0)) revert InvalidValue();
        methodologyVersion = version;
        methodologyHash = contentHash;
        emit MethodologySet(version, contentHash);
    }

    // ---------------------------------------------------------------- quarantine (tighten only)

    /// @notice Guardian/timelock confirm an exclusion with a zero target. Executor reports only
    /// stop further buys: a keeper-controlled router failure cannot change the signed basket.
    function quarantine(address token) external {
        bool allowed = msg.sender == admin.guardian() || msg.sender == address(admin);
        if (!allowed) {
            if (admin.roleOf(msg.sender) != Role.Executor) revert NotAuthorized();
            if (_assets[token].feed == address(0)) revert NotListed();
            if (isAutoQuarantined[token] || _assets[token].quarantined) revert AlreadyQuarantined();
            isAutoQuarantined[token] = true;
            emit TokenAutoQuarantined(token);
            return;
        }
        _quarantine(token);
    }

    /// @notice Anyone can quarantine a listed token whose price feed is stale, non-positive or failing.
    function quarantineIfStale(address token) external {
        Asset storage a = _assets[token];
        if (a.feed == address(0)) revert NotListed();
        (, bool ok) = _feedPrice(a.feed, a.feedDecimals, a.heartbeat);
        if (ok) revert PriceIsFresh();
        _quarantine(token);
    }

    // ---------------------------------------------------------------- views

    function param(Param key) external view returns (uint256) {
        return _params[key];
    }

    function allParams() external view returns (uint256[PARAM_COUNT] memory values) {
        for (uint256 i; i < PARAM_COUNT; ++i) {
            values[i] = _params[Param(i)];
        }
    }

    /// @notice Hard bounds the timelock itself cannot leave.
    function paramBounds(Param key) public pure returns (uint256 lo, uint256 hi) {
        if (key == Param.MaxSlippageBps) return (1, 1_000);
        if (key == Param.ReserveBufferBps) return (0, 5_000);
        if (key == Param.DriftThresholdBps) return (0, 2_000);
        if (key == Param.MinTokenAge) return (MIN_TOKEN_AGE_FLOOR, 3650 days);
        if (key == Param.MaxSnapshotAge) return (1 hours, 7 days);
        if (key == Param.ProposalDelay) return (1 hours, 7 days - 1 hours);
        if (key == Param.RebalanceInterval) return (1 days, 90 days);
        if (key == Param.RebalanceWindow) return (1 hours, 90 days);
        if (key == Param.MaxAdditionsPerEpoch) return (1, 5);
        if (key == Param.StaleBasketAfter) return (1 days, 90 days);
        if (key == Param.FailureThreshold) return (1, 10);
        if (key == Param.DepositFeeBps) return (0, 100);
        // MinMarketCapUsd, MinLiquidityUsd, MinVolumeUsd: whole US dollars, never zero.
        return (1, type(uint128).max);
    }

    function asset(address token) external view returns (Asset memory) {
        return _assets[token];
    }

    function listedTokens() external view returns (address[] memory) {
        return _listed;
    }

    function isApproved(address token) external view returns (bool) {
        return _assets[token].approved;
    }

    function isQuarantined(address token) external view returns (bool) {
        return _assets[token].quarantined;
    }

    function maxWeightBps(address token) external view returns (uint16) {
        return _assets[token].maxWeightBps;
    }

    /// @notice The on-chain half of eligibility: allowlisted, not quarantined, old enough, fresh price.
    function isEligible(address token) external view returns (bool) {
        Asset storage a = _assets[token];
        if (!a.approved || a.quarantined) return false;
        if (block.timestamp < uint256(a.listedAt) + _params[Param.MinTokenAge]) return false;
        (, bool ok) = _feedPrice(a.feed, a.feedDecimals, a.heartbeat);
        return ok;
    }

    /// @notice USD price of one whole token, scaled by 1e18. `ok` is false when the feed is missing,
    /// stale, non-positive, from an unfinished round or failing.
    function priceUsd(address token) public view returns (uint256 price, bool ok) {
        if (token == reserveAsset) return _feedPrice(reserveFeed, reserveFeedDecimals, reserveHeartbeat);
        Asset storage a = _assets[token];
        return _feedPrice(a.feed, a.feedDecimals, a.heartbeat);
    }

    /// @notice Converts `amount` of `from` into units of `to` at oracle prices, rounding down.
    function convert(address from, uint256 amount, address to) external view returns (uint256 out, bool ok) {
        if (from == to) return (amount, true);
        (uint256 priceFrom, bool okFrom) = priceUsd(from);
        (uint256 priceTo, bool okTo) = priceUsd(to);
        if (!okFrom || !okTo) return (0, false);
        uint256 usd = Math.mulDiv(amount, priceFrom, 10 ** _decimalsOf(from));
        return (Math.mulDiv(usd, 10 ** _decimalsOf(to), priceTo), true);
    }

    // ---------------------------------------------------------------- internals

    function _decimalsOf(address token) private view returns (uint256) {
        return token == reserveAsset ? reserveDecimals : _assets[token].decimals;
    }

    function _quarantine(address token) private {
        Asset storage a = _assets[token];
        if (a.feed == address(0)) revert NotListed();
        if (a.quarantined) revert AlreadyQuarantined();
        a.quarantined = true;
        emit TokenQuarantined(token, msg.sender);
    }

    function _checkFeed(address feed, uint32 heartbeat) private view returns (uint8 feedDecimals) {
        if (feed == address(0) || feed.code.length == 0) revert InvalidFeed();
        if (heartbeat == 0 || heartbeat > 7 days) revert InvalidValue();
        feedDecimals = IAggregatorV3(feed).decimals();
        if (feedDecimals > 18) revert InvalidFeed();
    }

    /// @dev A low-level call so that a reverting or malformed feed reads as "no price" instead of
    /// reverting the caller.
    function _feedPrice(address feed, uint8 feedDecimals, uint32 heartbeat)
        private
        view
        returns (uint256 price, bool ok)
    {
        if (feed == address(0)) return (0, false);
        (bool success, bytes memory ret) = feed.staticcall(abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!success || ret.length < 160) return (0, false);
        (uint256 roundId, int256 answer,, uint256 updatedAt, uint256 answeredInRound) =
            abi.decode(ret, (uint256, int256, uint256, uint256, uint256));
        if (answer <= 0 || uint256(answer) > type(uint128).max) return (0, false);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > heartbeat) {
            return (0, false);
        }
        if (answeredInRound < roundId) return (0, false);
        price = uint256(answer) * 1e18 / 10 ** feedDecimals;
        ok = price != 0;
    }

    function _requireAdmin() private view {
        if (msg.sender != address(admin)) revert NotTimelock();
    }
}
