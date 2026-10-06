// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;
    /// @dev When set, transfers out of `blockedFrom` revert (a token turning into a honeypot).
    address public blockedFrom;
    bool public balanceReverts;

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlockedFrom(address account) external {
        blockedFrom = account;
    }

    function setBalanceReverts(bool on) external {
        balanceReverts = on;
    }

    function balanceOf(address account) public view override returns (uint256) {
        require(!balanceReverts, "balanceOf disabled");
        return super.balanceOf(account);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(from == address(0) || from != blockedFrom, "transfers blocked");
        super._update(from, to, value);
    }
}

/// @dev Keeps a percentage of every transfer, to check that amounts are measured and not assumed.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("FOT", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 10;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeed {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;
    bool public reverts;
    bool public malformed;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
        roundId += 1;
        answeredInRound = roundId;
    }

    function touch() external {
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setAnsweredInRound(uint80 r) external {
        answeredInRound = r;
    }

    function setReverts(bool on) external {
        reverts = on;
    }

    function setMalformed(bool on) external {
        malformed = on;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverts, "feed down");
        if (malformed) {
            assembly {
                mstore(0, 1)
                return(0, 32)
            }
        }
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

interface IVaultLike {
    function deposit(uint256 assets, address receiver, uint256 minShares) external returns (uint256);
    function redeem(uint256 shares, address receiver, bool strict) external;
    function nav() external view returns (uint256, bool);
}

interface IExecutorLike {
    function executeTrade(address, address, uint256, uint256, address, bytes calldata) external returns (bool, uint256);
}

/// @dev Stands in for a swap venue. The caller states the output, so a test chooses the fill price.
contract MockRouter {
    address public vault;
    address public executor;
    uint256 public blockedCalls;

    function setTargets(address vault_, address executor_) external {
        vault = vault_;
        executor = executor_;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) public {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }

    function fail() external pure {
        revert("router: no route");
    }

    /// @dev Tries to use the vault and the executor while the vault's assets are out for a trade,
    /// then completes the swap honestly. Every attempt must be refused.
    function swapAndReenter(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
        IERC20(tokenIn).approve(vault, type(uint256).max);
        try IVaultLike(vault).deposit(1e6, address(this), 0) {}
        catch {
            ++blockedCalls;
        }
        try IVaultLike(vault).redeem(1, address(this), false) {}
        catch {
            ++blockedCalls;
        }
        try IVaultLike(vault).nav() {}
        catch {
            ++blockedCalls;
        }
        try IExecutorLike(executor).executeTrade(tokenIn, tokenOut, 1, 0, address(this), "") {}
        catch {
            ++blockedCalls;
        }
        swap(tokenIn, tokenOut, amountIn, amountOut);
    }
}
