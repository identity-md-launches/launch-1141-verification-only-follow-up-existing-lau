// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

/// @dev Minimal swap and liquidity router for tests: unlocks the pool manager, performs one action
/// and settles both currencies for the caller.
contract V4Router is IUnlockCallback {
    IPoolManager public immutable manager;

    struct Action {
        address payer;
        PoolKey key;
        bool isSwap;
        SwapParams swap;
        ModifyLiquidityParams liquidity;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swap(PoolKey memory key, SwapParams memory params) external payable returns (BalanceDelta delta) {
        ModifyLiquidityParams memory none;
        delta = _run(Action(msg.sender, key, true, params, none));
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        payable
        returns (BalanceDelta delta)
    {
        SwapParams memory none;
        delta = _run(Action(msg.sender, key, false, none, params));
    }

    function _run(Action memory action) private returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(action)), (BalanceDelta));
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "refund failed");
        }
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        Action memory action = abi.decode(raw, (Action));
        BalanceDelta delta;
        if (action.isSwap) delta = manager.swap(action.key, action.swap, "");
        else (delta,) = manager.modifyLiquidity(action.key, action.liquidity, "");
        _settle(action.key.currency0, action.payer, delta.amount0());
        _settle(action.key.currency1, action.payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(uint128(amount)));
        }
    }
}
