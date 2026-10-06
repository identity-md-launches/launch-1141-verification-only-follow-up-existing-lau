// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Chainlink-style price feed.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IWETH {
    function deposit() external payable;
}

/// @notice Roles held in the TimelockedAdmin role table. One address holds at most one role.
enum Role {
    None,
    Guardian,
    Signer,
    Keeper,
    Executor
}

/// @notice Timelocked, bounded parameters held by the AssetRegistry.
enum Param {
    MaxSlippageBps,
    ReserveBufferBps,
    DriftThresholdBps,
    MinTokenAge,
    MinMarketCapUsd,
    MinLiquidityUsd,
    MinVolumeUsd,
    MaxSnapshotAge,
    ProposalDelay,
    RebalanceInterval,
    RebalanceWindow,
    MaxAdditionsPerEpoch,
    StaleBasketAfter,
    FailureThreshold,
    DepositFeeBps
}

interface ITimelockedAdmin {
    function admin() external view returns (address);
    function guardian() external view returns (address);
    function executor() external view returns (address);
    function paused() external view returns (bool);
    function quorum() external view returns (uint32);
    function signerSetVersion() external view returns (uint32);
    function roleOf(address account) external view returns (Role);
}

interface IAssetRegistry {
    function reserveAsset() external view returns (address);
    function reserveDecimals() external view returns (uint8);
    function param(Param key) external view returns (uint256);
    function methodologyVersion() external view returns (uint32);
    function isApproved(address token) external view returns (bool);
    function isQuarantined(address token) external view returns (bool);
    function isAutoQuarantined(address token) external view returns (bool);
    function quarantineVersion(address token) external view returns (uint256);
    function isRouterApproved(address router) external view returns (bool);
    function maxWeightBps(address token) external view returns (uint16);
    function isEligible(address token) external view returns (bool);
    function convert(address from, uint256 amount, address to) external view returns (uint256 out, bool ok);
    function quarantine(address token) external;
}

interface IEpochManager {
    function epoch() external view returns (uint64);
    function activatedAt() external view returns (uint64);
    function targetWeightBps(address token) external view returns (uint16);
    function basketStale() external view returns (bool);
}

interface IIndexVault {
    function asset() external view returns (address);
    function heldTokens() external view returns (address[] memory);
    function isHeld(address token) external view returns (bool);
    function deposit(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares);
    function beginTrade(address sellToken, uint256 amount) external;
    function endTrade(address buyToken) external;
}

interface IFeeWaterfall {
    function reserveAsset() external view returns (address);
    function weth() external view returns (address);
    function feeQuote() external view returns (uint24 lpFeePips, uint24 hookFeePips, uint16 basketBps, uint16 nonLpBps);
}
