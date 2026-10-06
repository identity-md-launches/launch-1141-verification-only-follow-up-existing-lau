// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAssetRegistry, ITimelockedAdmin, Param} from "./interfaces/IIndex.sol";

/// @title IndexVault
/// @notice Holds the reserve asset and the basket, and issues ERC-20 index shares against them.
/// @dev Deposits are in the reserve asset and priced at oracle NAV. Redemptions are in kind: a
/// redeemer receives their pro-rata slice of the reserve and of every held token. That needs no
/// oracle, keeper, signer or swarm, and is never paused, so holders can always leave.
/// The only party that can move assets other than a redeemer is the executor contract named in the
/// TimelockedAdmin, and only through `beginTrade` / `endTrade`, which hold the vault locked for the
/// duration of a swap. The timelock itself has no withdrawal function here.
contract IndexVault is ERC20 {
    using SafeERC20 for IERC20;

    /// @notice Upper bound on tracked non-reserve tokens: five members plus positions being unwound.
    uint256 public constant MAX_HELD = 10;
    uint256 public constant BPS = 10_000;
    /// @dev Virtual shares per virtual unit of assets; makes share-price inflation unprofitable.
    uint256 private constant VIRTUAL_SHARES = 1e6;
    /// @dev Gas given to a held token's transfer during redemption, so one token cannot burn it all.
    uint256 private constant TRANSFER_GAS = 500_000;

    uint256 private constant IDLE = 1;
    uint256 private constant ENTERED = 2;
    uint256 private constant TRADING = 3;

    ITimelockedAdmin public immutable admin;
    IAssetRegistry public immutable registry;
    /// @notice The reserve asset deposits are made in (USDC or WETH).
    address public immutable asset;
    uint8 private immutable _shareDecimals;

    /// @notice Maximum NAV, in reserve units, that deposits may bring the vault to.
    uint256 public depositCap;
    bool private _assetChecked;
    uint256 private _lock = IDLE;
    address[] private _held;

    event Deposited(address indexed caller, address indexed receiver, uint256 assets, uint256 fee, uint256 shares);
    event Redeemed(address indexed caller, address indexed receiver, uint256 shares);
    event RedemptionPayout(address indexed receiver, address indexed token, uint256 amount);
    event RedemptionSkipped(address indexed receiver, address indexed token, uint256 amount);
    event TradeStarted(address indexed sellToken, uint256 amount);
    event TradeEnded(address indexed buyToken);
    event HeldTokenAdded(address indexed token);
    event HeldTokenRemoved(address indexed token);
    event DepositCapSet(uint256 cap);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error Paused();
    error NoGuardian();
    error Locked();
    error NotTimelock();
    error NotExecutor();
    error DecimalsMismatch();
    error PriceUnavailable(address token);
    error DepositCapExceeded();
    error InsufficientShares(uint256 shares, uint256 minShares);
    error TransferFailed(address token);
    error NotHeld(address token);
    error HeldListFull();
    error NotRescuable();

    modifier nonReentrant() {
        if (_lock != IDLE) revert Locked();
        _lock = ENTERED;
        _;
        _lock = IDLE;
    }

    modifier onlyExecutor() {
        if (msg.sender != admin.executor()) revert NotExecutor();
        _;
    }

    /// @param reserveDecimals_ Decimals of `asset_`. Passed in because a constructor here may not call
    /// outside the project; it is verified against the token on the first deposit.
    constructor(address admin_, address registry_, address asset_, uint8 reserveDecimals_, uint256 depositCap_)
        ERC20("IMD Index Vault Share", "vIMDEX")
    {
        if (admin_ == address(0) || registry_ == address(0) || asset_ == address(0)) revert ZeroAddress();
        if (reserveDecimals_ > 18) revert DecimalsMismatch();
        admin = ITimelockedAdmin(admin_);
        registry = IAssetRegistry(registry_);
        asset = asset_;
        _shareDecimals = reserveDecimals_ + 6;
        depositCap = depositCap_;
        emit DepositCapSet(depositCap_);
    }

    function decimals() public view override returns (uint8) {
        return _shareDecimals;
    }

    // ---------------------------------------------------------------- deposit

    /// @notice Deposits `assets` of the reserve asset and mints shares at oracle NAV.
    /// @dev Closed while paused, while no guardian is set, and while any held token lacks a fresh
    /// price: a deposit that cannot be priced fairly is refused rather than guessed.
    /// @param minShares Reverts if fewer shares would be minted.
    function deposit(uint256 assets, address receiver, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (admin.paused()) revert Paused();
        if (admin.guardian() == address(0)) revert NoGuardian();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert ZeroAmount();
        if (!_assetChecked) {
            if (IERC20Metadata(asset).decimals() + 6 != _shareDecimals) revert DecimalsMismatch();
            _assetChecked = true;
        }

        (uint256 navBefore, address unpriced) = _nav();
        if (unpriced != address(0)) revert PriceUnavailable(unpriced);

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balanceBefore;
        if (navBefore + received > depositCap) revert DepositCapExceeded();

        // The fee stays in the vault, so it accrues to existing holders.
        uint256 fee = received * registry.param(Param.DepositFeeBps) / BPS;
        shares = Math.mulDiv(received - fee, totalSupply() + VIRTUAL_SHARES, navBefore + 1);
        if (shares == 0 || shares < minShares) revert InsufficientShares(shares, minShares);
        _mint(receiver, shares);
        emit Deposited(msg.sender, receiver, received, fee, shares);
    }

    // ---------------------------------------------------------------- redeem

    /// @notice Burns `shares` and pays the caller's pro-rata slice of the reserve and every held token.
    /// @param strict When true, any token whose transfer fails reverts the redemption. When false, such
    /// a token is skipped and the redeemer forfeits that slice to the remaining holders; this is the
    /// exit of last resort when a held token has become untransferable.
    function redeem(uint256 shares, address receiver, bool strict) external nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroAmount();
        uint256 supply = totalSupply() + VIRTUAL_SHARES;
        _burn(msg.sender, shares);
        emit Redeemed(msg.sender, receiver, shares);

        uint256 amount = Math.mulDiv(IERC20(asset).balanceOf(address(this)), shares, supply);
        if (amount != 0) {
            IERC20(asset).safeTransfer(receiver, amount);
            emit RedemptionPayout(receiver, asset, amount);
        }
        uint256 n = _held.length;
        for (uint256 i; i < n; ++i) {
            address token = _held[i];
            (uint256 balance,) = _balanceOf(token);
            amount = Math.mulDiv(balance, shares, supply);
            if (amount == 0) continue;
            if (_tryTransfer(token, receiver, amount)) {
                emit RedemptionPayout(receiver, token, amount);
            } else {
                if (strict) revert TransferFailed(token);
                emit RedemptionSkipped(receiver, token, amount);
            }
        }
    }

    // ---------------------------------------------------------------- executor only

    /// @notice Hands `amount` of `sellToken` to the executor and locks the vault until `endTrade`.
    /// Deposits, redemptions and NAV reads revert while the lock is held.
    function beginTrade(address sellToken, uint256 amount) external onlyExecutor {
        if (_lock != IDLE) revert Locked();
        if (sellToken != asset && !isHeld(sellToken)) revert NotHeld(sellToken);
        _lock = TRADING;
        IERC20(sellToken).safeTransfer(msg.sender, amount);
        emit TradeStarted(sellToken, amount);
    }

    /// @notice Ends the trade: starts tracking `buyToken` and stops tracking emptied positions.
    function endTrade(address buyToken) external onlyExecutor {
        if (_lock != TRADING) revert Locked();
        if (buyToken != asset && !isHeld(buyToken)) {
            if (_held.length >= MAX_HELD) revert HeldListFull();
            _held.push(buyToken);
            emit HeldTokenAdded(buyToken);
        }
        for (uint256 i = _held.length; i != 0; --i) {
            address token = _held[i - 1];
            (uint256 balance, bool readable) = _balanceOf(token);
            if (readable && balance == 0) {
                _held[i - 1] = _held[_held.length - 1];
                _held.pop();
                emit HeldTokenRemoved(token);
            }
        }
        _lock = IDLE;
        emit TradeEnded(buyToken);
    }

    // ---------------------------------------------------------------- timelock only

    function setDepositCap(uint256 cap) external {
        if (msg.sender != address(admin)) revert NotTimelock();
        depositCap = cap;
        emit DepositCapSet(cap);
    }

    /// @notice Recovers a token sent here by mistake. It cannot touch the reserve or any held token.
    function rescue(address token, address to) external nonReentrant {
        if (msg.sender != address(admin)) revert NotTimelock();
        if (token == asset || isHeld(token) || to == address(0)) revert NotRescuable();
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ---------------------------------------------------------------- views

    function heldTokens() external view returns (address[] memory) {
        return _held;
    }

    function isHeld(address token) public view returns (bool) {
        uint256 n = _held.length;
        for (uint256 i; i < n; ++i) {
            if (_held[i] == token) return true;
        }
        return false;
    }

    /// @notice Net asset value in reserve units. `complete` is false when a held token has no fresh
    /// price; that token is then counted as zero and deposits are closed.
    function nav() external view returns (uint256 value, bool complete) {
        if (_lock == TRADING) revert Locked();
        address unpriced;
        (value, unpriced) = _nav();
        complete = unpriced == address(0);
    }

    /// @notice NAV per whole share, in reserve units.
    function navPerShare() external view returns (uint256 value, bool complete) {
        if (_lock == TRADING) revert Locked();
        (uint256 total, address unpriced) = _nav();
        value = Math.mulDiv(total + 1, 10 ** _shareDecimals, totalSupply() + VIRTUAL_SHARES);
        complete = unpriced == address(0);
    }

    /// @notice Every position: the reserve first, then each held token, with balance, value in
    /// reserve units and whether that value comes from a fresh price.
    function holdings()
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256[] memory values, bool[] memory priced)
    {
        if (_lock == TRADING) {
            revert Locked();
        }
        uint256 n = _held.length;
        tokens = new address[](n + 1);
        balances = new uint256[](n + 1);
        values = new uint256[](n + 1);
        priced = new bool[](n + 1);
        tokens[0] = asset;
        balances[0] = IERC20(asset).balanceOf(address(this));
        values[0] = balances[0];
        priced[0] = true;
        for (uint256 i; i < n; ++i) {
            tokens[i + 1] = _held[i];
            bool readable;
            (balances[i + 1], readable) = _balanceOf(_held[i]);
            (values[i + 1], priced[i + 1]) = registry.convert(_held[i], balances[i + 1], asset);
            priced[i + 1] = priced[i + 1] && readable;
        }
    }

    function previewDeposit(uint256 assets) external view returns (uint256 shares, bool available) {
        if (_lock == TRADING) revert Locked();
        (uint256 total, address unpriced) = _nav();
        uint256 fee = assets * registry.param(Param.DepositFeeBps) / BPS;
        shares = Math.mulDiv(assets - fee, totalSupply() + VIRTUAL_SHARES, total + 1);
        available =
            unpriced == address(0) && !admin.paused() && admin.guardian() != address(0) && total + assets <= depositCap;
    }

    function previewRedeem(uint256 shares) external view returns (address[] memory tokens, uint256[] memory amounts) {
        if (_lock == TRADING) revert Locked();
        uint256 n = _held.length;
        uint256 supply = totalSupply() + VIRTUAL_SHARES;
        tokens = new address[](n + 1);
        amounts = new uint256[](n + 1);
        tokens[0] = asset;
        amounts[0] = Math.mulDiv(IERC20(asset).balanceOf(address(this)), shares, supply);
        for (uint256 i; i < n; ++i) {
            tokens[i + 1] = _held[i];
            (uint256 balance,) = _balanceOf(_held[i]);
            amounts[i + 1] = Math.mulDiv(balance, shares, supply);
        }
    }

    // ---------------------------------------------------------------- internals

    /// @return value NAV counting unpriced tokens as zero.
    /// @return unpriced The first held token with a non-zero balance and no fresh price, if any.
    function _nav() private view returns (uint256 value, address unpriced) {
        value = IERC20(asset).balanceOf(address(this));
        uint256 n = _held.length;
        for (uint256 i; i < n; ++i) {
            address token = _held[i];
            (uint256 balance, bool ok) = _balanceOf(token);
            if (ok && balance == 0) continue;
            uint256 tokenValue;
            if (ok) (tokenValue, ok) = registry.convert(token, balance, asset);
            if (ok) value += tokenValue;
            else if (unpriced == address(0)) unpriced = token;
        }
    }

    /// @dev A held token whose `balanceOf` fails reads as zero and unreadable, so it cannot block
    /// redemptions; it is then treated as unpriced and is never dropped from the held list.
    function _balanceOf(address token) private view returns (uint256 balance, bool readable) {
        (bool ok, bytes memory ret) =
            token.staticcall{gas: TRANSFER_GAS}(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (ok && ret.length >= 32) return (abi.decode(ret, (uint256)), true);
    }

    function _tryTransfer(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call{gas: TRANSFER_GAS}(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || token.code.length == 0) return false;
        if (ret.length == 0) return true;
        return ret.length >= 32 && abi.decode(ret, (uint256)) == 1;
    }
}
