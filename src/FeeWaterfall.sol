// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEpochManager, IIndexVault, ITimelockedAdmin, IWETH} from "./interfaces/IIndex.sol";

/// @title FeeWaterfall
/// @notice Holds the on-chain fee split and divides the fees the hook collects.
/// @dev The five shares are visible here and changed only by the timelock:
///   basket reserve 40% · liquidity providers 25% · swarm/operator 20% · protocol 10% · token utility 5%.
/// The liquidity-provider share never reaches this contract: the hook applies it as the pool's LP fee,
/// so in-range LPs earn it natively. What arrives here is the other 75%, in the reserve asset, and is
/// divided between the four remaining buckets in proportion to their shares.
/// The basket bucket accumulates in the reserve asset until anyone pushes it into the vault, where it
/// is deposited at NAV for shares owned by the timelock treasury. Nothing is traded here.
contract FeeWaterfall {
    using SafeERC20 for IERC20;

    enum Bucket {
        Basket,
        Swarm,
        Protocol,
        Utility
    }

    uint256 public constant BPS = 10_000;
    /// @notice Hard ceiling on the total swap fee including the stale-basket surcharge: 3%.
    uint24 public constant MAX_TOTAL_FEE_PIPS = 30_000;

    ITimelockedAdmin public immutable admin;
    IIndexVault public immutable vault;
    IEpochManager public immutable epochs;
    address public immutable reserveAsset;
    /// @notice Wrapped native token, or zero when the hooked pool is not quoted in native ETH.
    address public immutable weth;

    uint16 public basketBps = 4_000;
    uint16 public lpBps = 2_500;
    uint16 public swarmBps = 2_000;
    uint16 public protocolBps = 1_000;
    uint16 public utilityBps = 500;

    /// @notice Total project swap fee in hundredths of a basis point (10_000 = 1%).
    uint24 public swapFeePips = 10_000;
    /// @notice Added to the fee while the basket is stale; zero disables the surcharge.
    uint24 public staleSurchargePips;

    mapping(Bucket bucket => uint256) public accrued;
    mapping(Bucket bucket => uint256) public lifetime;
    mapping(Bucket bucket => address) public recipient;
    /// @notice Sum of `accrued` over all buckets; the reserve balance never falls below it.
    uint256 public totalAccrued;
    uint256 private _lock = 1;

    event FeesDistributed(uint256 amount, uint256 basket, uint256 swarm, uint256 protocol, uint256 utility);
    event BucketClaimed(Bucket indexed bucket, address indexed recipient, uint256 amount);
    event BasketReservePushed(uint256 assets, uint256 shares, address indexed shareReceiver);
    event SplitSet(uint16 basketBps, uint16 lpBps, uint16 swarmBps, uint16 protocolBps, uint16 utilityBps);
    event SwapFeeSet(uint24 swapFeePips, uint24 staleSurchargePips);
    event RecipientSet(Bucket indexed bucket, address indexed recipient);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotTimelock();
    error Reentrancy();
    error InvalidSplit();
    error FeeTooHigh();
    error InvalidBucket();
    error NothingToSend();
    error NotRescuable();
    error EthTransferFailed();

    modifier onlyAdmin() {
        if (msg.sender != address(admin)) revert NotTimelock();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address admin_, address vault_, address epochs_, address weth_) {
        if (admin_ == address(0) || vault_ == address(0) || epochs_ == address(0)) revert ZeroAddress();
        admin = ITimelockedAdmin(admin_);
        vault = IIndexVault(vault_);
        epochs = IEpochManager(epochs_);
        reserveAsset = IIndexVault(vault_).asset();
        weth = weth_;
    }

    /// @dev Native fees arrive from the pool manager mid-swap, so this must stay empty.
    receive() external payable {}

    // ---------------------------------------------------------------- fee flow

    /// @notice Splits everything that arrived since the last call. Anyone may call it.
    function distribute() external nonReentrant returns (uint256 amount) {
        return _distribute();
    }

    /// @notice Sends a bucket's balance to its recipient. Anyone may trigger it; funds only ever go to
    /// the recipient the timelock configured.
    function claim(Bucket bucket) external nonReentrant returns (uint256 amount) {
        if (bucket == Bucket.Basket) revert InvalidBucket();
        address to = recipient[bucket];
        if (to == address(0)) revert ZeroAddress();
        _distribute();
        amount = accrued[bucket];
        if (amount == 0) revert NothingToSend();
        accrued[bucket] = 0;
        totalAccrued -= amount;
        IERC20(reserveAsset).safeTransfer(to, amount);
        emit BucketClaimed(bucket, to, amount);
    }

    /// @notice Deposits the accumulated basket reserve into the vault. The shares go to the timelock
    /// treasury. Reverts, leaving the reserve here, whenever the vault is not accepting deposits.
    function pushBasketReserve(uint256 minShares) external nonReentrant returns (uint256 shares) {
        _distribute();
        uint256 amount = accrued[Bucket.Basket];
        if (amount == 0) revert NothingToSend();
        accrued[Bucket.Basket] = 0;
        totalAccrued -= amount;
        IERC20(reserveAsset).forceApprove(address(vault), amount);
        shares = vault.deposit(amount, address(admin), minShares);
        emit BasketReservePushed(amount, shares, address(admin));
    }

    // ---------------------------------------------------------------- timelocked configuration

    function setSplit(uint16 basket, uint16 lp, uint16 swarm, uint16 protocol, uint16 utility) external onlyAdmin {
        if (uint256(basket) + lp + swarm + protocol + utility != BPS) revert InvalidSplit();
        // Fees already received are divided under the split that was in force when they arrived.
        _distribute();
        basketBps = basket;
        lpBps = lp;
        swarmBps = swarm;
        protocolBps = protocol;
        utilityBps = utility;
        emit SplitSet(basket, lp, swarm, protocol, utility);
    }

    function setSwapFee(uint24 swapFeePips_, uint24 staleSurchargePips_) external onlyAdmin {
        if (uint256(swapFeePips_) + staleSurchargePips_ > MAX_TOTAL_FEE_PIPS) revert FeeTooHigh();
        swapFeePips = swapFeePips_;
        staleSurchargePips = staleSurchargePips_;
        emit SwapFeeSet(swapFeePips_, staleSurchargePips_);
    }

    function setRecipient(Bucket bucket, address to) external onlyAdmin {
        if (bucket == Bucket.Basket) revert InvalidBucket();
        recipient[bucket] = to;
        emit RecipientSet(bucket, to);
    }

    /// @notice Recovers assets that are not part of the fee flow: any token other than the reserve,
    /// and native ETH when this deployment does not wrap it.
    function rescue(address token, address to) external onlyAdmin nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount;
        if (token == address(0)) {
            if (_wrapsNative()) revert NotRescuable();
            amount = address(this).balance;
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            if (token == reserveAsset) revert NotRescuable();
            amount = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }

    // ---------------------------------------------------------------- views

    /// @notice What the hook applies to a swap right now.
    /// @return lpFeePips The liquidity providers' share of the fee, set as the pool's LP fee.
    /// @return hookFeePips The rest, collected by the hook in the quote currency.
    /// @return basketBps_ and nonLpBps Numerator and denominator of the basket's part of the hook fee.
    function feeQuote()
        external
        view
        returns (uint24 lpFeePips, uint24 hookFeePips, uint16 basketBps_, uint16 nonLpBps)
    {
        uint256 total = swapFeePips;
        if (staleSurchargePips != 0 && epochs.basketStale()) total += staleSurchargePips;
        lpFeePips = uint24(total * lpBps / BPS);
        hookFeePips = uint24(total - lpFeePips);
        basketBps_ = basketBps;
        nonLpBps = uint16(BPS - lpBps);
    }

    /// @notice Reserve-asset fees (and wrappable ETH) received but not yet split.
    function pendingDistribution() external view returns (uint256) {
        uint256 balance = IERC20(reserveAsset).balanceOf(address(this));
        if (_wrapsNative()) balance += address(this).balance;
        return balance - totalAccrued;
    }

    // ---------------------------------------------------------------- internals

    function _wrapsNative() private view returns (bool) {
        return weth != address(0) && weth == reserveAsset;
    }

    function _distribute() private returns (uint256 amount) {
        if (_wrapsNative() && address(this).balance != 0) IWETH(weth).deposit{value: address(this).balance}();
        amount = IERC20(reserveAsset).balanceOf(address(this)) - totalAccrued;
        if (amount == 0) return 0;

        uint256 nonLp = BPS - lpBps;
        uint256 swarm;
        uint256 protocol;
        uint256 utility;
        if (nonLp != 0) {
            swarm = amount * swarmBps / nonLp;
            protocol = amount * protocolBps / nonLp;
            utility = amount * utilityBps / nonLp;
        }
        // The basket takes the remainder, so rounding dust always goes to the reserve.
        uint256 basket = amount - swarm - protocol - utility;

        _credit(Bucket.Basket, basket);
        _credit(Bucket.Swarm, swarm);
        _credit(Bucket.Protocol, protocol);
        _credit(Bucket.Utility, utility);
        totalAccrued += amount;
        emit FeesDistributed(amount, basket, swarm, protocol, utility);
    }

    function _credit(Bucket bucket, uint256 amount) private {
        accrued[bucket] += amount;
        lifetime[bucket] += amount;
    }
}
